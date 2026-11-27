use listen_router::config::Access;
use listen_router::claude::{arguments, parse_line, Out, Process, Spawn};
use std::path::{Path, PathBuf};

fn spawn(cwd: &Path, resume: Option<&str>) -> Spawn {
    Spawn {
        program: PathBuf::from(env!("CARGO_BIN_EXE_fake-claude")),
        cwd: cwd.to_path_buf(),
        model: "haiku".into(),
        system: "S".into(),
        resume: resume.map(str::to_string),
        access: Access::Folder,
        extra_dirs: vec![],
        cli: Default::default(),
    }
}

#[test]
fn arguments_per_level() {
    let folder = arguments(&spawn(Path::new("."), None));
    let mut commands = spawn(Path::new("."), None);
    commands.access = Access::Commands;
    let mut computer = spawn(Path::new("."), None);
    computer.access = Access::Computer;
    computer.extra_dirs = vec![PathBuf::from("/home/ruben")];
    let commands = arguments(&commands);
    let computer = arguments(&computer);
    let after = |args: &[String], flag: &str| args.iter().position(|a| a == flag).map(|i| args[i + 1].clone());

    assert_eq!(after(&folder, "--tools").as_deref(), Some("Read,Write,Edit,Glob,Grep,WebSearch"));
    assert_eq!(after(&commands, "--tools").as_deref(), Some("Read,Write,Edit,Glob,Grep,WebSearch,Bash"));
    assert_eq!(after(&commands, "--allowedTools").as_deref(), Some("WebSearch,Bash"));
    assert!(!commands.contains(&"--add-dir".to_string()));
    assert_eq!(after(&computer, "--add-dir").as_deref(), Some("/home/ruben"));
    assert_eq!(after(&computer, "--tools"), after(&commands, "--tools"));
    for args in [&folder, &commands, &computer] {
        assert!(args.contains(&"--restricted".to_string()), "restricted mode stays at every level");
        assert!(!args.iter().any(|a| a.contains("bypass") || a.contains("dangerously")), "{args:?}");
    }
}

#[test]
fn arguments_are_the_measured_ones() {
    let a = arguments(&spawn(Path::new("."), None));
    assert_eq!(
        a,
        [
            "-p", "--model", "haiku", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--restricted", "--strict-mcp-config", "--tools",
            "Read,Write,Edit,Glob,Grep,WebSearch", "--permission-mode", "acceptEdits", "--allowedTools", "WebSearch",
            "--system-prompt", "S",
        ]
    );
}

#[test]
fn no_tool_that_runs_commands_is_ever_named() {
    let a = arguments(&spawn(Path::new("."), Some("abc"))).join(" ");
    for forbidden in ["Bash", "PowerShell", "WebFetch", "bypassPermissions", "dangerously"] {
        assert!(!a.contains(forbidden), "{forbidden}");
    }
}

#[test]
fn resume_adds_the_stored_session() {
    let a = arguments(&spawn(Path::new("."), Some("abc")));
    assert_eq!(a[a.len() - 2..], ["--resume", "abc"]);
}

#[test]
fn write_fixture_parses_to_start_step_text_and_done() {
    let cwd = Path::new("C:\\topic");
    let outs: Vec<Out> = include_str!("fixtures/claude-write.jsonl").lines().flat_map(|l| parse_line(l, cwd)).collect();
    assert_eq!(outs.first(), Some(&Out::Started { cli_session: "00000000-0000-0000-0000-000000000000".into() }));
    assert!(outs.contains(&Out::Step { tool: "Write".into(), detail: "a.txt".into() }));
    assert!(outs.contains(&Out::Text("OK".into())));
    match outs.last() {
        Some(Out::Done { cli_session, usage, failed: None }) => {
            assert_eq!(cli_session, "00000000-0000-0000-0000-000000000000");
            assert!(usage.cost_usd > 0.0 && usage.output_tokens == 149);
        }
        other => panic!("{other:?}"),
    }
    assert!(!outs.contains(&Out::Limited));
}

#[test]
fn search_fixture_gives_the_query_and_at_most_five_sources() {
    let outs: Vec<Out> =
        include_str!("fixtures/claude-search.jsonl").lines().flat_map(|l| parse_line(l, Path::new("C:\\topic"))).collect();
    assert!(outs.contains(&Out::Step { tool: "WebSearch".into(), detail: "Hauptstadt von Australien".into() }));
    let sources: Vec<&Out> = outs.iter().filter(|o| matches!(o, Out::Source(_))).collect();
    assert_eq!(sources.len(), 5);
    assert_eq!(sources[0], &Out::Source("https://www.ab-in-den-urlaub.de/magazin/?p=103222".into()));
}

#[test]
fn a_path_elsewhere_is_shown_by_its_name_only() {
    let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"C:\\Users\\someone\\secret.txt"}}]}}"#;
    assert_eq!(parse_line(line, Path::new("C:\\topic")), [Out::Step { tool: "Read".into(), detail: "secret.txt".into() }]);
}

#[test]
fn rubbish_lines_are_ignored() {
    assert!(parse_line("not json", Path::new(".")).is_empty());
    assert!(parse_line("{}", Path::new(".")).is_empty());
    assert!(parse_line("", Path::new(".")).is_empty());
}

#[test]
fn a_refused_limit_is_reported() {
    let line = r#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}"#;
    assert_eq!(parse_line(line, Path::new(".")), [Out::Limited]);
}

#[tokio::test]
async fn process_answers_twice_and_keeps_running() {
    let dir = tempfile::tempdir().unwrap();
    let mut process = Process::start(&spawn(dir.path(), None)).unwrap();
    for word in ["eins", "zwei"] {
        process.send(word).await.unwrap();
        assert!(matches!(process.next().await, Some(Out::Started { .. })));
        assert_eq!(process.next().await, Some(Out::Text("echo:".into())));
        assert_eq!(process.next().await, Some(Out::Text(word.into())));
        assert!(matches!(process.next().await, Some(Out::Done { failed: None, .. })));
    }
    process.kill().await;
}

#[tokio::test]
async fn a_process_that_ends_gives_none() {
    let dir = tempfile::tempdir().unwrap();
    let mut process = Process::start(&spawn(dir.path(), None)).unwrap();
    process.send("DIE").await.unwrap();
    assert!(matches!(process.next().await, Some(Out::Started { .. })));
    assert_eq!(process.next().await, None);
}

#[test]
fn system_text_cannot_become_an_option() {
    let mut s = spawn(Path::new("."), None);
    s.system = "--add-dir C:/".into();
    let a = arguments(&s);
    assert_eq!(a[a.len() - 1], " --add-dir C:/");
    s.system = String::new();
    assert!(!arguments(&s).contains(&"--system-prompt".to_string()));
}

#[test]
fn a_command_step_shows_the_command() {
    let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo router-test","description":"x"}}]}}"#;
    assert_eq!(parse_line(line, Path::new(".")), [Out::Step { tool: "Bash".into(), detail: "echo router-test".into() }]);
}
