//! What the router has been doing, for its own window: steps and times, never text.

use serde::Serialize;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Opened,
    Asked,
    Step,
    Answered,
    Failed,
    Closed,
    Rested,
    Paired,
    DeviceRemoved,
    /// The owner widened what sessions may do.
    SettingsWidened,
}

/// One thing that happened. `detail` is a tool and a path, a failure kind or a device name; never what was said.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub at_millis: u64,
    pub topic: String,
    /// The first eight characters of the session id.
    pub session: String,
    pub role: String,
    pub kind: Kind,
    pub detail: String,
    pub millis: Option<u64>,
}

impl Entry {
    pub fn now(kind: Kind) -> Entry {
        Entry {
            at_millis: SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0),
            topic: String::new(),
            session: String::new(),
            role: String::new(),
            kind,
            detail: String::new(),
            millis: None,
        }
    }

    pub fn of(mut self, topic: &str, session: &str, role: &str) -> Entry {
        self.topic = topic.to_string();
        self.session = session.chars().take(8).collect();
        self.role = role.to_string();
        self
    }

    pub fn detail(mut self, detail: &str) -> Entry {
        self.detail = detail.chars().map(|c| if c.is_control() { ' ' } else { c }).take(200).collect();
        self
    }
}

/// The last entries, shared between the sessions and the window.
#[derive(Debug, Clone, Default)]
pub struct Activity {
    entries: Arc<Mutex<VecDeque<Entry>>>,
}

impl Activity {
    pub const KEEP: usize = 200;

    pub fn push(&self, entry: Entry) {
        let mut entries = self.entries.lock().unwrap();
        if entries.len() == Self::KEEP {
            entries.pop_front();
        }
        entries.push_back(entry);
    }

    /// Oldest first.
    pub fn recent(&self) -> Vec<Entry> {
        self.entries.lock().unwrap().iter().cloned().collect()
    }

    /// Whether some session's last word is a question still being answered.
    pub fn answering(&self) -> bool {
        let entries = self.entries.lock().unwrap();
        let mut last: Vec<(&str, Kind)> = Vec::new();
        for e in entries.iter() {
            if matches!(e.kind, Kind::Asked | Kind::Answered | Kind::Failed | Kind::Closed | Kind::Rested) {
                match last.iter_mut().find(|(s, _)| *s == e.session) {
                    Some(slot) => slot.1 = e.kind,
                    None => last.push((&e.session, e.kind)),
                }
            }
        }
        last.iter().any(|(_, kind)| *kind == Kind::Asked)
    }
}
