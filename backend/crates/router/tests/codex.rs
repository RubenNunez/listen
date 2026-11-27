use listen_router::claude::{Out, Spawn};
use listen_router::cli::{Cli, Process};
use listen_router::codex::{arguments, parse_line, Event};
use listen_router::config::{Access, Limits};
use listen_router::folders::Home;
use listen_router::manager::Manager;
use listen_router_proto::v1::{ask_event::Kind, OpenSessionRequest, Tool};
use std::path::{Path, PathBuf};
use tonic::Code;

fn spawn(cwd: &Path, access: Access) -> Spawn {
    Spawn {
        program: PathBuf::from(env!("CARGO_BIN_EXE_fake-codex")),
        cwd: cwd.to_path_buf(),
        model: "default".into(),
        system: "Be brief.".into(),
        resume: None,
        access,
        extra_dirs: vec![PathBuf::from("C:/Users/someone")],
        cli: Cli::Codex,
    }
}

#[test]
fn arguments_per_level() {
    let at = |access| arguments(&spawn(Path::new("."), access), None).join(" ");
    let folder = at(Access::Folder);
    let commands = at(Access::Commands);
    let computer = at(Access::Computer);
    assert!(folder.contains("sandbox_mode=\"read-only\""), "{folder}");
    assert!(commands.contains("sandbox_mode=\"workspace-write\"") && !commands.contains("writable_roots"), "{commands}");
    assert!(computer.contains("sandbox_mode=\"workspace-write\"") && computer.contains("writable_roots=['C:/Users/someone']"));
    for args in [&folder, &commands, &computer] {
        assert!(args.starts_with("exec --json --skip-git-repo-check --ignore-user-config"), "{args}");
        assert!(args.contains("approval_policy=\"never\""));
        assert!(args.ends_with(" -"), "the question comes on standard input: {args}");
        assert!(!args.contains("dangerously") && !args.contains("danger-full-access"), "{args}");
        assert!(!args.contains(" -m "), "\"default\" leaves the model to codex");
    }
    if cfg!(windows) {
        assert!(folder.contains("windows.sandbox=\"elevated\""), "without it codex refuses every action on Windows");
    }
    let resumed = arguments(&spawn(Path::new("."), Access::Commands), Some("t-1")).join(" ");
    assert!(resumed.starts_with("exec resume t-1 --json"), "{resumed}");
}

#[test]
fn a_real_capture_parses() {
    let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/codex-write.jsonl")).unwrap();
    let events: Vec<Event> = text.lines().filter_map(parse_line).collect();
    assert!(matches!(&events[0], Event::Thread(id) if id.len() > 10));
    let steps: Vec<&Event> = events.iter().filter(|e| matches!(e, Event::Step { .. })).collect();
    assert_eq!(steps.len(), 3, "three commands: {events:?}");
    if let Event::Step { tool, detail } = steps[0] {
        assert_eq!(tool, "command");
        assert!(detail.starts_with("Set-Content -LiteralPath 'note.txt'"), "the shell around it is gone: {detail}");
    }
    if let Event::Step { detail, .. } = steps[1] {
        assert!(detail.ends_with("(refused or failed)"), "writing outside the folder was refused: {detail}");
    }
    assert!(matches!(events.last(), Some(Event::Done { output_tokens: 228, .. })));
}

#[tokio::test]
async fn the_last_message_is_the_answer() {
    let dir = tempfile::tempdir().unwrap();
    let mut process = Process::start(&spawn(dir.path(), Access::Folder)).unwrap();
    process.send("hello").await.unwrap();
    let mut outs = Vec::new();
    while let Some(out) = process.next().await {
        outs.push(out);
    }
    assert!(matches!(&outs[0], Out::Started { .. }));
    let texts: Vec<&Out> = outs.iter().filter(|o| matches!(o, Out::Text(_))).collect();
    assert_eq!(texts, [&Out::Text("echo:hello".into())], "only the last message is the answer: {outs:?}");
    assert!(outs.iter().any(|o| matches!(o, Out::Step { tool, .. } if tool == "note")), "the remark on the way is a step");
    assert!(matches!(outs.last(), Some(Out::Done { failed: None, .. })));
    let argv = std::fs::read_to_string(dir.path().join("fake-codex-argv.txt")).unwrap();
    assert!(!argv.contains("resume"));
    let history = std::fs::read_dir(dir.path()).unwrap().flatten().find(|e| e.file_name().to_string_lossy().starts_with("fake-codex-history")).unwrap();
    assert!(std::fs::read_to_string(history.path()).unwrap().contains("<instructions>"), "the system text rides with the first question");
}

fn request(tool: Tool) -> OpenSessionRequest {
    OpenSessionRequest {
        topic_id: "demo".into(),
        role: "deep".into(),
        tool: tool as i32,
        model: String::new(),
        system: "S".into(),
        session_id: String::new(),
    }
}

fn manager(home: &Path, codex_enabled: bool) -> Manager {
    let m = Manager::new(Home::new(home.to_path_buf()), Limits::default(), PathBuf::from(env!("CARGO_BIN_EXE_fake-claude")));
    let mut rules = m.rules();
    rules.codex_enabled = codex_enabled;
    rules.codex = PathBuf::from(env!("CARGO_BIN_EXE_fake-codex"));
    m.set_rules(rules);
    m
}

async fn answer(m: &Manager, id: &str, text: &str) -> (Vec<String>, Option<i32>) {
    let mut events = m.ask(id, text.into()).await.unwrap();
    let (mut texts, mut failure) = (Vec::new(), None);
    while let Some(event) = events.recv().await {
        match event.kind {
            Some(Kind::Text(t)) => texts.push(t),
            Some(Kind::Failure(f)) => failure = Some(f.kind),
            _ => {}
        }
    }
    (texts, failure)
}

#[tokio::test]
async fn codex_is_refused_while_off() {
    let home = tempfile::tempdir().unwrap();
    let refused = manager(home.path(), false).open(request(Tool::Codex)).unwrap_err();
    assert_eq!(refused.code(), Code::FailedPrecondition);
}

#[tokio::test]
async fn a_codex_session_continues_its_thread() {
    let home = tempfile::tempdir().unwrap();
    let m = manager(home.path(), true);
    let id = m.open(request(Tool::Codex)).unwrap().session_id;
    assert_eq!(answer(&m, &id, "RECALL").await.0, ["0"]);
    assert_eq!(answer(&m, &id, "RECALL").await.0, ["1"], "the second question resumed the same thread");
    let argv = std::fs::read_to_string(home.path().join("topics/demo/fake-codex-argv.txt")).unwrap();
    assert!(argv.lines().nth(1).unwrap().contains("resume"), "{argv}");
    m.close(&id).await.unwrap();
}

#[tokio::test]
async fn a_codex_failure_and_limit_are_reported() {
    use listen_router_proto::v1::FailureKind;
    let home = tempfile::tempdir().unwrap();
    let m = manager(home.path(), true);
    let id = m.open(request(Tool::Codex)).unwrap().session_id;
    assert_eq!(answer(&m, &id, "FAIL").await.1, Some(FailureKind::Tool as i32));
    assert_eq!(answer(&m, &id, "LIMIT").await.1, Some(FailureKind::Limit as i32));
    m.close(&id).await.unwrap();
}
