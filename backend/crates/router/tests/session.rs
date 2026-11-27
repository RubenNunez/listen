use listen_router::config::Access;
use listen_router::claude::Spawn;
use listen_router::session::{Hooks, Session, Stored};
use listen_router_proto::v1::{ask_event::Kind, AskEvent, FailureKind};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::mpsc::Receiver;

fn spawn(cwd: &Path) -> Spawn {
    Spawn {
        program: PathBuf::from(env!("CARGO_BIN_EXE_fake-claude")),
        cwd: cwd.to_path_buf(),
        model: "haiku".into(),
        system: "S".into(),
        resume: None,
        access: Access::Folder,
        extra_dirs: vec![],
        cli: Default::default(),
    }
}

fn stored(cli_session: Option<String>) -> Stored {
    Stored {
        session_id: "s1".into(),
        topic_id: "t1".into(),
        role: "deep".into(),
        tool: 1,
        model: "haiku".into(),
        system: "S".into(),
        cli_session,
        created_at: 0,
    }
}

fn open(cwd: &Path, silence_ms: u64) -> Session {
    Session::open(stored(None), spawn(cwd), Duration::from_millis(silence_ms), Hooks::none()).unwrap()
}

async fn all(mut events: Receiver<AskEvent>) -> Vec<Kind> {
    let mut kinds = Vec::new();
    while let Some(event) = events.recv().await {
        kinds.push(event.kind.unwrap());
    }
    kinds
}

fn texts(kinds: &[Kind]) -> Vec<String> {
    kinds.iter().filter_map(|k| if let Kind::Text(t) = k { Some(t.clone()) } else { None }).collect()
}

fn failure_kind(kinds: &[Kind]) -> Option<i32> {
    match kinds.last() {
        Some(Kind::Failure(f)) => Some(f.kind),
        _ => None,
    }
}

#[tokio::test]
async fn deliveries_ride_with_the_next_question_only_once() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    assert_eq!(session.deliver("eins".into()), 1);
    assert_eq!(session.deliver("zwei".into()), 2);
    let first = all(session.ask("Wer?".into()).await).await;
    assert_eq!(texts(&first), ["echo:", "<delivered>\neins\nzwei\n</delivered>\n\nWer?"]);
    let second = all(session.ask("Und?".into()).await).await;
    assert_eq!(texts(&second), ["echo:", "Und?"]);
    session.close().await;
}

#[tokio::test]
async fn stream_ends_once_with_usage_before_end() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    let kinds = all(session.ask("x".into()).await).await;
    let ends = kinds.iter().filter(|k| matches!(k, Kind::End(_) | Kind::Failure(_))).count();
    assert_eq!(ends, 1);
    assert!(matches!(kinds[kinds.len() - 2], Kind::Usage(_)));
    assert!(matches!(kinds[kinds.len() - 1], Kind::End(_)));
    session.close().await;
}

#[tokio::test]
async fn second_ask_cancels_the_first_and_nothing_leaks() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    session.deliver("gehört".into());
    let first = session.ask("HANG".into()).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let second = session.ask("zwei".into()).await;
    let first = all(first).await;
    assert_eq!(failure_kind(&first), Some(FailureKind::Cancelled as i32));
    assert!(texts(&first).is_empty());
    let second = all(second).await;
    // The delivery of the cancelled question was given back and rides with the next one.
    assert_eq!(texts(&second), ["echo:", "<delivered>\ngehört\n</delivered>\n\nzwei"]);
    assert!(matches!(second.last(), Some(Kind::End(_))));
    let argv = std::fs::read_to_string(dir.path().join("fake-argv.txt")).unwrap();
    assert!(argv.lines().nth(1).unwrap().contains("--resume"), "the new process continues the stored history");
    session.close().await;
}

#[tokio::test]
async fn silence_is_cut_and_the_session_recovers() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 300);
    let kinds = all(session.ask("HANG".into()).await).await;
    assert_eq!(failure_kind(&kinds), Some(FailureKind::Silent as i32));
    assert!(!session.is_running());
    let again = all(session.ask("da".into()).await).await;
    assert_eq!(texts(&again), ["echo:", "da"]);
    session.close().await;
}

#[tokio::test]
async fn dead_process_is_resumed_once() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    let kinds = all(session.ask("DIE".into()).await).await;
    assert_eq!(failure_kind(&kinds), Some(FailureKind::Tool as i32));
    let argv = std::fs::read_to_string(dir.path().join("fake-argv.txt")).unwrap();
    assert_eq!(argv.lines().count(), 2, "started once, restarted once");
    assert!(argv.lines().nth(1).unwrap().contains("--resume"));
    session.close().await;
}

#[tokio::test]
async fn limit_is_its_own_failure() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    let kinds = all(session.ask("LIMIT".into()).await).await;
    assert_eq!(failure_kind(&kinds), Some(FailureKind::Limit as i32));
    session.close().await;
}

#[tokio::test]
async fn history_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    all(session.ask("eins".into()).await).await;
    all(session.ask("zwei".into()).await).await;
    let kept = session.close().await;
    assert!(kept.cli_session.is_some());
    let session = Session::open(stored(kept.cli_session), spawn(dir.path()), Duration::from_secs(5), Hooks::none()).unwrap();
    let kinds = all(session.ask("RECALL".into()).await).await;
    assert_eq!(texts(&kinds), ["2"]);
    session.close().await;
}

#[tokio::test]
async fn a_rested_session_starts_again_from_its_history() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    all(session.ask("eins".into()).await).await;
    session.rest().await;
    assert!(!session.is_running());
    let kinds = all(session.ask("RECALL".into()).await).await;
    assert_eq!(texts(&kinds), ["1"]);
    assert!(session.is_running());
    session.close().await;
}

#[tokio::test]
async fn a_listener_that_leaves_stops_the_question() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    drop(session.ask("eins".into()).await);
    let kinds = all(session.ask("zwei".into()).await).await;
    assert_eq!(texts(&kinds), ["echo:", "zwei"]);
    session.close().await;
}

#[tokio::test]
async fn a_missing_program_is_an_error_at_open() {
    let dir = tempfile::tempdir().unwrap();
    let mut spawn = spawn(dir.path());
    spawn.program = PathBuf::from("no-such-program-here");
    assert!(Session::open(stored(None), spawn, Duration::from_secs(1), Hooks::none()).is_err());
}

#[tokio::test]
async fn only_the_newest_500_deliveries_are_held() {
    let dir = tempfile::tempdir().unwrap();
    let session = open(dir.path(), 5000);
    for i in 0..510 {
        session.deliver(format!("d{i}"));
    }
    assert_eq!(session.deliver("last".into()), 500);
    let kinds = all(session.ask("x".into()).await).await;
    let sent = &texts(&kinds)[1];
    assert!(!sent.contains("\nd10\n") && sent.contains("\nd11\n") && sent.contains("\nlast\n"));
    session.close().await;
}
