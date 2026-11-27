use listen_router::config::Config;
use listen_router::folders::Home;
use listen_router::manager::Manager;
use listen_router::pairing::{system_clock, Pairing};
use listen_router::service::{serve, Found, RouterService};
use listen_router::tls;
use listen_router_proto::v1::router_client::RouterClient;
use listen_router_proto::v1::{
    ask_event::Kind, AskRequest, CloseSessionRequest, DeliverRequest, OpenSessionRequest, PairRequest, StatusRequest,
    Tool,
};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tonic::transport::{Certificate, Channel, ClientTlsConfig};
use tonic::{Code, Request};

struct Running {
    port: u16,
    cert_pem: String,
    code: String,
    config: Arc<Mutex<Config>>,
    _home: tempfile::TempDir,
}

async fn start() -> Running {
    let home = tempfile::tempdir().unwrap();
    let dirs = Home::new(home.path().to_path_buf());
    let identity = tls::load_or_create(&dirs.tls_dir()).unwrap();
    let config = Arc::new(Mutex::new(Config::default()));
    let pairing = Arc::new(Mutex::new(Pairing::new(system_clock())));
    let code = pairing.lock().unwrap().new_code();
    let manager = Arc::new(Manager::new(
        dirs.clone(),
        Config::default().limits,
        PathBuf::from(env!("CARGO_BIN_EXE_fake-claude")),
    ));
    let service = RouterService {
        manager,
        pairing,
        config: config.clone(),
        config_path: dirs.config_path(),
        name: "test".into(),
        claude: Found { found: true, version: "fake".into() },
        codex: Found::default(),
        activity: Default::default(),
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let cert_pem = identity.cert_pem.clone();
    tokio::spawn(async move { serve(service, listener, &identity, std::future::pending()).await.unwrap() });
    Running { port, cert_pem, code, config, _home: home }
}

async fn connect(port: u16, cert_pem: &str) -> Result<RouterClient<Channel>, tonic::transport::Error> {
    let tls = ClientTlsConfig::new().ca_certificate(Certificate::from_pem(cert_pem)).domain_name(tls::SERVER_NAME);
    let channel = Channel::from_shared(format!("https://127.0.0.1:{port}")).unwrap().tls_config(tls)?.connect().await?;
    Ok(RouterClient::new(channel))
}

fn with<T>(token: &str, message: T) -> Request<T> {
    let mut request = Request::new(message);
    request.metadata_mut().insert("authorization", format!("Bearer {token}").parse().unwrap());
    request
}

async fn pair(client: &mut RouterClient<Channel>, code: &str) -> String {
    client
        .pair(PairRequest { code: code.into(), device_name: "test device".into() })
        .await
        .unwrap()
        .into_inner()
        .device_token
}

fn open_request() -> OpenSessionRequest {
    OpenSessionRequest {
        topic_id: "t1".into(),
        role: "deep".into(),
        tool: Tool::Claude as i32,
        model: "haiku".into(),
        system: "S".into(),
        session_id: String::new(),
    }
}

#[tokio::test]
async fn calls_without_a_token_are_unauthenticated() {
    let running = start().await;
    let mut client = connect(running.port, &running.cert_pem).await.unwrap();
    let code = |status: tonic::Status| status.code();
    assert_eq!(code(client.status(StatusRequest {}).await.unwrap_err()), Code::Unauthenticated);
    assert_eq!(code(client.open_session(open_request()).await.unwrap_err()), Code::Unauthenticated);
    assert_eq!(
        code(client.deliver(DeliverRequest { session_id: "x".into(), text: "x".into() }).await.unwrap_err()),
        Code::Unauthenticated
    );
    assert_eq!(
        code(client.ask(AskRequest { session_id: "x".into(), text: "x".into() }).await.unwrap_err()),
        Code::Unauthenticated
    );
    assert_eq!(
        code(client.close_session(CloseSessionRequest { session_id: "x".into() }).await.unwrap_err()),
        Code::Unauthenticated
    );
    assert_eq!(code(client.status(with("made-up", StatusRequest {})).await.unwrap_err()), Code::Unauthenticated);
}

#[tokio::test]
async fn pair_then_status() {
    let running = start().await;
    let mut client = connect(running.port, &running.cert_pem).await.unwrap();
    let wrong = client.pair(PairRequest { code: "WRONG000".into(), device_name: "x".into() }).await.unwrap_err();
    assert_eq!(wrong.code(), Code::PermissionDenied);
    let token = pair(&mut client, &running.code).await;
    let again = client.pair(PairRequest { code: running.code.clone(), device_name: "x".into() }).await.unwrap_err();
    assert_eq!(again.code(), Code::FailedPrecondition);

    let status = client.status(with(&token, StatusRequest {})).await.unwrap().into_inner();
    let claude = &status.tools[0];
    assert!(claude.tool == Tool::Claude as i32 && claude.found && claude.enabled);
    let codex = &status.tools[1];
    assert!(codex.tool == Tool::Codex as i32 && !codex.enabled);
    let limits = status.limits.unwrap();
    assert_eq!(
        (limits.sessions_per_topic, limits.sessions_total, limits.idle_seconds, limits.silence_seconds),
        (4, 6, 600, 60)
    );
    assert!(status.sessions.is_empty());
}

#[tokio::test]
async fn open_deliver_ask_close_over_the_wire() {
    let running = start().await;
    let mut client = connect(running.port, &running.cert_pem).await.unwrap();
    let token = pair(&mut client, &running.code).await;
    let id = client.open_session(with(&token, open_request())).await.unwrap().into_inner().session_id;
    let waiting = client
        .deliver(with(&token, DeliverRequest { session_id: id.clone(), text: "gehört".into() }))
        .await
        .unwrap()
        .into_inner()
        .waiting;
    assert_eq!(waiting, 1);
    let mut stream = client
        .ask(with(&token, AskRequest { session_id: id.clone(), text: "Wer?".into() }))
        .await
        .unwrap()
        .into_inner();
    let mut texts = Vec::new();
    let mut last = None;
    while let Some(event) = stream.message().await.unwrap() {
        if let Some(Kind::Text(text)) = &event.kind {
            texts.push(text.clone());
        }
        last = event.kind;
    }
    assert_eq!(texts, ["echo:", "<delivered>\ngehört\n</delivered>\n\nWer?"]);
    assert!(matches!(last, Some(Kind::End(_))));

    let status = client.status(with(&token, StatusRequest {})).await.unwrap().into_inner();
    assert_eq!(status.sessions.len(), 1);
    assert_eq!(status.tools[0].signed_in, 1, "a question ended well, so the tool is signed in");
    client.close_session(with(&token, CloseSessionRequest { session_id: id.clone() })).await.unwrap();
    let gone = client.ask(with(&token, AskRequest { session_id: id, text: "x".into() })).await.unwrap_err();
    assert_eq!(gone.code(), Code::NotFound);
}

#[tokio::test]
async fn removed_device_is_locked_out() {
    let running = start().await;
    let mut client = connect(running.port, &running.cert_pem).await.unwrap();
    let token = pair(&mut client, &running.code).await;
    assert!(client.status(with(&token, StatusRequest {})).await.is_ok());
    running.config.lock().unwrap().devices.clear();
    assert_eq!(client.status(with(&token, StatusRequest {})).await.unwrap_err().code(), Code::Unauthenticated);
}

#[tokio::test]
async fn client_with_another_certificate_cannot_connect() {
    let running = start().await;
    let other = tempfile::tempdir().unwrap();
    let other = tls::load_or_create(other.path()).unwrap();
    assert!(connect(running.port, &other.cert_pem).await.is_err());
    assert!(connect(running.port, &running.cert_pem).await.is_ok());
}
