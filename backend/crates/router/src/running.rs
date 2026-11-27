//! A started router: the gRPC service, its sessions, pairing and the idle ticker.
//! Both programs use it: the command-line `listen-router` and the desktop app.

use crate::activity::{Activity, Entry, Kind};
use crate::bonjour::{announce, Announcement};
use crate::config::Config;
use crate::folders::Home;
use crate::manager::Manager;
use crate::pairing::{link, system_clock, Pairing};
use crate::service::{serve, Found, RouterService};
use crate::snapshot::BonjourView;
use crate::tls::{self, Identity};
use std::net::{SocketAddr, UdpSocket};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

#[derive(Debug, Clone, Default)]
pub struct Options {
    /// The router's own folder. `None`: `Listen` in the user's home folder.
    pub home: Option<PathBuf>,
    pub port: Option<u16>,
    pub claude: Option<PathBuf>,
    /// Further addresses this machine is reached by; the one in the local network is found by itself.
    pub hosts: Vec<String>,
    /// Announce the router in the local network by Bonjour.
    pub bonjour: bool,
}

#[derive(Debug)]
pub enum StartError {
    PortTaken(u16),
    Folder(std::io::Error),
    Network(std::io::Error),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StartError::PortTaken(port) => write!(f, "port {port} is taken; is another router already running?"),
            StartError::Folder(e) => write!(f, "the router's folder cannot be used: {e}"),
            StartError::Network(e) => write!(f, "the router cannot listen: {e}"),
        }
    }
}

impl std::error::Error for StartError {}

pub fn default_home() -> PathBuf {
    let base =
        std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_default();
    base.join("Listen")
}

/// The computer's name, as the apps show it.
pub fn machine_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .ok()
        .filter(|n| !n.is_empty())
        .or_else(|| {
            Command::new("hostname")
                .stderr(Stdio::null())
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|n| !n.is_empty())
        })
        .unwrap_or_else(|| "router".into())
}

/// Asks a tool for its version. That it answers is all the router learns about it.
pub fn look_for(program: &PathBuf) -> Found {
    let mut command = if cfg!(windows) && program.extension().is_none() && program.components().count() == 1 {
        // On Windows a tool installed by npm is a .cmd file, which only the command interpreter starts.
        let mut command = Command::new("cmd");
        command.arg("/C").arg(program);
        command
    } else {
        Command::new(program)
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No console window flashes up when the desktop app asks.
        command.creation_flags(0x0800_0000);
    }
    match command.arg("--version").stdin(Stdio::null()).stderr(Stdio::null()).output() {
        Ok(output) if output.status.success() => Found {
            found: true,
            version: String::from_utf8_lossy(&output.stdout).lines().next().unwrap_or("").trim().to_string(),
        },
        _ => Found::default(),
    }
}

/// The address other machines in the network reach this one by. Sends nothing.
pub fn network_address() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:9").ok()?;
    let address = socket.local_addr().ok()?.ip();
    (!address.is_loopback() && !address.is_unspecified()).then(|| address.to_string())
}

pub struct Running {
    pub home: Home,
    pub port: u16,
    pub hosts: Vec<String>,
    pub fingerprint: String,
    pub name: String,
    pub claude: Found,
    pub codex: Found,
    pub claude_program: PathBuf,
    pub manager: Arc<Manager>,
    pub activity: Activity,
    pub(crate) pairing: Arc<Mutex<Pairing>>,
    pub(crate) config: Arc<Mutex<Config>>,
    bonjour: BonjourView,
    announcement: Option<Announcement>,
    stop: Option<oneshot::Sender<()>>,
    served: Option<JoinHandle<()>>,
    idle: JoinHandle<()>,
}

impl Running {
    pub async fn start(options: Options) -> Result<Running, StartError> {
        let home = Home::new(options.home.unwrap_or_else(default_home));
        std::fs::create_dir_all(home.root()).map_err(StartError::Folder)?;
        let mut config = Config::load(&home.config_path()).map_err(StartError::Folder)?;
        if let Some(port) = options.port {
            config.port = port;
        }
        if let Some(claude) = options.claude {
            config.tools.claude.path = Some(claude);
        }
        let claude_program = config.claude_program();
        let identity: Identity = tls::load_or_create(&home.tls_dir()).map_err(StartError::Folder)?;
        let port = config.port;
        let listener = tokio::net::TcpListener::bind(SocketAddr::from(([0, 0, 0, 0], port))).await.map_err(|e| {
            if e.kind() == std::io::ErrorKind::AddrInUse {
                StartError::PortTaken(port)
            } else {
                StartError::Network(e)
            }
        })?;
        let port = listener.local_addr().map(|a| a.port()).unwrap_or(port);

        let (claude, codex) = {
            let (c, x) = (claude_program.clone(), config.codex_program());
            tokio::task::spawn_blocking(move || (look_for(&c), look_for(&x))).await.unwrap_or_default()
        };
        let mut hosts = options.hosts;
        // The same network only, for now: an address outside the private ranges is not put in the link by itself.
        if let Some(address) = network_address().filter(|a| crate::pairing::is_lan(a)) {
            if !hosts.contains(&address) {
                hosts.insert(0, address);
            }
        }
        if hosts.is_empty() {
            hosts.push("127.0.0.1".into());
        }

        let manager = Arc::new(Manager::new(home.clone(), config.limits, claude_program.clone()));
        manager.set_rules(crate::settings::rules_from(&config));
        let activity = manager.activity();
        let pairing = Arc::new(Mutex::new(Pairing::new(system_clock())));
        let announce_at_home = options.bonjour && config.bonjour;
        let config = Arc::new(Mutex::new(config));
        let name = machine_name();
        let service = RouterService {
            manager: manager.clone(),
            pairing: pairing.clone(),
            config: config.clone(),
            config_path: home.config_path(),
            name: name.clone(),
            claude: claude.clone(),
            codex: codex.clone(),
            activity: activity.clone(),
        };
        let (stop_tx, stop_rx) = oneshot::channel::<()>();
        let served_identity = identity.clone();
        let served = tokio::spawn(async move {
            let stop = async {
                let _ = stop_rx.await;
            };
            if let Err(error) = serve(service, listener, &served_identity, stop).await {
                eprintln!("the router stopped serving: {error}");
            }
        });
        let ticking = manager.clone();
        let idle = tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(60));
            loop {
                tick.tick().await;
                ticking.close_idle().await;
            }
        });

        // No pairing code yet: the terminal asks for a fixed one, the window for watched ones once it is visible.
        let (announcement, bonjour) = if announce_at_home {
            match announce(&name, port, &identity.fingerprint) {
                Ok(a) => (Some(a), BonjourView { announced: true, name: name.clone(), error: None }),
                Err(e) => (None, BonjourView { announced: false, name: name.clone(), error: Some(e) }),
            }
        } else {
            (None, BonjourView::default())
        };
        Ok(Running {
            bonjour,
            announcement,
            home,
            port,
            hosts,
            fingerprint: identity.fingerprint,
            name,
            claude,
            codex,
            claude_program,
            manager,
            activity,
            pairing,
            config,
            stop: Some(stop_tx),
            served: Some(served),
            idle,
        })
    }

    /// For the terminal: makes a fixed one-time code, valid for 300 seconds; any earlier code stops working.
    pub fn new_link(&self) -> String {
        let code = self.pairing.lock().unwrap().new_code();
        self.link_of(&code)
    }

    /// For the window, about once a second while it is visible: makes the code it shows and
    /// renews it. Not called, no code is made and the last one runs out (`pairing.rs`).
    pub fn pairing_seen(&self) {
        self.pairing.lock().unwrap().seen();
    }

    /// For the window: the owner asks for a code after the renewal stopped, or for a fresh one.
    pub fn show_pairing(&self) {
        self.pairing.lock().unwrap().restart();
    }

    /// For the window: the owner copied the shown link, so its code stays a full period longer.
    pub fn hold_pairing(&self) {
        self.pairing.lock().unwrap().hold();
    }

    pub(crate) fn link_of(&self, code: &str) -> String {
        link(&self.hosts, self.port, code, &self.fingerprint)
    }

    /// Unpairs the device whose token hash starts with `id`. Its next call is refused.
    pub fn remove_device(&self, id: &str) -> bool {
        if id.len() < 8 {
            return false;
        }
        let mut config = self.config.lock().unwrap();
        let Some(index) = config.devices.iter().position(|d| d.token_sha256.starts_with(id)) else {
            return false;
        };
        let device = config.devices.remove(index);
        if config.save(&self.home.config_path()).is_err() {
            config.devices.insert(index, device);
            return false;
        }
        self.activity.push(Entry::now(Kind::DeviceRemoved).detail(&device.name));
        true
    }

    pub fn bonjour(&self) -> BonjourView {
        self.bonjour.clone()
    }

    pub fn devices(&self) -> Vec<crate::config::Device> {
        self.config.lock().unwrap().devices.clone()
    }

    /// Stops serving and ends every session's process. Sessions stay on disk.
    pub async fn stop(mut self) {
        drop(self.announcement.take());
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(served) = self.served.take() {
            let _ = served.await;
        }
        self.idle.abort();
        self.manager.shut_down().await;
    }
}
