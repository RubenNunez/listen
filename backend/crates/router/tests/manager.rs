use listen_router::config::Limits;
use listen_router::folders::Home;
use listen_router::manager::Manager;
use listen_router_proto::v1::{ask_event::Kind, AskEvent, OpenSessionRequest, Tool};
use std::path::{Path, PathBuf};
use tokio::sync::mpsc::Receiver;
use tonic::Code;

fn manager(home: &Path, limits: Limits) -> Manager {
    Manager::new(Home::new(home.to_path_buf()), limits, PathBuf::from(env!("CARGO_BIN_EXE_fake-claude")))
}

fn request(topic: &str, role: &str) -> OpenSessionRequest {
    OpenSessionRequest {
        topic_id: topic.into(),
        role: role.into(),
        tool: Tool::Claude as i32,
        model: "haiku".into(),
        system: "S".into(),
        session_id: String::new(),
    }
}

async fn texts(mut events: Receiver<AskEvent>) -> Vec<String> {
    let mut texts = Vec::new();
    while let Some(event) = events.recv().await {
        if let Some(Kind::Text(text)) = event.kind {
            texts.push(text);
        }
    }
    texts
}

#[tokio::test]
async fn fifth_session_in_a_topic_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    for i in 0..4 {
        m.open(request("t1", &format!("r{i}"))).unwrap();
    }
    assert_eq!(m.open(request("t1", "r4")).unwrap_err().code(), Code::ResourceExhausted);
    assert!(m.open(request("t2", "r0")).is_ok());
    m.shut_down().await;
}

#[tokio::test]
async fn seventh_session_overall_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    for i in 0..6 {
        m.open(request(&format!("t{}", i / 3), "r")).unwrap();
    }
    assert_eq!(m.open(request("t9", "r")).unwrap_err().code(), Code::ResourceExhausted);
    m.shut_down().await;
}

#[tokio::test]
async fn bad_requests_are_refused_before_any_folder_is_made() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    for topic in ["", "..", "../x", "a/b", "C:\\x"] {
        assert_eq!(m.open(request(topic, "r")).unwrap_err().code(), Code::InvalidArgument, "{topic}");
    }
    assert_eq!(m.open(request("t1", " ")).unwrap_err().code(), Code::InvalidArgument);
    let mut flag = request("t1", "r");
    flag.model = "--dangerously-skip-permissions".into();
    assert_eq!(m.open(flag).unwrap_err().code(), Code::InvalidArgument);
    let mut unnamed = request("t1", "r");
    unnamed.tool = 0;
    assert_eq!(m.open(unnamed).unwrap_err().code(), Code::InvalidArgument);
    assert!(!dir.path().join("topics").exists());
}

#[tokio::test]
async fn codex_is_refused_as_not_enabled() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    let mut codex = request("t1", "r");
    codex.tool = Tool::Codex as i32;
    let error = m.open(codex).unwrap_err();
    assert_eq!(error.code(), Code::FailedPrecondition);
    assert!(error.message().contains("not enabled"));
}

#[tokio::test]
async fn open_with_a_stored_id_continues_it_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    let id = m.open(request("t1", "deep")).unwrap().session_id;
    texts(m.ask(&id, "eins".into()).await.unwrap()).await;
    texts(m.ask(&id, "zwei".into()).await.unwrap()).await;
    m.shut_down().await;

    let m = manager(dir.path(), Limits::default());
    assert_eq!(m.ask(&id, "x".into()).await.unwrap_err().code(), Code::NotFound);
    let mut again = request("t1", "");
    again.session_id = id.clone();
    let opened = m.open(again).unwrap();
    assert!(opened.continued);
    assert_eq!(opened.session_id, id);
    assert_eq!(texts(m.ask(&id, "RECALL".into()).await.unwrap()).await, ["2"]);
    assert_eq!(m.infos()[0].role, "deep");
    m.shut_down().await;
}

#[tokio::test]
async fn a_session_of_one_topic_cannot_be_opened_in_another() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    let id = m.open(request("t1", "r")).unwrap().session_id;
    let mut other = request("t2", "");
    other.session_id = id.clone();
    assert_eq!(m.open(other).unwrap_err().code(), Code::InvalidArgument);
    m.shut_down().await;
    let m = manager(dir.path(), Limits::default());
    let mut other = request("t2", "");
    other.session_id = id;
    assert_eq!(m.open(other).unwrap_err().code(), Code::NotFound);
}

#[tokio::test]
async fn idle_sessions_rest_and_wake_on_the_next_question() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits { idle_seconds: 0, ..Limits::default() });
    let id = m.open(request("t1", "r")).unwrap().session_id;
    texts(m.ask(&id, "eins".into()).await.unwrap()).await;
    m.close_idle().await;
    assert!(!m.infos()[0].open);
    assert_eq!(texts(m.ask(&id, "RECALL".into()).await.unwrap()).await, ["1"]);
    assert!(m.infos()[0].open);
    m.shut_down().await;
}

#[tokio::test]
async fn damaged_session_file_gives_data_loss_and_the_rest_works() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    let id = m.open(request("t1", "r")).unwrap().session_id;
    m.shut_down().await;
    let file = dir.path().join("topics/t1/sessions").join(format!("{id}.json"));
    let good = std::fs::read_to_string(&file).unwrap();

    let m = manager(dir.path(), Limits::default());
    let mut again = request("t1", "");
    again.session_id = id.clone();
    for bad in [
        "not json".to_string(),
        good.replace("\"haiku\"", "\"--dangerously-skip-permissions\""),
        good.replace("\"cli_session\": null", "\"cli_session\": \"--add-dir=C:/\""),
        good.replace("\"t1\"", "\"t2\""),
    ] {
        assert_ne!(bad, good);
        std::fs::write(&file, &bad).unwrap();
        assert_eq!(m.open(again.clone()).unwrap_err().code(), Code::DataLoss, "{bad}");
    }
    assert!(m.open(request("t1", "other")).is_ok());
    m.shut_down().await;
}

#[tokio::test]
async fn log_holds_steps_and_no_text() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    let id = m.open(request("t1", "r")).unwrap().session_id;
    assert_eq!(m.deliver(&id, "Geheimwort eins".into()).unwrap(), 1);
    texts(m.ask(&id, "Geheimwort zwei".into()).await.unwrap()).await;
    m.close(&id).await.unwrap();
    let log = std::fs::read_to_string(dir.path().join("topics/t1/sessions").join(format!("{id}.log"))).unwrap();
    assert!(!log.contains("Geheimwort"));
    let kinds: Vec<&str> = log.lines().map(|l| l.split('\t').nth(1).unwrap()).collect();
    assert_eq!(kinds, ["open", "deliver", "ask", "end", "close"]);
    assert_eq!(m.close(&id).await.unwrap_err().code(), Code::NotFound);
}

#[tokio::test]
async fn too_long_text_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let m = manager(dir.path(), Limits::default());
    let id = m.open(request("t1", "r")).unwrap().session_id;
    assert_eq!(m.deliver(&id, "x".repeat(100_001)).unwrap_err().code(), Code::InvalidArgument);
    assert_eq!(m.ask(&id, "x".repeat(100_001)).await.unwrap_err().code(), Code::InvalidArgument);
    m.shut_down().await;
}

#[tokio::test]
async fn own_folder_is_the_working_directory() {
    let home = tempfile::tempdir().unwrap();
    let own = tempfile::tempdir().unwrap();
    let m = manager(home.path(), Limits::default());
    let mut rules = m.rules();
    rules.own_folders.insert("demo".into(), own.path().to_path_buf());
    m.set_rules(rules);
    let id = m.open(request("demo", "deep")).unwrap().session_id;
    texts(m.ask(&id, "hello".into()).await.unwrap()).await;
    assert!(own.path().join("fake-argv.txt").exists(), "the session ran in the topic's own folder");
    assert!(!own.path().join("sessions").exists(), "nothing of the router's is put into the user's folder");
    assert!(home.path().join("topics/demo/sessions").join(format!("{id}.json")).exists(), "records stay with the router");
    m.close(&id).await.unwrap();
}

#[tokio::test]
async fn missing_own_folder_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let gone = home.path().join("no-such-folder");
    let m = manager(home.path(), Limits::default());
    let mut rules = m.rules();
    rules.own_folders.insert("demo".into(), gone.clone());
    m.set_rules(rules);
    let refused = m.open(request("demo", "deep")).unwrap_err();
    assert_eq!(refused.code(), Code::FailedPrecondition);
    assert!(refused.message().contains("no-such-folder"), "{}", refused.message());
    assert!(!gone.exists(), "nothing was created in its place");
}

#[tokio::test]
async fn topics_root_moves_the_topic_folders() {
    let home = tempfile::tempdir().unwrap();
    let elsewhere = tempfile::tempdir().unwrap();
    let m = manager(home.path(), Limits::default());
    let mut rules = m.rules();
    rules.topics_root = Some(elsewhere.path().to_path_buf());
    m.set_rules(rules);
    let id = m.open(request("demo", "deep")).unwrap().session_id;
    texts(m.ask(&id, "hello".into()).await.unwrap()).await;
    assert!(elsewhere.path().join("demo/fake-argv.txt").exists());
    assert!(!home.path().join("topics/demo").exists());
    m.close(&id).await.unwrap();
}

#[tokio::test]
async fn running_session_keeps_its_level() {
    let home = tempfile::tempdir().unwrap();
    let m = manager(home.path(), Limits::default());
    let first = m.open(request("demo", "deep")).unwrap().session_id;
    texts(m.ask(&first, "one".into()).await.unwrap()).await;
    let mut rules = m.rules();
    rules.claude_access = listen_router::config::Access::Commands;
    m.set_rules(rules);
    texts(m.ask(&first, "two".into()).await.unwrap()).await;
    let second = m.open(request("demo", "fast")).unwrap().session_id;
    texts(m.ask(&second, "three".into()).await.unwrap()).await;
    let argv = std::fs::read_to_string(home.path().join("topics/demo/fake-argv.txt")).unwrap();
    let starts: Vec<&str> = argv.lines().collect();
    assert_eq!(starts.len(), 2, "one process per session: {argv}");
    assert!(!starts[0].contains("Bash"), "the running session kept its level: {}", starts[0]);
    assert!(starts[1].contains("Bash"), "the new session has the new level: {}", starts[1]);
    m.close(&first).await.unwrap();
    m.close(&second).await.unwrap();
}
