use listen_router::activity::Kind;
use listen_router::running::{Options, Running, StartError};
use listen_router::tls;
use listen_router_proto::v1::router_client::RouterClient;
use listen_router_proto::v1::{OpenSessionRequest, PairRequest, StatusRequest, Tool};
use std::path::PathBuf;
use tonic::transport::{Certificate, Channel, ClientTlsConfig};
use tonic::{Code, Request};

fn options(home: &std::path::Path, port: u16) -> Options {
    Options {
        home: Some(home.to_path_buf()),
        port: Some(port),
        claude: Some(PathBuf::from(env!("CARGO_BIN_EXE_fake-claude"))),
        hosts: vec![],
        bonjour: false,
    }
}

/// A port nobody uses right now.
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

#[tokio::test]
async fn start_and_stop_leave_no_process() {
    let home = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    assert!(router.claude.found, "the fake answers --version");
    assert_eq!(router.snapshot().pairing.phase, "none", "no code before anybody asked for one");
    assert!(router.new_link().starts_with("listen://pair?"));
    let manager = router.manager.clone();
    let id = manager
        .open(OpenSessionRequest {
            topic_id: "demo".into(),
            role: "flash".into(),
            tool: Tool::Claude as i32,
            model: "haiku".into(),
            system: String::new(),
            session_id: String::new(),
        })
        .unwrap()
        .session_id;
    let mut events = manager.ask(&id, "hello".into()).await.unwrap();
    while events.recv().await.is_some() {}
    assert!(manager.infos()[0].open, "its process runs");
    router.stop().await;
    assert!(manager.infos().is_empty(), "every session was closed");
    // A process still running in the topic folder would hold it on Windows; it can be renamed only once all have ended.
    let topics = home.path().join("topics");
    std::fs::rename(topics.join("demo"), topics.join("moved")).expect("no process holds the topic folder");
}

#[tokio::test]
async fn port_taken_is_reported() {
    let home = tempfile::tempdir().unwrap();
    let held = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
    let port = held.local_addr().unwrap().port();
    match Running::start(options(home.path(), port)).await {
        Err(StartError::PortTaken(p)) => assert_eq!(p, port),
        Err(other) => panic!("expected PortTaken, got {other}"),
        Ok(_) => panic!("expected PortTaken, the router started"),
    }
}

async fn client(router: &Running) -> RouterClient<Channel> {
    let cert = tls::load_or_create(&router.home.tls_dir()).unwrap().cert_pem;
    let tls = ClientTlsConfig::new().ca_certificate(Certificate::from_pem(cert)).domain_name(tls::SERVER_NAME);
    let address = format!("https://127.0.0.1:{}", router.port);
    RouterClient::new(Channel::from_shared(address).unwrap().tls_config(tls).unwrap().connect().await.unwrap())
}

fn code_of(link: &str) -> String {
    link.split('&').find_map(|p| p.strip_prefix("code=")).unwrap().to_string()
}

fn with<T>(token: &str, message: T) -> Request<T> {
    let mut request = Request::new(message);
    request.metadata_mut().insert("authorization", format!("Bearer {token}").parse().unwrap());
    request
}

#[tokio::test]
async fn snapshot_shows_tools_devices_and_link() {
    let home = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    let mut client = client(&router).await;
    // The window is visible: a watched code is shown.
    router.pairing_seen();
    let showing = router.snapshot().pairing;
    assert_eq!((showing.phase, showing.period, showing.device.as_deref()), ("code", 30, None));
    assert!((29..=30).contains(&showing.seconds_left));
    assert!(showing.link.starts_with("listen://pair?"));
    assert!(showing.qr_svg.starts_with("<svg") || showing.qr_svg.starts_with("<?xml"));
    client.pair(PairRequest { code: code_of(&showing.link), device_name: "iPhone".into() }).await.unwrap();

    router.pairing_seen();
    let snapshot = router.snapshot();
    assert!(snapshot.ready && snapshot.problem.is_none());
    assert_eq!(snapshot.port, router.port);
    let claude = &snapshot.tools[0];
    assert_eq!(
        (claude.name.as_str(), claude.found, claude.enabled, claude.signed_in.as_str()),
        ("claude", true, true, "unknown")
    );
    assert!(!claude.hint.is_empty(), "unknown sign-in says how to sign in");
    assert_eq!((snapshot.tools[1].name.as_str(), snapshot.tools[1].enabled), ("codex", false));
    assert_eq!(snapshot.devices.len(), 1);
    assert_eq!(snapshot.devices[0].name, "iPhone");
    assert_eq!(snapshot.devices[0].id.len(), 8);
    // Paired: the window names the device and shows no further code by itself.
    assert_eq!((snapshot.pairing.phase, snapshot.pairing.device.as_deref()), ("paired", Some("iPhone")));
    assert!(snapshot.pairing.link.is_empty() && snapshot.pairing.qr_svg.is_empty());
    assert!(snapshot.activity.iter().any(|e| e.kind == Kind::Paired));
    let json = serde_json::to_value(&snapshot).unwrap();
    assert!(
        json["pairing"]["qrSvg"].is_string() && json["tools"][0]["signedIn"].is_string(),
        "camelCase for the window"
    );
    router.stop().await;
}

#[tokio::test]
async fn missing_claude_is_not_ready() {
    let home = tempfile::tempdir().unwrap();
    let mut o = options(home.path(), free_port());
    o.claude = Some(home.path().join("no-such-claude"));
    let router = Running::start(o).await.unwrap();
    let snapshot = router.snapshot();
    assert!(!snapshot.ready);
    assert!(snapshot.problem.unwrap().contains("claude"));
    assert!(!snapshot.tools[0].found);
    router.stop().await;
}

#[tokio::test]
async fn removed_device_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    let mut client = client(&router).await;
    let token = client
        .pair(PairRequest { code: code_of(&router.new_link()), device_name: "Mac".into() })
        .await
        .unwrap()
        .into_inner()
        .device_token;
    client.status(with(&token, StatusRequest {})).await.expect("paired, so allowed");
    let id = router.snapshot().devices[0].id.clone();
    assert!(!router.remove_device("abc"), "too short an id removes nothing");
    assert!(router.remove_device(&id));
    let refused = client.status(with(&token, StatusRequest {})).await.unwrap_err();
    assert_eq!(refused.code(), Code::Unauthenticated);
    let stored = std::fs::read_to_string(home.path().join("router.toml")).unwrap();
    assert!(!stored.contains("Mac"), "{stored}");
    assert!(router.snapshot().activity.iter().any(|e| e.kind == Kind::DeviceRemoved && e.detail == "Mac"));
    router.stop().await;
}

#[tokio::test]
async fn a_new_link_replaces_the_code() {
    let home = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    let mut client = client(&router).await;
    let first = router.new_link();
    let second = router.new_link();
    assert_ne!(first, second);
    let shown = router.snapshot().pairing;
    assert_eq!((shown.link.as_str(), shown.period), (second.as_str(), 300), "the terminal's code is a fixed one");
    let refused = client.pair(PairRequest { code: code_of(&first), device_name: "x".into() }).await.unwrap_err();
    assert_eq!(refused.code(), Code::PermissionDenied);
    router.stop().await;
}

#[tokio::test]
async fn the_owner_asking_again_shows_a_code_after_a_pairing() {
    let home = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    let mut client = client(&router).await;
    router.pairing_seen();
    let first = router.snapshot().pairing.link;
    client.pair(PairRequest { code: code_of(&first), device_name: "iPhone".into() }).await.unwrap();
    assert_eq!(router.snapshot().pairing.phase, "paired");
    router.show_pairing();
    let again = router.snapshot().pairing;
    assert_eq!(again.phase, "code");
    assert_ne!(again.link, first);
    client.pair(PairRequest { code: code_of(&again.link), device_name: "Mac".into() }).await.unwrap();
    assert_eq!(router.devices().len(), 2);
    router.stop().await;
}

#[tokio::test]
async fn widening_needs_confirmation() {
    use listen_router::config::Access;
    use listen_router::settings::SettingsError;
    let home = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    let mut wider = router.settings();
    wider.claude.access = Access::Commands;
    match router.save_settings(wider.clone(), false) {
        Err(SettingsError::NeedsConfirmation(w)) => assert!(w[0].contains("run commands"), "{w:?}"),
        other => panic!("expected NeedsConfirmation, got {other:?}"),
    }
    assert_eq!(router.settings().claude.access, Access::Folder, "nothing changed without confirmation");
    let saved = router.save_settings(wider, true).unwrap();
    assert!(!saved.restart_needed);
    assert_eq!(router.manager.rules().claude_access, Access::Commands, "new sessions follow it");
    let stored = std::fs::read_to_string(home.path().join("router.toml")).unwrap();
    assert!(stored.contains("access = \"commands\""), "{stored}");
    assert!(router.snapshot().activity.iter().any(|e| e.kind == Kind::SettingsWidened));
    router.stop().await;
}

#[tokio::test]
async fn port_change_needs_restart() {
    let home = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    let mut s = router.settings();
    s.port = free_port();
    assert!(router.save_settings(s, false).unwrap().restart_needed);
    router.stop().await;
}

#[tokio::test]
async fn topics_lists_folders_and_sessions() {
    let home = tempfile::tempdir().unwrap();
    let own = tempfile::tempdir().unwrap();
    let router = Running::start(options(home.path(), free_port())).await.unwrap();
    let mut s = router.settings();
    s.topic_folders.insert("project".into(), own.path().to_path_buf());
    router.save_settings(s, true).unwrap();
    let id = router
        .manager
        .open(OpenSessionRequest {
            topic_id: "demo".into(),
            role: "deep".into(),
            tool: Tool::Claude as i32,
            model: "haiku".into(),
            system: String::new(),
            session_id: String::new(),
        })
        .unwrap()
        .session_id;
    let topics = router.topics();
    let ids: Vec<&str> = topics.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(ids, ["demo", "project"]);
    let demo = &topics[0];
    assert!(!demo.own_folder && demo.folder.ends_with("demo"));
    assert_eq!(demo.sessions.len(), 1);
    assert_eq!((demo.sessions[0].id.as_str(), demo.sessions[0].role.as_str()), (id.as_str(), "deep"));
    assert!(topics[1].own_folder && topics[1].folder == own.path().display().to_string());
    router.stop().await;
}
