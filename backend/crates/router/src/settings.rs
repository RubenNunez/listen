//! The owner's settings, as the router's window shows and changes them, and the topics it lists.
//! Only the window changes them; the apps and gRPC cannot.

use crate::activity::{Entry, Kind};
use crate::config::{Config, Limits, ToolSettings};
use crate::manager::{is_model_name, Rules};
use crate::running::Running;
use crate::session::Stored;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// What sessions follow, from the settings.
pub fn rules_from(config: &Config) -> Rules {
    Rules {
        limits: config.limits,
        claude: config.claude_program(),
        claude_access: config.tools.claude.access,
        codex_enabled: config.tools.codex.enabled,
        codex: config.codex_program(),
        codex_access: config.tools.codex.access,
        claude_model: if config.tools.claude.model.is_empty() { "sonnet".into() } else { config.tools.claude.model.clone() },
        codex_model: if config.tools.codex.model.is_empty() { "default".into() } else { config.tools.codex.model.clone() },
        topics_root: config.topics_root.clone(),
        own_folders: config.topics.iter().filter_map(|(id, t)| t.folder.clone().map(|f| (id.clone(), f))).collect(),
    }
}

/// The part of `router.toml` the window edits. Devices are changed by pairing and removing, not here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// Shown, not changed here: `router.toml` itself lives in it.
    pub folder: String,
    pub port: u16,
    pub topics_root: Option<PathBuf>,
    pub limits: Limits,
    pub bonjour: bool,
    pub autostart: bool,
    pub claude: ToolSettings,
    pub codex: ToolSettings,
    /// Topic id → a folder of the user's own.
    pub topic_folders: BTreeMap<String, PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    /// Port and Bonjour change only when the router starts again.
    pub restart_needed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", content = "detail", rename_all = "camelCase")]
pub enum SettingsError {
    /// The new settings widen what sessions may do; the owner confirms these warnings first.
    NeedsConfirmation(Vec<String>),
    Invalid(String),
    NotSaved(String),
}

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SettingsError::NeedsConfirmation(w) => write!(f, "needs confirmation: {}", w.join(" ")),
            SettingsError::Invalid(e) | SettingsError::NotSaved(e) => f.write_str(e),
        }
    }
}

const CODEX_WARNING: &str = "codex works by running commands. On Windows its sandbox lets a session read every file you can read (measured on 15 November 2026).";

/// What the owner is told before the new settings take effect: every widening, nothing else.
pub fn warnings(old: &Settings, new: &Settings) -> Vec<String> {
    let mut out = Vec::new();
    if new.claude.enabled && new.claude.access > old.claude.access {
        out.extend(new.claude.access.warning("claude"));
    }
    if new.codex.enabled && !old.codex.enabled {
        out.push(CODEX_WARNING.into());
    }
    if new.codex.enabled && (new.codex.access > old.codex.access || !old.codex.enabled) {
        out.extend(new.codex.access.warning("codex"));
    }
    for (topic, folder) in &new.topic_folders {
        if old.topic_folders.get(topic) != Some(folder) {
            out.push(format!("Sessions of topic \"{topic}\" will work in {} and can change what is there.", folder.display()));
        }
    }
    out
}

fn check(new: &Settings) -> Result<(), SettingsError> {
    let invalid = |m: String| Err(SettingsError::Invalid(m));
    if new.port == 0 {
        return invalid("the port must be 1 to 65535".into());
    }
    let l = new.limits;
    if l.sessions_per_topic == 0 || l.sessions_total == 0 || l.idle_seconds < 10 || l.silence_seconds < 5 {
        return invalid("limits must allow at least one session, 10 s idle and 5 s silence".into());
    }
    if l.sessions_per_topic > l.sessions_total {
        return invalid("a topic cannot have more sessions than the router in total".into());
    }
    for (tool, settings) in [("claude", &new.claude), ("codex", &new.codex)] {
        if !settings.model.is_empty() && !is_model_name(&settings.model) {
            return invalid(format!("\"{}\" is not a model name for {tool}", settings.model));
        }
    }
    if let Some(root) = &new.topics_root {
        if !root.is_absolute() {
            return invalid("the topics folder must be a full path".into());
        }
    }
    for (topic, folder) in &new.topic_folders {
        if !crate::folders::is_plain_name(topic) {
            return invalid(format!("\"{topic}\" is not a topic id"));
        }
        if !folder.is_absolute() || !folder.is_dir() {
            return invalid(format!("the folder for \"{topic}\" must be an existing folder, given as a full path"));
        }
    }
    Ok(())
}

/// One topic as the window lists it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TopicView {
    pub id: String,
    /// Where its sessions work.
    pub folder: String,
    pub own_folder: bool,
    pub sessions: Vec<StoredView>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredView {
    pub id: String,
    pub role: String,
    pub model: String,
    pub created_at: u64,
    /// When its log was last written, in seconds since 1970.
    pub last_used: Option<u64>,
    pub running: bool,
}

impl Running {
    pub fn settings(&self) -> Settings {
        let config = self.config.lock().unwrap();
        Settings {
            folder: self.home.root().display().to_string(),
            port: config.port,
            topics_root: config.topics_root.clone(),
            limits: config.limits,
            bonjour: config.bonjour,
            autostart: config.autostart,
            claude: ToolSettings { path: Some(config.claude_program()), ..config.tools.claude.clone() },
            codex: config.tools.codex.clone(),
            topic_folders: config.topics.iter().filter_map(|(id, t)| t.folder.clone().map(|f| (id.clone(), f))).collect(),
        }
    }

    /// Checks and stores new settings. A widening is stored only with `confirmed`.
    pub fn save_settings(&self, new: Settings, confirmed: bool) -> Result<Saved, SettingsError> {
        check(&new)?;
        let old = self.settings();
        let warned = warnings(&old, &new);
        if !warned.is_empty() && !confirmed {
            return Err(SettingsError::NeedsConfirmation(warned));
        }
        let mut config = self.config.lock().unwrap();
        let before = config.clone();
        config.port = new.port;
        config.topics_root = new.topics_root.clone();
        config.limits = new.limits;
        config.bonjour = new.bonjour;
        config.autostart = new.autostart;
        config.tools.claude = new.claude.clone();
        config.tools.codex = new.codex.clone();
        config.topics.retain(|id, _| new.topic_folders.contains_key(id));
        for (id, folder) in &new.topic_folders {
            config.topics.entry(id.clone()).or_default().folder = Some(folder.clone());
        }
        if let Err(e) = config.save(&self.home.config_path()) {
            *config = before;
            return Err(SettingsError::NotSaved(e.to_string()));
        }
        self.manager.set_rules(rules_from(&config));
        if !warned.is_empty() {
            self.activity.push(Entry::now(Kind::SettingsWidened).detail(&warned.join(" ")));
        }
        Ok(Saved { restart_needed: new.port != old.port || new.bonjour != old.bonjour })
    }

    /// Every topic the router has a folder or records for.
    pub fn topics(&self) -> Vec<TopicView> {
        let base = self.manager.topics_base();
        let rules = self.manager.rules();
        let running: Vec<String> = self.manager.infos().into_iter().filter(|s| s.open).map(|s| s.session_id).collect();
        let mut ids: Vec<String> = std::fs::read_dir(&base)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().is_dir())
            .filter_map(|e| e.file_name().to_str().map(str::to_string))
            .filter(|n| crate::folders::is_plain_name(n))
            .collect();
        for id in rules.own_folders.keys() {
            if !ids.contains(id) {
                ids.push(id.clone());
            }
        }
        ids.sort();
        ids.into_iter()
            .map(|id| {
                let own = rules.own_folders.get(&id).cloned();
                let records = base.join(&id).join("sessions");
                let mut sessions: Vec<StoredView> = std::fs::read_dir(&records)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
                    .filter_map(|e| {
                        let stored: Stored = serde_json::from_str(&std::fs::read_to_string(e.path()).ok()?).ok()?;
                        let last_used = std::fs::metadata(e.path().with_extension("log"))
                            .and_then(|m| m.modified())
                            .ok()
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_secs());
                        Some(StoredView {
                            running: running.contains(&stored.session_id),
                            id: stored.session_id,
                            role: stored.role,
                            model: stored.model,
                            created_at: stored.created_at,
                            last_used,
                        })
                    })
                    .collect();
                sessions.sort_by_key(|s| std::cmp::Reverse(s.last_used.unwrap_or(s.created_at)));
                TopicView {
                    folder: own.clone().unwrap_or_else(|| base.join(&id)).display().to_string(),
                    own_folder: own.is_some(),
                    id,
                    sessions,
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Access;

    fn base() -> Settings {
        let config = Config::default();
        Settings {
            folder: "x".into(),
            port: 50551,
            topics_root: None,
            limits: config.limits,
            bonjour: true,
            autostart: false,
            claude: config.tools.claude.clone(),
            codex: config.tools.codex.clone(),
            topic_folders: BTreeMap::new(),
        }
    }

    #[test]
    fn narrowing_and_unrelated_changes_need_no_confirmation() {
        let old = base();
        let mut new = base();
        new.limits.sessions_total = 8;
        new.autostart = true;
        assert!(warnings(&old, &new).is_empty());
        let mut wide = base();
        wide.claude.access = Access::Commands;
        assert!(warnings(&wide, &old).is_empty(), "going back to folder only warns about nothing");
    }

    #[test]
    fn switching_codex_on_warns_about_its_sandbox() {
        let mut new = base();
        new.codex.enabled = true;
        let w = warnings(&base(), &new);
        assert!(w.iter().any(|w| w.contains("read every file")), "{w:?}");
    }

    #[test]
    fn invalid_settings_are_refused() {
        let mut s = base();
        s.port = 0;
        assert!(matches!(check(&s), Err(SettingsError::Invalid(_))));
        let mut s = base();
        s.topic_folders.insert("demo".into(), PathBuf::from("relative/path"));
        assert!(matches!(check(&s), Err(SettingsError::Invalid(_))));
        let mut s = base();
        s.claude.model = "--dangerously".into();
        assert!(matches!(check(&s), Err(SettingsError::Invalid(_))));
        let mut s = base();
        s.limits.sessions_per_topic = 9;
        assert!(matches!(check(&s), Err(SettingsError::Invalid(_))));
    }
}
