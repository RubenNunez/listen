//! `listen-router`: starts the router on this machine, in a terminal.
//! The desktop app (`listen-router-app`) starts the same router with a window.

use clap::Parser;
use listen_router::running::{Options, Running};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Parser)]
#[command(
    name = "listen-router",
    version,
    about = "Offers the claude command-line tool on this machine to your Listen apps"
)]
struct Args {
    /// The router's own folder. Default: Listen in your home folder.
    #[arg(long)]
    home: Option<PathBuf>,
    /// The port to listen on. Default: 50551, or what router.toml says.
    #[arg(long)]
    port: Option<u16>,
    /// The claude executable. Default: the one on the PATH, or what router.toml says.
    #[arg(long)]
    claude: Option<PathBuf>,
    /// A further address under which this machine is reached, for example its VPN address. May be given several times.
    #[arg(long = "host")]
    hosts: Vec<String>,
    /// Do not announce the router in the local network by Bonjour.
    #[arg(long)]
    no_bonjour: bool,
}

/// The terminal keeps one fixed code for five minutes. It is not renewed like the window's:
/// a printed QR code cannot be replaced in place, and printing a new one every 30 seconds
/// would scroll everything else away.
fn show_link(link: &str) {
    println!("\nPair a device within five minutes: scan this with the iPhone's camera, or use the link (Enter makes a new one):\n");
    println!("{}", listen_router::pairing::qr_terminal(link));
    println!("  {link}");
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let router = Running::start(Options {
        home: args.home,
        port: args.port,
        claude: args.claude,
        hosts: args.hosts,
        bonjour: !args.no_bonjour,
    })
    .await?;

    println!("Listen Router {}", env!("CARGO_PKG_VERSION"));
    println!("  folder       {}", router.home.root().display());
    if router.claude.found {
        println!("  claude       {}", router.claude.version);
    } else {
        println!("  claude       NOT FOUND ({}). Install it and sign in with: claude", router.claude_program.display());
    }
    let settings = router.settings();
    let level = |a: listen_router::config::Access| format!("{a:?}").to_lowercase();
    println!("  claude access {}", level(settings.claude.access));
    println!(
        "  codex        {}",
        match (router.codex.found, settings.codex.enabled) {
            (true, true) => format!("{}, switched on, access {}", router.codex.version, level(settings.codex.access)),
            (true, false) => "found, off (switch it on in router.toml or the app's settings)".to_string(),
            (false, _) => "not found".to_string(),
        }
    );
    println!("  devices      {}", router.devices().len());
    println!("  fingerprint  {}", router.fingerprint);
    println!("  listening    port {}", router.port);
    let bonjour = router.bonjour();
    match (bonjour.announced, bonjour.error) {
        (true, _) => println!("  bonjour      announced as \"{}\"", bonjour.name),
        (false, Some(error)) => println!("  bonjour      not announced: {error}"),
        _ => println!("  bonjour      off"),
    }
    show_link(&router.new_link());

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    loop {
        tokio::select! {
            line = lines.next_line() => match line {
                Ok(Some(_)) => show_link(&router.new_link()),
                // No terminal input (started in the background): wait for ctrl-c only.
                _ => { let _ = tokio::signal::ctrl_c().await; break; }
            },
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    router.stop().await;
    println!("stopped");
    Ok(())
}
