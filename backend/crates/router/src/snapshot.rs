//! Everything the router's window shows, in one value.

use crate::activity::Entry;
use crate::pairing::{qr_svg, Phase};
use crate::running::Running;
use listen_router_proto::v1::SignedIn;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub version: String,
    pub name: String,
    pub ready: bool,
    pub problem: Option<String>,
    pub folder: String,
    pub port: u16,
    /// Of the router's certificate. The app shows it before it pairs, to be compared with this one.
    pub fingerprint: String,
    pub tools: Vec<ToolView>,
    pub devices: Vec<DeviceView>,
    pub pairing: PairingView,
    pub bonjour: BonjourView,
    pub sessions: Vec<SessionView>,
    pub activity: Vec<Entry>,
    pub answering: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolView {
    pub name: String,
    pub found: bool,
    pub enabled: bool,
    pub version: String,
    /// "yes", "no" or "unknown".
    pub signed_in: String,
    /// What the user can do; the router never signs a tool in itself.
    pub hint: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceView {
    /// The first eight characters of the token's hash: enough to name it, useless as a token.
    pub id: String,
    pub name: String,
    pub paired_at: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingView {
    /// "code": `link` is shown and renewed. "idle": renewal stopped after minutes without a pairing.
    /// "paired": `device` just paired. "locked": stopped after wrong codes. "none": no code was asked for yet.
    pub phase: &'static str,
    /// Empty unless the phase is "code".
    pub link: String,
    pub qr_svg: String,
    /// Until the code is replaced by the next one.
    pub seconds_left: u64,
    /// What `seconds_left` counts down from.
    pub period: u64,
    /// The name the device gave when it paired; text from outside.
    pub device: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BonjourView {
    pub announced: bool,
    pub name: String,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    pub id: String,
    pub topic: String,
    pub role: String,
    pub model: String,
    pub running: bool,
}

fn access_word(access: crate::config::Access) -> &'static str {
    match access {
        crate::config::Access::Folder => "folder only",
        crate::config::Access::Commands => "folder and commands",
        crate::config::Access::Computer => "home folder and commands",
    }
}

const SIGN_IN: &str = "run claude in a terminal on this computer and follow its steps";

impl Running {
    pub fn snapshot(&self) -> Snapshot {
        let signed_in = self.manager.signed_in();
        let claude_hint = match (self.claude.found, signed_in) {
            (false, _) => {
                format!(
                    "Not found as \"{}\". Install Claude Code, then {SIGN_IN} to sign in. The router looks again when it starts.",
                    self.claude_program.display()
                )
            }
            (true, SignedIn::Yes) => String::new(),
            (true, SignedIn::No) => format!("A question failed as if signed out. To sign in, {SIGN_IN}."),
            (true, _) => format!("Whether it is signed in shows after the first answer. To sign in, {SIGN_IN}."),
        };
        let word = |s: SignedIn| match s {
            SignedIn::Yes => "yes",
            SignedIn::No => "no",
            _ => "unknown",
        };
        let shown = self.pairing.lock().unwrap().shown();
        let link = shown.code.as_deref().map(|code| self.link_of(code));
        let (claude_access, codex) = {
            let config = self.config.lock().unwrap();
            (config.tools.claude.access, config.tools.codex.clone())
        };
        Snapshot {
            version: env!("CARGO_PKG_VERSION").to_string(),
            name: self.name.clone(),
            ready: self.claude.found,
            problem: (!self.claude.found)
                .then(|| "The claude tool was not found on this computer, so no session can start".to_string()),
            folder: self.home.root().display().to_string(),
            port: self.port,
            fingerprint: self.fingerprint.clone(),
            tools: vec![
                ToolView {
                    name: "claude".into(),
                    found: self.claude.found,
                    enabled: true,
                    version: self.claude.version.clone(),
                    signed_in: word(if self.claude.found { signed_in } else { SignedIn::Unknown }).into(),
                    hint: if claude_access == crate::config::Access::Folder {
                        claude_hint
                    } else {
                        format!("Access: {}. {claude_hint}", access_word(claude_access)).trim().to_string()
                    },
                },
                ToolView {
                    name: "codex".into(),
                    found: self.codex.found,
                    enabled: codex.enabled && self.codex.found,
                    version: self.codex.version.clone(),
                    signed_in: "unknown".into(),
                    hint: match (codex.enabled, self.codex.found) {
                        (true, true) => format!("Switched on in Settings. Access: {}.", access_word(codex.access)),
                        (true, false) => "Switched on in Settings, but not found on this computer.".into(),
                        (false, true) => {
                            "Can be switched on in Settings. Its sandbox reaches further than claude's.".into()
                        }
                        (false, false) => "Optional. The router works with claude alone.".into(),
                    },
                },
            ],
            devices: self
                .devices()
                .into_iter()
                .map(|d| DeviceView {
                    id: d.token_sha256.chars().take(8).collect(),
                    name: d.name,
                    paired_at: d.paired_at,
                })
                .collect(),
            pairing: PairingView {
                phase: match (&shown.phase, &shown.code) {
                    (Phase::Code, Some(_)) => "code",
                    (Phase::Code, None) => "none",
                    (Phase::Idle, _) => "idle",
                    (Phase::Paired(_), _) => "paired",
                    (Phase::Locked, _) => "locked",
                },
                qr_svg: link.as_deref().map(qr_svg).unwrap_or_default(),
                link: link.unwrap_or_default(),
                seconds_left: shown.seconds_left,
                period: shown.period,
                device: match shown.phase {
                    Phase::Paired(name) => Some(name),
                    _ => None,
                },
            },
            bonjour: self.bonjour(),
            sessions: self
                .manager
                .infos()
                .into_iter()
                .map(|s| SessionView {
                    id: s.session_id,
                    topic: s.topic_id,
                    role: s.role,
                    model: s.model,
                    running: s.open,
                })
                .collect(),
            activity: self.activity.recent(),
            answering: self.activity.answering(),
        }
    }
}
