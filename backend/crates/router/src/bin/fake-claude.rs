//! A stand-in for the `claude` command-line tool, for tests only. It asks no model.
//!
//! It takes the same arguments, writes them to `fake-argv.txt` in its working directory,
//! and answers each user line in the real tool's output format: `echo:` and the text.
//! Special texts: `HANG` never answers, `DIE` ends the process, `LIMIT` fails like a plan
//! limit, `RECALL` answers with the number of earlier messages of this session.

use serde_json::{json, Value};
use std::io::{BufRead, Write};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--version"] {
        println!("0.0.0 (fake claude)");
        return;
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("fake-argv.txt")
        .and_then(|mut f| writeln!(f, "{}", args.join(" ")));
    let resumed = args.iter().position(|a| a == "--resume").and_then(|i| args.get(i + 1)).cloned();
    let session = resumed.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let history = format!("fake-history-{session}.txt");

    let stdout = std::io::stdout();
    let say = |value: Value| {
        let mut out = stdout.lock();
        let _ = writeln!(out, "{value}");
        let _ = out.flush();
    };

    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(text) = message["message"]["content"].as_str() else { continue };
        let earlier = std::fs::read_to_string(&history).map(|h| h.lines().count()).unwrap_or(0);
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&history)
            .and_then(|mut f| writeln!(f, "{}", text.replace('\n', " ")));

        say(json!({"type": "system", "subtype": "init", "session_id": session}));
        let question = text.rsplit("</delivered>\n\n").next().unwrap_or(text);
        match question {
            "HANG" => loop {
                std::thread::sleep(std::time::Duration::from_secs(3600));
            },
            "DIE" => std::process::exit(1),
            "LIMIT" => {
                say(json!({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected"}}));
                say(json!({"type": "result", "subtype": "error", "is_error": true, "session_id": session,
                           "result": "usage limit reached", "total_cost_usd": 0.0, "usage": {"input_tokens": 0, "output_tokens": 0}}));
            }
            _ => {
                let pieces = if question == "RECALL" { vec![earlier.to_string()] } else { vec!["echo:".to_string(), text.to_string()] };
                for piece in &pieces {
                    say(json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": piece}}}));
                }
                say(json!({"type": "result", "subtype": "success", "is_error": false, "session_id": session,
                           "result": pieces.concat(), "total_cost_usd": 0.001, "usage": {"input_tokens": 3, "output_tokens": 5}}));
            }
        }
    }
}
