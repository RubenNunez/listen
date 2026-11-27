//! All sessions of the router: limits, idle sessions, what is kept on disk, and the step log.

use crate::activity::{Activity, Entry, Kind};
use crate::claude::Spawn;
use crate::cli::Cli;
use crate::config::Limits;
use crate::config::Access;
use crate::folders::{is_plain_name, topic_at, Home, TopicDir, TopicId};
use crate::session::{Hooks, Session, Stored};
use listen_router_proto::v1::{AskEvent, OpenSessionRequest, OpenSessionResponse, SessionInfo, SignedIn, Tool};
use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use tonic::Status;

/// The longest text one delivery or question may carry, in bytes.
pub const TEXT_LIMIT: usize = 100_000;
/// The longest system text, in bytes. It travels on the command line.
pub const SYSTEM_LIMIT: usize = 16_000;

/// What the owner set in the router's window that sessions opened from now on follow.
/// A running session keeps what it was opened with.
#[derive(Debug, Clone)]
pub struct Rules {
    pub limits: Limits,
    pub claude: PathBuf,
    pub claude_access: Access,
    pub codex_enabled: bool,
    pub codex: PathBuf,
    pub codex_access: Access,
    /// The model a session gets when the app names none. For codex "default" leaves it to codex.
    pub claude_model: String,
    pub codex_model: String,
    /// Where topic folders live; `None`: `topics` in the router's folder.
    pub topics_root: Option<PathBuf>,
    /// Topics whose sessions work in a folder of the user's own.
    pub own_folders: BTreeMap<String, PathBuf>,
}

impl Rules {
    pub fn new(limits: Limits, claude: PathBuf) -> Rules {
        Rules {
            limits,
            claude,
            claude_access: Access::Folder,
            codex_enabled: false,
            codex: PathBuf::from("codex"),
            codex_access: Access::Folder,
            claude_model: "sonnet".into(),
            codex_model: "default".into(),
            topics_root: None,
            own_folders: BTreeMap::new(),
        }
    }
}

pub struct Manager {
    home: Home,
    rules: Mutex<Rules>,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    signed_in: Mutex<SignedIn>,
    activity: Activity,
}

/// The activity entry for a line of a session's step log, if it is one the window shows.
fn entry_for(kind: &str, detail: &str) -> Option<Entry> {
    Some(match kind {
        "ask" => Entry::now(Kind::Asked),
        "step" => Entry::now(Kind::Step).detail(detail),
        "end" => {
            let mut entry = Entry::now(Kind::Answered);
            entry.millis = detail.parse().ok();
            entry
        }
        "failure" => Entry::now(Kind::Failed).detail(detail),
        "history-lost" => Entry::now(Kind::Failed).detail("history lost, started anew"),
        _ => return None,
    })
}

/// What "the whole computer" means for the file tools: the user's home folder.
fn home_dirs() -> Vec<PathBuf> {
    std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).into_iter().collect()
}

fn now_millis() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

/// One line of a session's log: time, kind, detail. Never text of a delivery, question or reply.
fn log_line(path: &Path, kind: &str, detail: &str) {
    let detail: String = detail.chars().map(|c| if c.is_control() { ' ' } else { c }).take(300).collect();
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{}\t{kind}\t{detail}", now_millis());
    }
}

fn save(path: &Path, stored: &Stored) {
    if let Ok(text) = serde_json::to_string_pretty(stored) {
        let _ = std::fs::write(path, text);
    }
}

/// A model name as the CLI takes it: letters, digits and `. _ - [ ]`, not starting with `-`.
pub fn is_model_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && !name.starts_with('-')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-[]".contains(&b))
}

/// Reads a stored session and refuses anything that does not look like one the router wrote.
/// A session can write in its own topic folder, so this file is not trusted.
fn read_stored(dir: &TopicDir, topic: &TopicId, session_id: &str) -> Result<Stored, Status> {
    let path = dir.sessions.join(format!("{session_id}.json"));
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(Status::not_found("no such session in this topic"))
        }
        Err(_) => return Err(Status::data_loss("the stored session cannot be read")),
    };
    let stored: Stored = serde_json::from_str(&text).map_err(|_| Status::data_loss("the stored session is damaged"))?;
    let sound = stored.session_id == session_id
        && stored.topic_id == topic.as_str()
        && (stored.tool == Tool::Claude as i32 || stored.tool == Tool::Codex as i32)
        && is_model_name(&stored.model)
        && stored.system.len() <= SYSTEM_LIMIT
        && stored.cli_session.as_deref().is_none_or(is_plain_name);
    if sound {
        Ok(stored)
    } else {
        Err(Status::data_loss("the stored session is damaged"))
    }
}

impl Manager {
    pub fn new(home: Home, limits: Limits, claude: PathBuf) -> Manager {
        Manager {
            home,
            rules: Mutex::new(Rules::new(limits, claude)),
            sessions: Mutex::new(HashMap::new()),
            signed_in: Mutex::new(SignedIn::Unknown),
            activity: Activity::default(),
        }
    }

    /// What the sessions have been doing; shared, so the window can read it.
    pub fn activity(&self) -> Activity {
        self.activity.clone()
    }

    fn note(&self, session: &Session, kind: Kind) {
        let stored = session.stored();
        self.activity.push(Entry::now(kind).of(&stored.topic_id, &stored.session_id, &stored.role));
    }

    pub fn limits(&self) -> Limits {
        self.rules.lock().unwrap().limits
    }

    pub fn rules(&self) -> Rules {
        self.rules.lock().unwrap().clone()
    }

    /// New settings, for sessions opened from now on.
    pub fn set_rules(&self, rules: Rules) {
        *self.rules.lock().unwrap() = rules;
    }

    /// Where the router keeps a topic's records.
    pub fn topics_base(&self) -> PathBuf {
        self.rules.lock().unwrap().topics_root.clone().unwrap_or_else(|| self.home.topics_dir())
    }

    fn running(&self, topic: Option<&str>) -> usize {
        self.sessions
            .lock()
            .unwrap()
            .values()
            .filter(|s| s.is_running() && topic.is_none_or(|t| s.stored().topic_id == t))
            .count()
    }

    fn room_for(&self, topic: &str) -> Result<(), Status> {
        let limits = self.limits();
        if self.running(None) >= limits.sessions_total as usize {
            return Err(Status::resource_exhausted(format!(
                "the router runs at most {} sessions at once",
                limits.sessions_total
            )));
        }
        if self.running(Some(topic)) >= limits.sessions_per_topic as usize {
            return Err(Status::resource_exhausted(format!(
                "a topic has at most {} sessions at once",
                limits.sessions_per_topic
            )));
        }
        Ok(())
    }

    pub fn open(&self, mut request: OpenSessionRequest) -> Result<OpenSessionResponse, Status> {
        let topic = TopicId::parse(&request.topic_id).map_err(|e| Status::invalid_argument(e.to_string()))?;
        let tool = match Tool::try_from(request.tool) {
            Ok(Tool::Claude) => Tool::Claude,
            Ok(Tool::Codex) if self.rules().codex_enabled => Tool::Codex,
            Ok(Tool::Codex) => return Err(Status::failed_precondition("codex is not enabled on this router")),
            _ => return Err(Status::invalid_argument("name a tool")),
        };
        let continuing = !request.session_id.is_empty();
        if continuing {
            if !is_plain_name(&request.session_id) {
                return Err(Status::invalid_argument("not a session id"));
            }
            if let Some(session) = self.sessions.lock().unwrap().get(&request.session_id) {
                if session.stored().topic_id != topic.as_str() {
                    return Err(Status::invalid_argument("this session belongs to another topic"));
                }
                return Ok(OpenSessionResponse { session_id: request.session_id, continued: true });
            }
        } else {
            let role = request.role.trim();
            if role.is_empty() || role.len() > 64 || role.chars().any(char::is_control) {
                return Err(Status::invalid_argument("a role is 1 to 64 characters"));
            }
            if request.model.is_empty() {
                let rules = self.rules();
                request.model = if tool == Tool::Codex { rules.codex_model } else { rules.claude_model };
            }
            if !is_model_name(&request.model) {
                return Err(Status::invalid_argument("name a model, for example \"haiku\""));
            }
            if request.system.len() > SYSTEM_LIMIT {
                return Err(Status::invalid_argument("the system text is too long"));
            }
        }
        self.room_for(topic.as_str())?;
        let rules = self.rules();
        let base = rules.topics_root.clone().unwrap_or_else(|| self.home.topics_dir());
        let own = rules.own_folders.get(topic.as_str()).map(PathBuf::as_path);
        let dir = topic_at(&base, own, &topic).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Status::failed_precondition(e.to_string()),
            _ => Status::internal(format!("the topic folder cannot be made: {e}")),
        })?;
        let stored = if continuing {
            read_stored(&dir, &topic, &request.session_id)?
        } else {
            Stored {
                session_id: uuid::Uuid::new_v4().to_string(),
                topic_id: topic.as_str().to_string(),
                role: request.role.trim().to_string(),
                tool: tool as i32,
                model: request.model.clone(),
                system: request.system.clone(),
                cli_session: None,
                created_at: (now_millis() / 1000) as u64,
            }
        };
        let json = dir.sessions.join(format!("{}.json", stored.session_id));
        let log = dir.sessions.join(format!("{}.log", stored.session_id));
        if !continuing {
            save(&json, &stored);
        }
        log_line(&log, "open", if continuing { "continued" } else { "new" });
        let codex = stored.tool == Tool::Codex as i32;
        if codex && !rules.codex_enabled {
            return Err(Status::failed_precondition("codex is not enabled on this router"));
        }
        let spawn = Spawn {
            program: if codex { rules.codex.clone() } else { rules.claude.clone() },
            cwd: dir.root.clone(),
            model: stored.model.clone(),
            system: stored.system.clone(),
            resume: None,
            access: if codex { rules.codex_access } else { rules.claude_access },
            extra_dirs: home_dirs(),
            cli: if codex { Cli::Codex } else { Cli::Claude },
        };
        let activity = self.activity.clone();
        let (topic_id, session_id, role) = (stored.topic_id.clone(), stored.session_id.clone(), stored.role.clone());
        activity.push(Entry::now(Kind::Opened).of(&topic_id, &session_id, &role).detail(if continuing {
            "continued"
        } else {
            "new"
        }));
        let hooks = Hooks {
            saved: Box::new(move |stored| save(&json, stored)),
            log: Box::new(move |kind, detail| {
                log_line(&log, kind, detail);
                if let Some(entry) = entry_for(kind, detail) {
                    activity.push(entry.of(&topic_id, &session_id, &role));
                }
            }),
        };
        let session_id = stored.session_id.clone();
        let silence = Duration::from_secs(rules.limits.silence_seconds as u64);
        let session = Session::open(stored, spawn, silence, hooks)
            .map_err(|e| Status::failed_precondition(format!("claude could not be started: {e}")))?;
        self.sessions.lock().unwrap().insert(session_id.clone(), Arc::new(session));
        Ok(OpenSessionResponse { session_id, continued: continuing })
    }

    fn get(&self, session_id: &str) -> Result<Arc<Session>, Status> {
        self.sessions
            .lock()
            .unwrap()
            .get(session_id)
            .cloned()
            .ok_or_else(|| Status::not_found("no such open session; open it again with its id"))
    }

    fn log_path(&self, session: &Session) -> Option<PathBuf> {
        let stored = session.stored();
        let topic = TopicId::parse(&stored.topic_id).ok()?;
        Some(self.topics_base().join(topic.as_str()).join("sessions").join(format!("{}.log", stored.session_id)))
    }

    pub fn deliver(&self, session_id: &str, text: String) -> Result<u32, Status> {
        if text.len() > TEXT_LIMIT {
            return Err(Status::invalid_argument("the text is too long"));
        }
        let session = self.get(session_id)?;
        if let Some(log) = self.log_path(&session) {
            log_line(&log, "deliver", &text.len().to_string());
        }
        Ok(session.deliver(text))
    }

    pub async fn ask(&self, session_id: &str, text: String) -> Result<mpsc::Receiver<AskEvent>, Status> {
        if text.len() > TEXT_LIMIT {
            return Err(Status::invalid_argument("the text is too long"));
        }
        let session = self.get(session_id)?;
        if !session.is_running() {
            // An idle session wakes up; it needs room like a new one.
            self.room_for(&session.stored().topic_id)?;
        }
        Ok(session.ask(text).await)
    }

    pub async fn close(&self, session_id: &str) -> Result<(), Status> {
        let session = self.sessions.lock().unwrap().remove(session_id);
        let session = session.ok_or_else(|| Status::not_found("no such open session"))?;
        self.note_sign_in(&session);
        if let Some(log) = self.log_path(&session) {
            log_line(&log, "close", "");
        }
        self.note(&session, Kind::Closed);
        session.close().await;
        Ok(())
    }

    pub fn infos(&self) -> Vec<SessionInfo> {
        let mut infos: Vec<SessionInfo> = self
            .sessions
            .lock()
            .unwrap()
            .values()
            .map(|session| {
                let stored = session.stored();
                SessionInfo {
                    session_id: stored.session_id,
                    topic_id: stored.topic_id,
                    role: stored.role,
                    tool: stored.tool,
                    model: stored.model,
                    open: session.is_running(),
                }
            })
            .collect();
        infos.sort_by(|a, b| (&a.topic_id, &a.session_id).cmp(&(&b.topic_id, &b.session_id)));
        infos
    }

    fn note_sign_in(&self, session: &Session) {
        let mut signed_in = self.signed_in.lock().unwrap();
        match session.answered() {
            Some(true) => *signed_in = SignedIn::Yes,
            Some(false) if *signed_in == SignedIn::Unknown => *signed_in = SignedIn::No,
            _ => {}
        }
    }

    /// Known only from how questions ended; the router never looks at the tool's own files.
    pub fn signed_in(&self) -> SignedIn {
        let sessions: Vec<Arc<Session>> = self.sessions.lock().unwrap().values().cloned().collect();
        for session in &sessions {
            self.note_sign_in(session);
        }
        *self.signed_in.lock().unwrap()
    }

    /// Ends the processes of sessions nobody has used for the idle time. They stay open and wake on the next question.
    pub async fn close_idle(&self) {
        let idle = Duration::from_secs(self.limits().idle_seconds as u64);
        let sessions: Vec<Arc<Session>> = self.sessions.lock().unwrap().values().cloned().collect();
        for session in sessions {
            if session.is_running() && session.last_used().elapsed() >= idle {
                if let Some(log) = self.log_path(&session) {
                    log_line(&log, "idle", "");
                }
                self.note(&session, Kind::Rested);
                session.rest().await;
            }
        }
    }

    /// Ends every process. The sessions stay on disk.
    pub async fn shut_down(&self) {
        let sessions: Vec<Arc<Session>> = self.sessions.lock().unwrap().drain().map(|(_, s)| s).collect();
        for session in sessions {
            session.close().await;
        }
    }
}
