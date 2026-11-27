//! One session: a conversation with one tool and one model that keeps its history.
//!
//! A single task owns the process and takes commands one after another, so questions
//! never run side by side and a cancel is simply the next command arriving.

use crate::claude::{Out, Spawn};
use crate::cli::Process;
use listen_router_proto::v1::{ask_event::Kind, AskEvent, End, Failure, FailureKind, Step, Usage};
use serde::{Deserialize, Serialize};
use std::io;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};

/// How many deliveries are held for the next question at most.
pub const MAX_WAITING: usize = 500;

/// What is kept on disk about a session, in `sessions/<id>.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stored {
    pub session_id: String,
    pub topic_id: String,
    pub role: String,
    pub tool: i32,
    pub model: String,
    pub system: String,
    /// The CLI's own id of the conversation; what a new process continues from.
    pub cli_session: Option<String>,
    pub created_at: u64,
}

/// Takes a kind and a detail of a step.
pub type LogStep = Box<dyn Fn(&str, &str) + Send + Sync>;

/// What a session tells its owner.
pub struct Hooks {
    /// The stored state changed and should be written.
    pub saved: Box<dyn Fn(&Stored) + Send + Sync>,
    /// A step for the log: a kind and a detail. Never text of a delivery, question or reply.
    pub log: LogStep,
}

impl Hooks {
    pub fn none() -> Hooks {
        Hooks { saved: Box::new(|_| {}), log: Box::new(|_, _| {}) }
    }
}

/// What is sent to the process: the deliveries since the last question, then the question.
pub fn question(waiting: &[String], text: &str) -> String {
    if waiting.is_empty() {
        text.to_string()
    } else {
        format!("<delivered>\n{}\n</delivered>\n\n{text}", waiting.join("\n"))
    }
}

struct Shared {
    stored: Stored,
    waiting: Vec<String>,
    last_used: Instant,
    running: bool,
    /// Whether a question has ever ended well or failed for want of a sign-in.
    answered: Option<bool>,
}

enum Command {
    Ask { text: String, reply: mpsc::Sender<AskEvent> },
    /// Ends the process; the session stays usable.
    Rest(oneshot::Sender<()>),
    Close(oneshot::Sender<()>),
}

pub struct Session {
    commands: mpsc::Sender<Command>,
    shared: Arc<Mutex<Shared>>,
}

impl Session {
    /// Starts the process right away, so that the first question does not wait for it.
    pub fn open(stored: Stored, spawn: Spawn, silence: Duration, hooks: Hooks) -> io::Result<Session> {
        let mut spawn = spawn;
        spawn.resume = stored.cli_session.clone();
        let process = Process::start(&spawn)?;
        let shared =
            Arc::new(Mutex::new(Shared { stored, waiting: Vec::new(), last_used: Instant::now(), running: true, answered: None }));
        let (commands, inbox) = mpsc::channel(8);
        let actor = Actor { inbox, shared: shared.clone(), spawn, silence, hooks, process: Some(process), fresh_resume: false };
        tokio::spawn(actor.run());
        Ok(Session { commands, shared })
    }

    /// Holds text for the next question. Asks no model. Returns how many deliveries wait.
    pub fn deliver(&self, text: String) -> u32 {
        let mut shared = self.shared.lock().unwrap();
        shared.last_used = Instant::now();
        shared.waiting.push(text);
        // Nobody asking must not fill the memory: the oldest deliveries go first.
        if shared.waiting.len() > MAX_WAITING {
            let extra = shared.waiting.len() - MAX_WAITING;
            shared.waiting.drain(..extra);
        }
        shared.waiting.len() as u32
    }

    /// Asks. A question still running in this session is cancelled.
    /// The stream ends with exactly one `End` or one `Failure`.
    pub async fn ask(&self, text: String) -> mpsc::Receiver<AskEvent> {
        let (reply, events) = mpsc::channel(64);
        self.shared.lock().unwrap().last_used = Instant::now();
        if let Err(mpsc::error::SendError(Command::Ask { reply, .. })) =
            self.commands.send(Command::Ask { text, reply }).await
        {
            let _ = reply.send(failure(FailureKind::Tool, "the session is closed")).await;
        }
        events
    }

    /// Ends the process and keeps the session; the next question starts a new one from the stored history.
    pub async fn rest(&self) {
        let (done, wait) = oneshot::channel();
        if self.commands.send(Command::Rest(done)).await.is_ok() {
            let _ = wait.await;
        }
    }

    pub async fn close(&self) -> Stored {
        let (done, wait) = oneshot::channel();
        if self.commands.send(Command::Close(done)).await.is_ok() {
            let _ = wait.await;
        }
        self.stored()
    }

    pub fn stored(&self) -> Stored {
        self.shared.lock().unwrap().stored.clone()
    }

    pub fn last_used(&self) -> Instant {
        self.shared.lock().unwrap().last_used
    }

    /// Whether a process is running for this session.
    pub fn is_running(&self) -> bool {
        self.shared.lock().unwrap().running
    }

    /// `Some(true)` once a question has ended well, `Some(false)` when one failed for want of a sign-in.
    pub fn answered(&self) -> Option<bool> {
        self.shared.lock().unwrap().answered
    }
}

fn event(kind: Kind) -> AskEvent {
    AskEvent { kind: Some(kind) }
}

fn failure(kind: FailureKind, message: &str) -> AskEvent {
    event(Kind::Failure(Failure { kind: kind as i32, message: message.to_string() }))
}

enum Turn {
    Finished,
    /// Another command arrived while the question ran.
    Interrupted(Command),
    /// The session's owner is gone.
    Gone,
}

struct Actor {
    inbox: mpsc::Receiver<Command>,
    shared: Arc<Mutex<Shared>>,
    spawn: Spawn,
    silence: Duration,
    hooks: Hooks,
    process: Option<Process>,
    /// The running process was started from stored history and has not said anything yet.
    fresh_resume: bool,
}

impl Actor {
    async fn run(mut self) {
        let mut next = None;
        loop {
            let command = match next.take() {
                Some(command) => command,
                None => match self.inbox.recv().await {
                    Some(command) => command,
                    None => break,
                },
            };
            match command {
                Command::Ask { text, reply } => match self.turn(text, reply).await {
                    Turn::Finished => {}
                    Turn::Interrupted(command) => next = Some(command),
                    Turn::Gone => break,
                },
                Command::Rest(done) => {
                    self.stop().await;
                    let _ = done.send(());
                }
                Command::Close(done) => {
                    self.stop().await;
                    let _ = done.send(());
                    return;
                }
            }
        }
        self.stop().await;
    }

    async fn stop(&mut self) {
        if let Some(process) = self.process.take() {
            process.kill().await;
        }
        self.shared.lock().unwrap().running = false;
    }

    fn start(&mut self) -> io::Result<()> {
        if self.process.is_none() {
            self.spawn.resume = self.shared.lock().unwrap().stored.cli_session.clone();
            self.process = Some(Process::start(&self.spawn)?);
            self.fresh_resume = self.spawn.resume.is_some();
            self.shared.lock().unwrap().running = true;
        }
        Ok(())
    }

    fn remember(&self, cli_session: String) {
        if cli_session.is_empty() {
            return;
        }
        let mut shared = self.shared.lock().unwrap();
        if shared.stored.cli_session.as_deref() != Some(cli_session.as_str()) {
            shared.stored.cli_session = Some(cli_session);
            (self.hooks.saved)(&shared.stored);
        }
    }

    /// Deliveries of a question that failed go back in front, so that nothing heard is lost.
    /// A model may then see a delivery twice, which costs little; never seeing it costs the context.
    fn give_back(&self, deliveries: Vec<String>) {
        if !deliveries.is_empty() {
            let mut shared = self.shared.lock().unwrap();
            let later = std::mem::replace(&mut shared.waiting, deliveries);
            shared.waiting.extend(later);
        }
    }

    async fn fail(&mut self, reply: &mpsc::Sender<AskEvent>, deliveries: Vec<String>, kind: FailureKind, message: &str) {
        (self.hooks.log)("failure", kind.as_str_name());
        self.give_back(deliveries);
        let _ = reply.send(failure(kind, message)).await;
    }

    async fn turn(&mut self, text: String, reply: mpsc::Sender<AskEvent>) -> Turn {
        // Taken when the question starts, so that deliveries given back by a cancelled one ride along.
        let deliveries = std::mem::take(&mut self.shared.lock().unwrap().waiting);
        let full = question(&deliveries, &text);
        (self.hooks.log)("ask", &full.len().to_string());
        let began = Instant::now();
        let mut said_text = false;
        let mut limited = false;
        let mut restarts = 0;
        'process: loop {
            if let Err(error) = self.start() {
                self.fail(&reply, deliveries, FailureKind::Tool, &format!("the tool could not be started: {error}")).await;
                return Turn::Finished;
            }
            let sent = self.process.as_mut().expect("just started").send(&full).await.is_ok();
            loop {
                let out = if sent {
                    tokio::select! {
                        command = self.inbox.recv() => {
                            self.stop().await;
                            self.fail(&reply, deliveries, FailureKind::Cancelled, "a newer question took its place").await;
                            return command.map_or(Turn::Gone, Turn::Interrupted);
                        }
                        out = tokio::time::timeout(self.silence, self.process.as_mut().expect("running").next()) => out,
                    }
                } else {
                    Ok(None)
                };
                match out {
                    Err(_) => {
                        self.stop().await;
                        self.fail(&reply, deliveries, FailureKind::Silent, "the tool said nothing for too long").await;
                        return Turn::Finished;
                    }
                    Ok(None) => {
                        // The process ended. If it was started from stored history and never said a
                        // word, that history cannot be continued: start empty rather than fail forever.
                        if self.fresh_resume {
                            let mut shared = self.shared.lock().unwrap();
                            shared.stored.cli_session = None;
                            (self.hooks.saved)(&shared.stored);
                            drop(shared);
                            (self.hooks.log)("history-lost", "");
                        }
                        self.stop().await;
                        restarts += 1;
                        if restarts < 2 && !said_text {
                            continue 'process;
                        }
                        self.fail(&reply, deliveries, FailureKind::Tool, "the tool ended without an answer").await;
                        return Turn::Finished;
                    }
                    Ok(Some(out)) => {
                        self.fresh_resume = false;
                        let passed = match out {
                            Out::Started { cli_session } => {
                                self.remember(cli_session);
                                continue;
                            }
                            Out::Limited => {
                                limited = true;
                                continue;
                            }
                            Out::Text(text) => {
                                said_text = true;
                                Kind::Text(text)
                            }
                            Out::Step { tool, detail } => {
                                let shown = if tool == "WebSearch" { "search" } else { detail.as_str() };
                                (self.hooks.log)("step", &format!("{tool} {shown}"));
                                Kind::Step(Step { tool, detail })
                            }
                            Out::Source(url) => Kind::Source(url),
                            Out::Done { cli_session, usage, failed } => {
                                self.remember(cli_session);
                                match failed {
                                    None => {
                                        self.shared.lock().unwrap().answered = Some(true);
                                        (self.hooks.log)("end", &began.elapsed().as_millis().to_string());
                                        let usage = Usage {
                                            cost_usd: usage.cost_usd,
                                            input_tokens: usage.input_tokens,
                                            output_tokens: usage.output_tokens,
                                        };
                                        let _ = reply.send(event(Kind::Usage(usage))).await;
                                        let _ = reply.send(event(Kind::End(End {}))).await;
                                    }
                                    Some(message) => {
                                        let lower = message.to_lowercase();
                                        // How the real tool words a reached plan limit was not seen;
                                        // besides its rate-limit event, the word "limit" is a first guess.
                                        let kind = if limited || lower.contains("limit") { FailureKind::Limit } else { FailureKind::Tool };
                                        if lower.contains("login") || lower.contains("log in") || lower.contains("sign in") {
                                            self.shared.lock().unwrap().answered = Some(false);
                                        }
                                        self.fail(&reply, deliveries, kind, &message).await;
                                    }
                                }
                                return Turn::Finished;
                            }
                        };
                        if reply.send(event(passed)).await.is_err() {
                            // Nobody listens any more: stop spending on it.
                            self.stop().await;
                            self.give_back(deliveries);
                            (self.hooks.log)("failure", "abandoned");
                            return Turn::Finished;
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn question_wraps_deliveries() {
        assert_eq!(question(&[], "Wer?"), "Wer?");
        assert_eq!(
            question(&["eins".into(), "zwei".into()], "Wer?"),
            "<delivered>\neins\nzwei\n</delivered>\n\nWer?"
        );
    }
}
