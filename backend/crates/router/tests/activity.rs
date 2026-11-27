use listen_router::activity::{Activity, Entry, Kind};
use listen_router::config::Limits;
use listen_router::folders::Home;
use listen_router::manager::Manager;
use listen_router_proto::v1::{OpenSessionRequest, Tool};
use std::path::PathBuf;

#[test]
fn activity_keeps_the_last_200() {
    let activity = Activity::default();
    for i in 0..250 {
        activity.push(Entry::now(Kind::Step).detail(&i.to_string()));
    }
    let recent = activity.recent();
    assert_eq!(recent.len(), 200);
    assert_eq!(recent[0].detail, "50");
    assert_eq!(recent[199].detail, "249");
}

#[tokio::test]
async fn activity_has_no_reply_text() {
    let home = tempfile::tempdir().unwrap();
    let manager = Manager::new(
        Home::new(home.path().to_path_buf()),
        Limits::default(),
        PathBuf::from(env!("CARGO_BIN_EXE_fake-claude")),
    );
    let activity = manager.activity();
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
    manager.deliver(&id, "Lieferung-XYZ".into()).unwrap();
    let mut events = manager.ask(&id, "Frage-XYZ".into()).await.unwrap();
    while events.recv().await.is_some() {}
    assert!(!activity.answering(), "the question has been answered");
    manager.close(&id).await.unwrap();

    let entries = activity.recent();
    let kinds: Vec<Kind> = entries.iter().map(|e| e.kind).collect();
    assert_eq!(kinds.first(), Some(&Kind::Opened));
    assert!(kinds.contains(&Kind::Asked) && kinds.contains(&Kind::Answered), "{kinds:?}");
    assert_eq!(kinds.last(), Some(&Kind::Closed));
    let all = serde_json::to_string(&entries).unwrap();
    assert!(!all.contains("XYZ") && !all.contains("echo:"), "{all}");
    assert!(entries.iter().all(|e| e.topic == "demo" && e.role == "flash" && e.session == id[..8]));
    assert!(entries.iter().find(|e| e.kind == Kind::Answered).unwrap().millis.is_some());
}
