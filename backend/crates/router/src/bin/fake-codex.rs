//! A stand-in for `codex exec --json`, for tests only. It asks no model.
//!
//! It writes its arguments to `fake-codex-argv.txt` in its working directory, reads the
//! question from standard input and answers in the real tool's event format: a remark,
//! then `echo:` and the question's last line. `RECALL` answers with the number of earlier
//! questions of this thread, `FAIL` ends the turn with a failure, `LIMIT` with a limit.

use serde_json::json;
use std::io::{Read, Write};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--version"] {
        println!("codex-cli 0.0.0 (fake)");
        return;
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("fake-codex-argv.txt")
        .and_then(|mut f| writeln!(f, "{}", args.join(" ")));
    let resumed = args.iter().position(|a| a == "resume").and_then(|i| args.get(i + 1)).cloned();
    let thread = resumed.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let mut prompt = String::new();
    let _ = std::io::stdin().read_to_string(&mut prompt);
    let history = format!("fake-codex-history-{thread}.txt");
    let earlier = std::fs::read_to_string(&history).map(|h| h.lines().count()).unwrap_or(0);
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&history)
        .and_then(|mut f| writeln!(f, "{}", prompt.replace('\n', " ")));

    let say = |value: serde_json::Value| println!("{value}");
    say(json!({"type": "thread.started", "thread_id": thread}));
    say(json!({"type": "turn.started"}));
    let question = prompt.trim().lines().last().unwrap_or("").to_string();
    match question.as_str() {
        "FAIL" => {
            say(json!({"type": "turn.failed", "error": {"message": "something broke"}}));
            return;
        }
        "LIMIT" => {
            say(json!({"type": "error", "message": "You've hit your usage limit."}));
            return;
        }
        _ => {}
    }
    say(json!({"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": "Working on it.\n"}}));
    say(json!({"type": "item.completed", "item": {"id": "item_1", "type": "command_execution",
        "command": "\"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -Command \"Get-ChildItem\"",
        "exit_code": 0, "status": "completed"}}));
    let answer = if question == "RECALL" { earlier.to_string() } else { format!("echo:{question}") };
    say(json!({"type": "item.completed", "item": {"id": "item_2", "type": "agent_message", "text": answer}}));
    say(json!({"type": "turn.completed", "usage": {"input_tokens": 11, "output_tokens": 2}}));
}
