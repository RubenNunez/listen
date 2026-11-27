//! One running `claude` process, spoken to in its stream-json format.
//!
//! The command line is the one measured on 15 November 2026 with `claude` 2.1.310
//! (see `docs/ROUTER_DESIGN.md`, section 4): `--restricted` removes every tool that
//! runs commands or code and confines the file tools to the working directory.
//! The router sets and reads no credential; the process inherits the user's environment.

use crate::config::Access;
use serde_json::Value;
use std::collections::VecDeque;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

/// The tools a session has at the level "folder only". None of them runs commands or code.
pub const TOOLS: &str = "Read,Write,Edit,Glob,Grep,WebSearch";

/// How many addresses of one web search are passed on.
const SOURCES_PER_SEARCH: usize = 5;

#[derive(Debug, Clone)]
pub struct Spawn {
    pub program: PathBuf,
    pub cwd: PathBuf,
    pub model: String,
    pub system: String,
    /// The CLI's own id of a stored session to continue.
    pub resume: Option<String>,
    /// How much the session may do, as the owner set it in the router's window.
    pub access: Access,
    /// Further folders the file tools may reach (`Access::Computer`).
    pub extra_dirs: Vec<PathBuf>,
    /// Which tool runs.
    pub cli: crate::cli::Cli,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Usage {
    pub cost_usd: f64,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

/// What the process says, reduced to what the router passes on.
#[derive(Debug, Clone, PartialEq)]
pub enum Out {
    Started { cli_session: String },
    Text(String),
    /// A tool was used. `detail` is a path relative to the working directory or a search query.
    Step { tool: String, detail: String },
    /// Address of a web page a search returned.
    Source(String),
    /// The plan's limit does not allow the request.
    Limited,
    Done { cli_session: String, usage: Usage, failed: Option<String> },
}

pub fn arguments(spawn: &Spawn) -> Vec<String> {
    // Restricted mode stays at every level: it keeps the user's own settings, hooks and MCP servers
    // out and confines the file tools to the working folders. A level adds only what it names.
    let commands = spawn.access >= Access::Commands;
    let tools = if commands { format!("{TOOLS},Bash") } else { TOOLS.to_string() };
    let allowed = if commands { "WebSearch,Bash" } else { "WebSearch" };
    let mut args: Vec<String> = [
        "-p",
        "--model",
        spawn.model.as_str(),
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--restricted",
        "--strict-mcp-config",
        "--tools",
        tools.as_str(),
        "--permission-mode",
        "acceptEdits",
        // Without this a search (or a command) is refused for want of someone to approve it.
        "--allowedTools",
        allowed,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    if spawn.access >= Access::Computer {
        for dir in &spawn.extra_dirs {
            args.push("--add-dir".into());
            args.push(dir.display().to_string());
        }
    }
    if !spawn.system.is_empty() {
        args.push("--system-prompt".into());
        // A value that begins with "-" must not be taken for an option.
        args.push(if spawn.system.starts_with('-') { format!(" {}", spawn.system) } else { spawn.system.clone() });
    }
    if let Some(id) = &spawn.resume {
        args.push("--resume".into());
        args.push(id.clone());
    }
    args
}

/// The line that carries one user message to the process.
pub fn user_line(text: &str) -> String {
    serde_json::json!({"type": "user", "message": {"role": "user", "content": text}}).to_string()
}

/// Reads one line of the process's output. Lines that say nothing the router needs give nothing.
pub fn parse_line(line: &str, cwd: &Path) -> Vec<Out> {
    let Ok(value) = serde_json::from_str::<Value>(line) else { return Vec::new() };
    let text = |v: &Value| v.as_str().map(str::to_string);
    match value["type"].as_str() {
        Some("system") if value["subtype"] == "init" => {
            text(&value["session_id"]).map(|cli_session| Out::Started { cli_session }).into_iter().collect()
        }
        Some("stream_event") => {
            let delta = &value["event"]["delta"];
            match (delta["type"].as_str(), delta["text"].as_str()) {
                (Some("text_delta"), Some(t)) if !t.is_empty() => vec![Out::Text(t.to_string())],
                _ => Vec::new(),
            }
        }
        Some("assistant") => value["message"]["content"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|block| block["type"] == "tool_use")
            .map(|block| {
                let input = &block["input"];
                let detail = match (input["file_path"].as_str(), input["query"].as_str(), input["command"].as_str()) {
                    (Some(path), _, _) => relative(path, cwd),
                    (None, Some(query), _) => query.to_string(),
                    // A command, as far as the owner allowed commands: shown on one line, not too long.
                    (None, None, Some(command)) => {
                        command.chars().map(|c| if c.is_control() { ' ' } else { c }).take(120).collect()
                    }
                    _ => String::new(),
                };
                Out::Step { tool: block["name"].as_str().unwrap_or("").to_string(), detail }
            })
            .collect(),
        Some("user") => {
            let result = &value["tool_use_result"];
            if !result["query"].is_string() {
                return Vec::new();
            }
            result["results"]
                .as_array()
                .into_iter()
                .flatten()
                .flat_map(|r| r["content"].as_array().into_iter().flatten())
                .filter_map(|hit| hit["url"].as_str())
                .filter(|url| url.starts_with("https://") || url.starts_with("http://"))
                .take(SOURCES_PER_SEARCH)
                .map(|url| Out::Source(url.to_string()))
                .collect()
        }
        Some("rate_limit_event") => match value["rate_limit_info"]["status"].as_str() {
            Some(status) if status != "allowed" && !status.starts_with("allowed") => vec![Out::Limited],
            _ => Vec::new(),
        },
        Some("result") => {
            let failed = if value["is_error"].as_bool().unwrap_or(false) {
                Some(text(&value["result"]).or_else(|| text(&value["subtype"])).unwrap_or_else(|| "failed".into()))
            } else {
                None
            };
            vec![Out::Done {
                cli_session: text(&value["session_id"]).unwrap_or_default(),
                usage: Usage {
                    cost_usd: value["total_cost_usd"].as_f64().unwrap_or(0.0),
                    input_tokens: value["usage"]["input_tokens"].as_u64().unwrap_or(0),
                    output_tokens: value["usage"]["output_tokens"].as_u64().unwrap_or(0),
                },
                failed,
            }]
        }
        _ => Vec::new(),
    }
}

/// The path as seen from the working directory, with `/`. A path elsewhere is given by its file name only.
fn relative(path: &str, cwd: &Path) -> String {
    let path = path.replace('\\', "/");
    let mut base = cwd.to_string_lossy().replace('\\', "/");
    if !base.ends_with('/') {
        base.push('/');
    }
    if path.len() > base.len() && path[..base.len()].eq_ignore_ascii_case(&base) {
        path[base.len()..].to_string()
    } else {
        path.rsplit('/').next().unwrap_or("").to_string()
    }
}

pub struct Process {
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    cwd: PathBuf,
    waiting: VecDeque<Out>,
}

impl Process {
    pub fn start(spawn: &Spawn) -> io::Result<Process> {
        let mut child = Command::new(&spawn.program)
            .args(arguments(spawn))
            .current_dir(&spawn.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let stdin = child.stdin.take().ok_or_else(|| io::Error::other("no input pipe"))?;
        let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no output pipe"))?;
        Ok(Process { child, stdin, lines: BufReader::new(stdout).lines(), cwd: spawn.cwd.clone(), waiting: VecDeque::new() })
    }

    /// Sends one user message.
    pub async fn send(&mut self, text: &str) -> io::Result<()> {
        self.stdin.write_all(user_line(text).as_bytes()).await?;
        self.stdin.write_all(b"\n").await?;
        self.stdin.flush().await
    }

    /// The next thing the process says; `None` when it has ended.
    pub async fn next(&mut self) -> Option<Out> {
        loop {
            if let Some(out) = self.waiting.pop_front() {
                return Some(out);
            }
            match self.lines.next_line().await {
                Ok(Some(line)) => self.waiting.extend(parse_line(&line, &self.cwd)),
                _ => return None,
            }
        }
    }

    pub async fn kill(mut self) {
        let _ = self.child.kill().await;
    }
}
