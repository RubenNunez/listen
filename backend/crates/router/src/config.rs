//! `router.toml`: limits, where the CLI is, and the paired devices.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

/// How much the router allows at once. The defaults are the design's starting values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Limits {
    pub sessions_per_topic: u32,
    pub sessions_total: u32,
    /// A session without a question for this long loses its process; it stays on disk.
    pub idle_seconds: u32,
    /// A question that produces nothing for this long is cancelled.
    pub silence_seconds: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Limits { sessions_per_topic: 4, sessions_total: 6, idle_seconds: 600, silence_seconds: 60 }
    }
}

/// A paired device. Only the hash of its token is kept.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    pub name: String,
    pub token_sha256: String,
    pub paired_at: u64,
}

/// How much a tool's sessions may do. Set by the owner in the router's window; the default is the narrowest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Access {
    /// Files inside the topic's folder and web search. No commands.
    #[default]
    Folder,
    /// Also commands, run in the topic's folder with the user's rights.
    Commands,
    /// Also files anywhere the user can reach.
    Computer,
}

impl Access {
    /// What the owner is told before widening to this level.
    pub fn warning(self, tool: &str) -> Option<String> {
        match self {
            Access::Folder => None,
            Access::Commands => Some(format!(
                "{tool} sessions can run commands on this computer with your rights. A transcript or web page that reaches a session could lead it to run something."
            )),
            Access::Computer => Some(format!(
                "{tool} sessions can read and change any file in your home folder, not only the topic's, and run commands."
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ToolSettings {
    pub enabled: bool,
    /// The executable; found on the PATH when not set.
    pub path: Option<PathBuf>,
    /// The model a session gets when the app names none.
    pub model: String,
    pub access: Access,
}

impl Default for ToolSettings {
    fn default() -> Self {
        ToolSettings { enabled: true, path: None, model: String::new(), access: Access::Folder }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Tools {
    pub claude: ToolSettings,
    pub codex: ToolSettings,
}

impl Default for Tools {
    fn default() -> Self {
        Tools {
            claude: ToolSettings { model: "sonnet".into(), ..ToolSettings::default() },
            // Off until the owner switches it on: its sandbox reaches further than claude's (design, section 9).
            codex: ToolSettings { enabled: false, ..ToolSettings::default() },
        }
    }
}

/// A topic's own settings.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TopicSettings {
    /// A folder of the user's own as the sessions' working directory, instead of one under the topics folder.
    pub folder: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub port: u16,
    /// The `claude` executable, as slice 1 stored it. `tools.claude.path` takes its place; this is still read.
    pub claude_path: Option<PathBuf>,
    pub limits: Limits,
    /// Where the topic folders live. Default: `topics` in the router's folder.
    pub topics_root: Option<PathBuf>,
    pub tools: Tools,
    pub topics: BTreeMap<String, TopicSettings>,
    /// Announce the router at home by Bonjour.
    pub bonjour: bool,
    /// Start the desktop app when the user signs in.
    pub autostart: bool,
    pub devices: Vec<Device>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            port: 50551,
            claude_path: None,
            limits: Limits::default(),
            topics_root: None,
            tools: Tools::default(),
            topics: BTreeMap::new(),
            bonjour: true,
            autostart: false,
            devices: Vec::new(),
        }
    }
}

impl Config {
    /// The claude executable: the setting, the old field, or the name on the PATH.
    pub fn claude_program(&self) -> PathBuf {
        self.tools.claude.path.clone().or_else(|| self.claude_path.clone()).unwrap_or_else(|| PathBuf::from("claude"))
    }

    pub fn codex_program(&self) -> PathBuf {
        self.tools.codex.path.clone().unwrap_or_else(|| PathBuf::from("codex"))
    }
}

impl Config {
    /// Reads the file; a missing file gives the defaults.
    pub fn load(path: &Path) -> io::Result<Config> {
        match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string())),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Config::default()),
            Err(e) => Err(e),
        }
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        let text = toml::to_string_pretty(self).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_default_to_the_spec() {
        let l = Limits::default();
        assert_eq!((l.sessions_per_topic, l.sessions_total, l.idle_seconds, l.silence_seconds), (4, 6, 600, 60));
    }

    #[test]
    fn old_config_keeps_todays_behaviour() {
        // A router.toml as slice 1 wrote it.
        let old = "port = 50551\nclaude_path = \"C:/tools/claude.cmd\"\n\n[limits]\nsessions_per_topic = 4\nsessions_total = 6\nidle_seconds = 600\nsilence_seconds = 60\n\n[[devices]]\nname = \"iPhone\"\ntoken_sha256 = \"ab\"\npaired_at = 7\n";
        let config: Config = toml::from_str(old).unwrap();
        assert_eq!(config.tools.claude.access, Access::Folder);
        assert!(config.tools.claude.enabled);
        assert!(!config.tools.codex.enabled, "codex stays off");
        assert_eq!(config.claude_program(), PathBuf::from("C:/tools/claude.cmd"));
        assert!(config.bonjour && !config.autostart && config.topics.is_empty() && config.topics_root.is_none());
        assert_eq!(config.devices.len(), 1);
    }

    #[test]
    fn settings_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("router.toml");
        let mut config = Config::default();
        config.tools.claude.access = Access::Commands;
        config.tools.codex = ToolSettings { enabled: true, path: Some("/usr/bin/codex".into()), model: "gpt".into(), access: Access::Computer };
        config.topics.insert("demo".into(), TopicSettings { folder: Some(dir.path().to_path_buf()) });
        config.topics_root = Some(dir.path().join("t"));
        config.autostart = true;
        config.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), config);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("access = \"commands\""), "{text}");
    }

    #[test]
    fn only_wider_levels_warn() {
        assert!(Access::Folder.warning("claude").is_none());
        assert!(Access::Commands.warning("claude").unwrap().contains("run commands"));
        assert!(Access::Computer > Access::Commands && Access::Commands > Access::Folder);
    }

    #[test]
    fn config_round_trips_and_missing_file_is_default() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("router.toml");
        assert_eq!(Config::load(&path).unwrap(), Config::default());
        let mut config = Config { port: 1234, ..Config::default() };
        config.devices.push(Device { name: "iPhone".into(), token_sha256: "ab".into(), paired_at: 7 });
        config.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), config);
    }
}
