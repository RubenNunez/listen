//! `listen-routerctl`: a small command-line client for the Listen Router, for trying it without an app.
//!
//! It keeps the router's address, certificate and this client's token in `routerctl.toml`
//! in the folder it is run from. That file holds a secret and is ignored by git.

mod link;
mod pin;

use clap::{Parser, Subcommand};
use listen_router_proto::v1::router_client::RouterClient;
use listen_router_proto::v1::{
    ask_event::Kind, AskRequest, CloseSessionRequest, DeliverRequest, FailureKind, OpenSessionRequest, PairRequest, SignedIn,
    StatusRequest, Tool,
};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::time::Instant;
use tonic::transport::{Certificate, Channel, ClientTlsConfig};
use tonic::Request;

/// The name the router's certificate carries; the certificate itself is checked by fingerprint.
const SERVER_NAME: &str = "listen-router";
const FILE: &str = "routerctl.toml";

#[derive(Parser)]
#[command(name = "listen-routerctl", version, about = "Talks to a Listen Router from the command line")]
struct Args {
    #[command(subcommand)]
    command: Do,
}

#[derive(Subcommand)]
enum Do {
    /// Pairs with a router, given the listen://pair?… link it prints.
    Pair { link: String },
    /// Shows what the router has: tools, limits, sessions.
    Status,
    /// Opens a session in a topic and prints its id.
    Open {
        topic: String,
        role: String,
        /// The model; empty leaves it to the router's setting.
        #[arg(long, default_value = "")]
        model: String,
        /// claude or codex.
        #[arg(long, default_value = "claude")]
        tool: String,
        #[arg(long, default_value = "")]
        system: String,
        /// Continue this stored session instead of starting a new one.
        #[arg(long = "continue")]
        continue_id: Option<String>,
    },
    /// Hands text to a session for its next question. Asks no model.
    Deliver { session: String, text: String },
    /// Asks a session and prints the reply as it arrives.
    Ask { session: String, text: String },
    /// Closes a session. It stays on the router's disk.
    Close { session: String },
}

#[derive(Serialize, Deserialize)]
struct Saved {
    host: String,
    port: u16,
    fingerprint: String,
    cert_pem: String,
    token: String,
}

type Failure = Box<dyn std::error::Error>;

async fn connect(host: &str, port: u16, cert_pem: &str) -> Result<RouterClient<Channel>, Failure> {
    let tls = ClientTlsConfig::new().ca_certificate(Certificate::from_pem(cert_pem)).domain_name(SERVER_NAME);
    let address = if host.contains(':') { format!("https://[{host}]:{port}") } else { format!("https://{host}:{port}") };
    let channel = Channel::from_shared(address)?.tls_config(tls)?.connect().await?;
    Ok(RouterClient::new(channel))
}

fn saved() -> Result<Saved, Failure> {
    let text = std::fs::read_to_string(FILE).map_err(|_| format!("not paired yet: no {FILE} here; run `pair <link>` first"))?;
    Ok(toml::from_str(&text)?)
}

fn with<T>(token: &str, message: T) -> Request<T> {
    let mut request = Request::new(message);
    if let Ok(value) = format!("Bearer {token}").parse() {
        request.metadata_mut().insert("authorization", value);
    }
    request
}

#[tokio::main]
async fn main() {
    if let Err(error) = run(Args::parse().command).await {
        let message = match error.downcast_ref::<tonic::Status>() {
            Some(status) => format!("{:?}: {}", status.code(), status.message()),
            None => error.to_string(),
        };
        eprintln!("error: {message}");
        std::process::exit(1);
    }
}

async fn run(command: Do) -> Result<(), Failure> {
    if let Do::Pair { link } = &command {
        let link = link::parse(link)?;
        // Take the first address that answers with the certificate the link names.
        let mut last: Failure = "the link names no address".into();
        for host in &link.hosts {
            match pin::certificate(host, link.port, &link.fingerprint).await {
                Ok(cert_pem) => {
                    let mut client = connect(host, link.port, &cert_pem).await?;
                    let device_name = std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_default();
                    let reply = client
                        .pair(PairRequest { code: link.code.clone(), device_name: format!("routerctl {device_name}") })
                        .await?
                        .into_inner();
                    let saved = Saved {
                        host: host.clone(),
                        port: link.port,
                        fingerprint: link.fingerprint.clone(),
                        cert_pem,
                        token: reply.device_token,
                    };
                    std::fs::write(FILE, toml::to_string_pretty(&saved)?)?;
                    println!("paired with {} at {host}:{}", reply.router_name, link.port);
                    return Ok(());
                }
                Err(error) => last = format!("{host}: {error}").into(),
            }
        }
        return Err(last);
    }

    let saved = saved()?;
    let mut client = connect(&saved.host, saved.port, &saved.cert_pem).await?;
    let token = saved.token.as_str();
    match command {
        Do::Pair { .. } => unreachable!("handled above"),
        Do::Status => {
            let status = client.status(with(token, StatusRequest {})).await?.into_inner();
            println!("router {}", status.router_version);
            for tool in status.tools {
                let name = Tool::try_from(tool.tool).map(|t| t.as_str_name()).unwrap_or("?");
                let signed_in = match SignedIn::try_from(tool.signed_in) {
                    Ok(SignedIn::Yes) => "signed in",
                    Ok(SignedIn::No) => "NOT signed in",
                    _ => "sign-in not known yet",
                };
                println!(
                    "  {name:<12} {} · {} · {signed_in} {}",
                    if tool.found { "found" } else { "not found" },
                    if tool.enabled { "enabled" } else { "not enabled" },
                    tool.version
                );
            }
            if let Some(l) = status.limits {
                println!(
                    "  limits       {} per topic, {} in total, idle {} s, silence {} s",
                    l.sessions_per_topic, l.sessions_total, l.idle_seconds, l.silence_seconds
                );
            }
            for s in status.sessions {
                println!(
                    "  session      {}  topic {}  role {}  model {}  {}",
                    s.session_id,
                    s.topic_id,
                    s.role,
                    s.model,
                    if s.open { "running" } else { "resting" }
                );
            }
        }
        Do::Open { topic, role, model, system, continue_id, tool } => {
            let tool = if tool == "codex" { Tool::Codex } else { Tool::Claude };
            let reply = client
                .open_session(with(
                    token,
                    OpenSessionRequest {
                        topic_id: topic,
                        role,
                        tool: tool as i32,
                        model,
                        system,
                        session_id: continue_id.unwrap_or_default(),
                    },
                ))
                .await?
                .into_inner();
            println!("{}", reply.session_id);
            if reply.continued {
                eprintln!("continued");
            }
        }
        Do::Deliver { session, text } => {
            let reply = client.deliver(with(token, DeliverRequest { session_id: session, text })).await?.into_inner();
            println!("{} waiting", reply.waiting);
        }
        Do::Ask { session, text } => {
            let began = Instant::now();
            let mut first = None;
            let mut stream = client.ask(with(token, AskRequest { session_id: session, text })).await?.into_inner();
            while let Some(event) = stream.message().await? {
                match event.kind {
                    Some(Kind::Text(text)) => {
                        first.get_or_insert_with(|| began.elapsed());
                        print!("{text}");
                        std::io::stdout().flush()?;
                    }
                    Some(Kind::Step(step)) => println!("\n[{} {}]", step.tool, step.detail),
                    Some(Kind::Source(url)) => println!("[source {url}]"),
                    Some(Kind::Usage(usage)) => {
                        println!("\n[{} in, {} out, {:.5} USD]", usage.input_tokens, usage.output_tokens, usage.cost_usd)
                    }
                    Some(Kind::End(_)) => println!(
                        "[first text after {:.2} s, done after {:.2} s]",
                        first.unwrap_or_default().as_secs_f64(),
                        began.elapsed().as_secs_f64()
                    ),
                    Some(Kind::Failure(failure)) => {
                        let kind = FailureKind::try_from(failure.kind).map(|k| k.as_str_name()).unwrap_or("?");
                        return Err(format!("{kind}: {}", failure.message).into());
                    }
                    None => {}
                }
            }
        }
        Do::Close { session } => {
            client.close_session(with(token, CloseSessionRequest { session_id: session })).await?;
            println!("closed");
        }
    }
    Ok(())
}
