//! The `codex` command-line tool, driven turn by turn with `codex exec --json`.
//!
//! Measured on 15 November 2026 with `codex-cli` 0.162.1 on Windows (design, section 4):
//! one process per question; `codex exec resume <thread>` continues a conversation with
//! its history; the reply arrives as whole `agent_message` items, not in pieces; commands
//! come as `command_execution` items. With `--ignore-user-config` codex has no Windows
//! sandbox unless `windows.sandbox` is given, and refuses every action; with it, the
//! `workspace-write` mode writes in the folder, refuses writing outside it, and reads anywhere.
//!
//! The router passes no credential and reads none; codex uses the user's own sign-in.

use crate::claude::{Out, Spawn, Usage};
use crate::config::Access;
use serde_json::Value;
use std::collections::VecDeque;
use std::io;
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdout, Command};

/// The sandbox mode for a level. codex always works by running commands; "folder only" therefore
/// means it may read but not write, and the wider levels write in the topic's folder (and the home folder).
pub fn sandbox(access: Access) -> &'static str {
    match access {
        Access::Folder => "read-only",
        Access::Commands | Access::Computer => "workspace-write",
    }
}

/// The command line for one question. `thread` continues an earlier conversation.
pub fn arguments(spawn: &Spawn, thread: Option<&str>) -> Vec<String> {
    let mut args: Vec<String> = vec!["exec".into()];
    if let Some(thread) = thread {
        args.extend(["resume".into(), thread.to_string()]);
    }
    args.extend(["--json", "--skip-git-repo-check", "--ignore-user-config"].map(String::from));
    // Nobody is there to approve a step: it is decided by the sandbox alone.
    args.extend(["-c".into(), "approval_policy=\"never\"".into()]);
    args.extend(["-c".into(), format!("sandbox_mode=\"{}\"", sandbox(spawn.access))]);
    if cfg!(windows) {
        args.extend(["-c".into(), "windows.sandbox=\"elevated\"".into()]);
    }
    if spawn.access >= Access::Computer && !spawn.extra_dirs.is_empty() {
        // TOML literal strings, so a Windows path needs no escaping.
        let roots: Vec<String> = spawn.extra_dirs.iter().map(|d| format!("'{}'", d.display())).collect();
        args.extend(["-c".into(), format!("sandbox_workspace_write.writable_roots=[{}]", roots.join(","))]);
    }
    if !spawn.model.is_empty() && spawn.model != "default" {
        args.extend(["-m".into(), spawn.model.clone()]);
    }
    // The question comes on standard input.
    args.push("-".into());
    args
}

/// The first question of a conversation carries the system text; codex has no option of its own for it.
pub fn first_prompt(system: &str, text: &str) -> String {
    if system.is_empty() {
        text.to_string()
    } else {
        format!("<instructions>\n{system}\n</instructions>\n\n{text}")
    }
}

/// A command as the window shows it: without the shell around it, one line, not too long.
fn shown_command(command: &str) -> String {
    let inner = command.split_once(" -Command ").map(|(_, c)| c).unwrap_or(command);
    let inner = inner.trim().trim_matches('"');
    inner.chars().map(|c| if c.is_control() { ' ' } else { c }).take(120).collect()
}

/// What one line of `codex exec --json` says. Agent messages are held back by the caller:
/// only the last one of a turn is the answer.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Thread(String),
    Message(String),
    Step { tool: String, detail: String },
    Done { input_tokens: u64, output_tokens: u64 },
    Failed(String),
}

pub fn parse_line(line: &str) -> Option<Event> {
    let value: Value = serde_json::from_str(line).ok()?;
    let item = &value["item"];
    match value["type"].as_str()? {
        "thread.started" => value["thread_id"].as_str().map(|t| Event::Thread(t.to_string())),
        "item.completed" => match item["type"].as_str()? {
            "agent_message" => item["text"].as_str().map(|t| Event::Message(t.trim().to_string())),
            "command_execution" => {
                let status = if item["exit_code"].as_i64() == Some(0) { "" } else { " (refused or failed)" };
                Some(Event::Step {
                    tool: "command".into(),
                    detail: format!("{}{status}", shown_command(item["command"].as_str().unwrap_or(""))),
                })
            }
            "file_change" => {
                let paths: Vec<String> = item["changes"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|c| c["path"].as_str())
                    .map(|p| p.replace('\\', "/").rsplit('/').next().unwrap_or("").to_string())
                    .collect();
                Some(Event::Step { tool: "edit".into(), detail: paths.join(", ") })
            }
            "web_search" => Some(Event::Step { tool: "WebSearch".into(), detail: "search".into() }),
            _ => None,
        },
        "turn.completed" => Some(Event::Done {
            input_tokens: value["usage"]["input_tokens"].as_u64().unwrap_or(0),
            output_tokens: value["usage"]["output_tokens"].as_u64().unwrap_or(0),
        }),
        "turn.failed" => Some(Event::Failed(
            value["error"]["message"].as_str().unwrap_or("the turn failed").to_string(),
        )),
        "error" => Some(Event::Failed(value["message"].as_str().unwrap_or("codex reported an error").to_string())),
        _ => None,
    }
}

/// One codex conversation. Each question starts a process that ends with the turn.
pub struct Process {
    spawn: Spawn,
    thread: Option<String>,
    child: Option<Child>,
    lines: Option<Lines<BufReader<ChildStdout>>>,
    waiting: VecDeque<Out>,
    /// The latest agent message of the running turn; it becomes the answer when the turn ends.
    held: Option<String>,
}

impl Process {
    /// Nothing runs until the first question.
    pub fn start(spawn: &Spawn) -> io::Result<Process> {
        Ok(Process { thread: spawn.resume.clone(), spawn: spawn.clone(), child: None, lines: None, waiting: VecDeque::new(), held: None })
    }

    pub async fn send(&mut self, text: &str) -> io::Result<()> {
        if let Some(mut old) = self.child.take() {
            let _ = old.kill().await;
        }
        let prompt = if self.thread.is_none() { first_prompt(&self.spawn.system, text) } else { text.to_string() };
        let mut command = if cfg!(windows) && self.spawn.program.extension().is_none() {
            // Installed by npm, codex is a .cmd file that only the command interpreter starts.
            let mut c = Command::new("cmd");
            c.arg("/C").arg(&self.spawn.program);
            c
        } else {
            Command::new(&self.spawn.program)
        };
        let mut child = command
            .args(arguments(&self.spawn, self.thread.as_deref()))
            .current_dir(&self.spawn.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let mut stdin = child.stdin.take().ok_or_else(|| io::Error::other("no input pipe"))?;
        stdin.write_all(prompt.as_bytes()).await?;
        drop(stdin);
        let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no output pipe"))?;
        self.lines = Some(BufReader::new(stdout).lines());
        self.child = Some(child);
        self.held = None;
        Ok(())
    }

    fn take(&mut self, event: Event) {
        match event {
            Event::Thread(id) => {
                self.thread = Some(id.clone());
                self.waiting.push_back(Out::Started { cli_session: id });
            }
            Event::Message(text) => {
                // An earlier message of the same turn was a remark on the way, not the answer.
                if let Some(before) = self.held.replace(text) {
                    let detail: String = before.lines().next().unwrap_or("").chars().take(120).collect();
                    self.waiting.push_back(Out::Step { tool: "note".into(), detail });
                }
            }
            Event::Step { tool, detail } => self.waiting.push_back(Out::Step { tool, detail }),
            Event::Done { input_tokens, output_tokens } => {
                if let Some(answer) = self.held.take() {
                    self.waiting.push_back(Out::Text(answer));
                }
                self.waiting.push_back(Out::Done {
                    cli_session: self.thread.clone().unwrap_or_default(),
                    // A plan reports no price per request.
                    usage: Usage { cost_usd: 0.0, input_tokens, output_tokens },
                    failed: None,
                });
            }
            Event::Failed(message) => {
                if message.to_lowercase().contains("limit") {
                    self.waiting.push_back(Out::Limited);
                }
                self.waiting.push_back(Out::Done {
                    cli_session: self.thread.clone().unwrap_or_default(),
                    usage: Usage::default(),
                    failed: Some(message),
                });
            }
        }
    }

    /// The next thing the turn says; `None` when its process has ended.
    pub async fn next(&mut self) -> Option<Out> {
        loop {
            if let Some(out) = self.waiting.pop_front() {
                return Some(out);
            }
            let lines = self.lines.as_mut()?;
            match lines.next_line().await {
                Ok(Some(line)) => {
                    if let Some(event) = parse_line(&line) {
                        self.take(event);
                    }
                }
                _ => {
                    self.lines = None;
                    return None;
                }
            }
        }
    }

    pub async fn kill(mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill().await;
        }
    }

    pub fn program(&self) -> &PathBuf {
        &self.spawn.program
    }
}
