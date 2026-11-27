//! Pairing: a one-time code is exchanged for a device token.
//!
//! Codes are handed out in one of two ways:
//! - **Fixed** (`new_code`, the terminal): one code, valid for 300 seconds.
//! - **Watched** (`seen`, the window): while the window is visible the code is replaced every
//!   30 seconds. A code works while it is on screen and for 30 seconds after it left it, so a
//!   scan made just before a renewal still pairs; only the one code before the current one
//!   has that grace. After three minutes without a pairing the renewal stops until the owner
//!   asks again. It also stops on a pairing and on five wrong codes.

use crate::config::{Config, Device};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::sync::Arc;

/// Characters of a pairing code; none that are easily mistaken for another.
const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_LENGTH: usize = 8;
/// How long a fixed code works.
pub const VALID_SECONDS: u64 = 300;
/// How long a watched code stays on screen before the next one replaces it.
pub const RENEW_SECONDS: u64 = 30;
/// How long a watched code still works after it left the screen.
pub const GRACE_SECONDS: u64 = 30;
/// A watched run without a pairing stops renewing after this long.
pub const IDLE_SECONDS: u64 = 180;
/// No sign of the window for longer than this: it was hidden, and what it showed left the screen.
const AWAY_SECONDS: u64 = 10;
/// Wrong codes allowed between two acts of the owner.
const WRONG_TRIES: u32 = 5;
/// Codes that ran out are remembered a while, only to answer "expired" instead of "wrong".
const REMEMBERED: usize = 8;

#[derive(Debug, PartialEq, Eq)]
pub enum PairError {
    /// No code is waiting: none was made, it was used, or it was discarded.
    NoCode,
    Wrong,
    Expired,
}

pub type Clock = Arc<dyn Fn() -> u64 + Send + Sync>;

/// Seconds since 1970.
pub fn system_clock() -> Clock {
    Arc::new(|| std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0))
}

struct Code {
    text: String,
    made_at: u64,
}

/// What a watched run is doing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    /// A code is on screen and is renewed.
    Code,
    /// Nobody paired for `IDLE_SECONDS`: no code until the owner asks for one.
    Idle,
    /// A device paired, by this name: no code until the owner asks for one.
    Paired(String),
    /// Too many wrong codes: no code until the owner asks for one.
    Locked,
}

struct Watch {
    /// When this run of codes began.
    since: u64,
    /// When the window last said it is visible.
    seen: u64,
    phase: Phase,
}

/// What there is to show right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shown {
    pub phase: Phase,
    pub code: Option<String>,
    /// Seconds until the code is replaced (watched) or runs out (fixed).
    pub seconds_left: u64,
    /// The length the countdown started from.
    pub period: u64,
}

pub struct Pairing {
    now: Clock,
    current: Option<Code>,
    /// The code before the current one, and when it left the screen.
    previous: Option<(String, u64)>,
    /// `None`: fixed codes.
    watch: Option<Watch>,
    /// Wrong codes since the owner last asked for one.
    wrong: u32,
    gone: VecDeque<String>,
}

fn fresh(now: u64) -> Code {
    let mut bytes = [0u8; CODE_LENGTH];
    getrandom::fill(&mut bytes).expect("the system gives random bytes");
    // 256 is a multiple of the alphabet's 32 characters, so every character is equally likely.
    let text: String = bytes.iter().map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char).collect();
    Code { text, made_at: now }
}

impl Pairing {
    pub fn new(now: Clock) -> Pairing {
        Pairing { now, current: None, previous: None, watch: None, wrong: 0, gone: VecDeque::new() }
    }

    /// A new fixed code, valid for 300 seconds and usable once. It replaces any earlier one.
    pub fn new_code(&mut self) -> String {
        let code = fresh((self.now)());
        let text = code.text.clone();
        self.current = Some(code);
        self.previous = None;
        self.watch = None;
        self.wrong = 0;
        text
    }

    /// The window is visible right now. Called about once a second while it is; this is what
    /// makes and renews watched codes. Without it the last code runs out by itself.
    pub fn seen(&mut self) {
        let now = (self.now)();
        let Some(watch) = self.watch.as_mut() else {
            return self.begin(now);
        };
        let last = std::mem::replace(&mut watch.seen, now);
        let showing = watch.phase == Phase::Code;
        let idle = now.saturating_sub(watch.since) >= IDLE_SECONDS;
        if now.saturating_sub(last) > AWAY_SECONDS {
            // The window is back: what it showed left the screen when it was last seen.
            self.retire(last);
            self.begin(now);
        } else if showing && idle {
            watch.phase = Phase::Idle;
            self.retire(now);
        } else if showing && self.current.as_ref().is_none_or(|c| now.saturating_sub(c.made_at) >= RENEW_SECONDS) {
            self.retire(now);
            self.current = Some(fresh(now));
        }
        self.lapse(now);
    }

    /// The owner asks for a code: a new watched run, whatever state the last one ended in.
    pub fn restart(&mut self) {
        let now = (self.now)();
        if let Some(last) = self.watch.as_ref().map(|w| w.seen) {
            self.retire(last);
        }
        self.begin(now);
        self.lapse(now);
    }

    /// The owner copied the link of the code on screen, to paste it elsewhere: that code
    /// stays for a full period from now, and the run counts as begun now.
    pub fn hold(&mut self) {
        let now = (self.now)();
        if let (Some(code), Some(watch)) = (self.current.as_mut(), self.watch.as_mut()) {
            if watch.phase == Phase::Code {
                code.made_at = now;
                watch.since = now;
            }
        }
    }

    fn begin(&mut self, now: u64) {
        self.watch = Some(Watch { since: now, seen: now, phase: Phase::Code });
        self.current = Some(fresh(now));
        self.wrong = 0;
    }

    /// The current code leaves the screen; it alone keeps working for the grace period.
    fn retire(&mut self, left_at: u64) {
        if let Some(code) = self.current.take() {
            if let Some((older, _)) = self.previous.replace((code.text, left_at)) {
                self.forget(older);
            }
        }
    }

    fn forget(&mut self, text: String) {
        if self.gone.len() == REMEMBERED {
            self.gone.pop_front();
        }
        self.gone.push_back(text);
    }

    /// Drops the codes whose time is over.
    fn lapse(&mut self, now: u64) {
        if let Some((text, _)) = self.previous.take_if(|(_, left_at)| now > *left_at + GRACE_SECONDS) {
            self.forget(text);
        }
        let over = match &self.watch {
            None => self.current.take_if(|code| now.saturating_sub(code.made_at) > VALID_SECONDS),
            Some(watch) => {
                let seen = watch.seen;
                self.current.take_if(|_| now > seen + GRACE_SECONDS)
            }
        };
        if let Some(code) = over {
            self.forget(code.text);
        }
    }

    pub fn shown(&self) -> Shown {
        let now = (self.now)();
        let age = self.current.as_ref().map(|c| now.saturating_sub(c.made_at)).unwrap_or(0);
        let (phase, period) = match &self.watch {
            Some(watch) => (watch.phase.clone(), RENEW_SECONDS),
            None => (Phase::Code, VALID_SECONDS),
        };
        Shown {
            code: self.current.as_ref().filter(|_| phase == Phase::Code).map(|c| c.text.clone()),
            phase,
            seconds_left: period.saturating_sub(age),
            period,
        }
    }

    /// Exchanges the code for a new device token and stores the token's hash.
    /// The current code and, within its grace period, the one before it are accepted.
    pub fn redeem(&mut self, code: &str, device_name: &str, config: &mut Config) -> Result<String, PairError> {
        let now = (self.now)();
        self.lapse(now);
        let given = code.trim().to_ascii_uppercase();
        let is = |text: &str| same(given.as_bytes(), text.as_bytes());
        let current = self.current.as_ref().is_some_and(|c| is(&c.text));
        let previous = self.previous.as_ref().is_some_and(|(text, _)| is(text));
        if !(current | previous) {
            if self.gone.iter().any(|text| is(text)) {
                return Err(PairError::Expired);
            }
            if self.current.is_none() && self.previous.is_none() {
                return Err(PairError::NoCode);
            }
            self.wrong += 1;
            if self.wrong >= WRONG_TRIES {
                self.current = None;
                self.previous = None;
                if let Some(watch) = self.watch.as_mut() {
                    watch.phase = Phase::Locked;
                }
            }
            return Err(PairError::Wrong);
        }
        // Used: neither this code nor the other one works again.
        self.current = None;
        self.previous = None;
        self.wrong = 0;
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).expect("the system gives random bytes");
        let token = hex(&bytes);
        let name = device_name.trim();
        let name: String = if name.is_empty() { "device".to_string() } else { name.chars().take(64).collect() };
        if let Some(watch) = self.watch.as_mut() {
            watch.phase = Phase::Paired(name.clone());
        }
        config.devices.push(Device { name, token_sha256: sha256_hex(token.as_bytes()), paired_at: now });
        Ok(token)
    }
}

/// The device this token belongs to, if any.
pub fn device_for<'a>(token: &str, config: &'a Config) -> Option<&'a Device> {
    let hash = sha256_hex(token.as_bytes());
    config.devices.iter().find(|d| same(d.token_sha256.as_bytes(), hash.as_bytes()))
}

/// The link a QR code carries: where the router is, the code, and its certificate's fingerprint.
pub fn link(hosts: &[String], port: u16, code: &str, fingerprint: &str) -> String {
    format!("listen://pair?host={}&port={port}&code={code}&fp={fingerprint}", hosts.join(","))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Compares without stopping at the first difference.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The link as a QR code: black on white with its quiet zone, so a camera reads it on a dark screen too.
pub fn qr_svg(link: &str) -> String {
    match qrcode::QrCode::new(link.as_bytes()) {
        Ok(code) => code
            .render::<qrcode::render::svg::Color>()
            .min_dimensions(220, 220)
            .dark_color(qrcode::render::svg::Color("#000000"))
            .light_color(qrcode::render::svg::Color("#ffffff"))
            .build(),
        Err(_) => String::new(),
    }
}

/// The link as a QR code for a terminal, two rows of modules per line.
pub fn qr_terminal(link: &str) -> String {
    use qrcode::render::unicode::Dense1x2;
    match qrcode::QrCode::new(link.as_bytes()) {
        // Light modules drawn as blocks: on a dark terminal the code then reads as dark on light.
        Ok(code) => code.render::<Dense1x2>().dark_color(Dense1x2::Light).light_color(Dense1x2::Dark).build(),
        Err(_) => String::new(),
    }
}

/// Whether an address belongs to a local network: 10/8, 172.16/12, 192.168/16. The link carries only these for now.
pub fn is_lan(address: &str) -> bool {
    match address.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(v4)) => v4.is_private(),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[test]
    fn lan_addresses_are_private_ipv4() {
        for yes in ["192.168.0.25", "10.1.2.3", "172.16.0.1", "172.31.255.255"] {
            assert!(is_lan(yes), "{yes}");
        }
        for no in ["127.0.0.1", "169.254.1.1", "8.8.8.8", "172.32.0.1", "100.64.0.2", "fe80::1", "::1", "router", ""] {
            assert!(!is_lan(no), "{no}");
        }
    }

    #[test]
    fn qr_terminal_is_square_blocks() {
        let text = qr_terminal("listen://pair?host=192.168.0.25&port=50551&code=ABCD2345&fp=ab12");
        let lines: Vec<&str> = text.lines().collect();
        assert!(lines.len() > 10);
        let width = lines[0].chars().count();
        assert!(lines.iter().all(|l| l.chars().count() == width));
        assert!(text.chars().all(|c| " █▀▄\n".contains(c)), "{text}");
    }

    #[test]
    fn qr_svg_is_an_svg_of_the_link() {
        let svg = qr_svg("listen://pair?host=a&port=1&code=c&fp=ab");
        assert!(svg.contains("<svg") && svg.contains("#000000"));
    }

    fn pairing() -> (Pairing, Arc<AtomicU64>) {
        let time = Arc::new(AtomicU64::new(1000));
        let clock = time.clone();
        (Pairing::new(Arc::new(move || clock.load(Ordering::SeqCst))), time)
    }

    #[test]
    fn code_has_eight_unambiguous_characters() {
        let (mut p, _) = pairing();
        let code = p.new_code();
        assert_eq!(code.len(), 8);
        assert!(code.bytes().all(|b| ALPHABET.contains(&b)));
    }

    #[test]
    fn code_works_once() {
        let (mut p, _) = pairing();
        let mut config = Config::default();
        let code = p.new_code();
        assert!(p.redeem(&code, "iPhone", &mut config).is_ok());
        assert_eq!(p.redeem(&code, "iPhone", &mut config), Err(PairError::NoCode));
    }

    #[test]
    fn code_expires_after_300_seconds() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        let code = p.new_code();
        time.fetch_add(301, Ordering::SeqCst);
        assert_eq!(p.redeem(&code, "iPhone", &mut config), Err(PairError::Expired));
        assert!(config.devices.is_empty());
    }

    #[test]
    fn five_wrong_tries_discard_the_code() {
        let (mut p, _) = pairing();
        let mut config = Config::default();
        let code = p.new_code();
        for _ in 0..5 {
            assert_eq!(p.redeem("WRONG000", "x", &mut config), Err(PairError::Wrong));
        }
        assert_eq!(p.redeem(&code, "x", &mut config), Err(PairError::NoCode));
    }

    // Watched codes: the window says "seen" once a second while it is visible.

    /// Lets `seconds` pass with the window visible.
    fn watch(p: &mut Pairing, time: &AtomicU64, seconds: u64) {
        for _ in 0..seconds {
            time.fetch_add(1, Ordering::SeqCst);
            p.seen();
        }
    }

    fn code(p: &Pairing) -> String {
        p.shown().code.expect("a code is shown")
    }

    #[test]
    fn watched_code_is_renewed_every_30_seconds() {
        let (mut p, time) = pairing();
        p.seen();
        let first = code(&p);
        assert_eq!((p.shown().seconds_left, p.shown().period), (30, 30));
        watch(&mut p, &time, 29);
        assert_eq!(code(&p), first);
        assert_eq!(p.shown().seconds_left, 1);
        watch(&mut p, &time, 1);
        assert_ne!(code(&p), first);
        assert_eq!(p.shown().seconds_left, 30);
    }

    #[test]
    fn the_code_before_works_for_a_grace_period_and_only_that_one() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        let first = code(&p);
        watch(&mut p, &time, 30);
        let second = code(&p);
        watch(&mut p, &time, 30);
        // The third code is on screen: the second is in its grace period, the first is out.
        assert_eq!(p.redeem(&first, "x", &mut config), Err(PairError::Expired));
        assert!(p.redeem(&second, "iPhone", &mut config).is_ok());
    }

    #[test]
    fn grace_ends_30_seconds_after_the_code_left_the_screen() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        let first = code(&p);
        watch(&mut p, &time, 59);
        // `first` left the screen at second 30.
        assert!(p.redeem(&first, "iPhone", &mut config).is_ok(), "29 seconds after it left the screen");

        let (mut p, time) = pairing();
        p.seen();
        let first = code(&p);
        watch(&mut p, &time, 30);
        // The window is hidden from here on, so no third code pushes it out: time alone ends it.
        time.fetch_add(31, Ordering::SeqCst);
        assert_eq!(p.redeem(&first, "x", &mut config), Err(PairError::Expired));
        assert_eq!(config.devices.len(), 1);
    }

    #[test]
    fn a_used_code_ends_the_other_one_and_the_run() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        let first = code(&p);
        watch(&mut p, &time, 31);
        let second = code(&p);
        assert!(p.redeem(&first, " Anna's iPhone ", &mut config).is_ok());
        assert_eq!(p.redeem(&second, "x", &mut config), Err(PairError::NoCode));
        assert_eq!(p.shown().phase, Phase::Paired("Anna's iPhone".into()));
        // No further code by itself, however long the window stays open.
        watch(&mut p, &time, 120);
        assert_eq!(p.shown().code, None);
        assert_eq!(config.devices.len(), 1);
        p.restart();
        assert_eq!(p.shown().phase, Phase::Code);
        assert!(p.redeem(&code(&p), "Mac", &mut config).is_ok());
    }

    #[test]
    fn renewal_stops_after_three_idle_minutes() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        watch(&mut p, &time, 179);
        assert_eq!(p.shown().phase, Phase::Code);
        let last = code(&p);
        watch(&mut p, &time, 1);
        assert_eq!((p.shown().phase, p.shown().code), (Phase::Idle, None));
        // The last code shown keeps its grace period, then nothing works.
        watch(&mut p, &time, 31);
        assert_eq!(p.redeem(&last, "x", &mut config), Err(PairError::Expired));
        watch(&mut p, &time, 600);
        assert_eq!(p.shown().phase, Phase::Idle);
        p.restart();
        assert!(p.redeem(&code(&p), "iPhone", &mut config).is_ok());
    }

    #[test]
    fn a_scan_at_the_moment_renewal_stops_still_pairs() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        watch(&mut p, &time, 179);
        let last = code(&p);
        watch(&mut p, &time, 20);
        assert_eq!(p.shown().phase, Phase::Idle);
        assert!(p.redeem(&last, "iPhone", &mut config).is_ok());
    }

    #[test]
    fn hidden_window_makes_no_codes_and_the_last_one_lapses() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        watch(&mut p, &time, 5);
        let shown = code(&p);
        // Hidden: no more `seen`. The code is not replaced and runs out 30 seconds after it was last seen.
        time.fetch_add(30, Ordering::SeqCst);
        assert_eq!(code(&p), shown, "nothing renews it");
        assert!(p.redeem(&shown, "iPhone", &mut config).is_ok(), "still inside the grace period");

        let (mut p, time) = pairing();
        p.seen();
        let shown = code(&p);
        time.fetch_add(31, Ordering::SeqCst);
        assert_eq!(p.redeem(&shown, "x", &mut config), Err(PairError::Expired));
        time.fetch_add(3600, Ordering::SeqCst);
        assert_eq!(p.redeem(&shown, "x", &mut config), Err(PairError::Expired));
        assert_eq!(p.redeem("ABCD2345", "x", &mut config), Err(PairError::NoCode), "no code is valid unseen");
    }

    #[test]
    fn window_shown_again_starts_with_a_fresh_code() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        watch(&mut p, &time, 180);
        assert_eq!(p.shown().phase, Phase::Idle);
        time.fetch_add(3600, Ordering::SeqCst);
        p.seen();
        assert_eq!((p.shown().phase, p.shown().seconds_left), (Phase::Code, 30));

        // Hidden for a moment only: the code from before is the one in its grace period.
        let before = code(&p);
        time.fetch_add(20, Ordering::SeqCst);
        p.seen();
        assert_ne!(code(&p), before);
        assert!(p.redeem(&before, "iPhone", &mut config).is_ok());
    }

    #[test]
    fn wrong_tries_count_across_renewals_and_lock_the_run() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        for _ in 0..4 {
            assert_eq!(p.redeem("WRONG000", "x", &mut config), Err(PairError::Wrong));
            watch(&mut p, &time, 30);
        }
        let right = code(&p);
        assert_eq!(p.redeem("WRONG000", "x", &mut config), Err(PairError::Wrong));
        assert_eq!(p.shown().phase, Phase::Locked);
        assert_eq!(p.redeem(&right, "x", &mut config), Err(PairError::NoCode));
        watch(&mut p, &time, 60);
        assert_eq!(p.shown().code, None, "no new code without the owner");
        p.restart();
        assert!(p.redeem(&code(&p), "iPhone", &mut config).is_ok());
    }

    #[test]
    fn an_expired_code_is_no_wrong_try() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        let first = code(&p);
        watch(&mut p, &time, 90);
        for _ in 0..10 {
            assert_eq!(p.redeem(&first, "x", &mut config), Err(PairError::Expired));
        }
        assert_eq!(p.shown().phase, Phase::Code);
    }

    #[test]
    fn restart_keeps_the_code_before_for_its_grace_period() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        let first = code(&p);
        watch(&mut p, &time, 10);
        p.restart();
        assert_ne!(code(&p), first);
        assert_eq!(p.shown().seconds_left, 30);
        assert!(p.redeem(&first, "iPhone", &mut config).is_ok());
    }

    #[test]
    fn a_held_code_stays_a_full_period_longer() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        let copied = code(&p);
        watch(&mut p, &time, 28);
        p.hold();
        assert_eq!(p.shown().seconds_left, 30);
        watch(&mut p, &time, 29);
        assert_eq!(code(&p), copied);
        watch(&mut p, &time, 30);
        assert_ne!(code(&p), copied);
        assert!(p.redeem(&copied, "Mac", &mut config).is_ok(), "pasted 59 seconds after copying");
    }

    #[test]
    fn a_fixed_code_is_not_renewed_and_ends_a_watched_run() {
        let (mut p, time) = pairing();
        let mut config = Config::default();
        p.seen();
        let watched = code(&p);
        let fixed = p.new_code();
        assert_eq!((p.shown().period, p.shown().seconds_left), (300, 300));
        assert_eq!(p.redeem(&watched, "x", &mut config), Err(PairError::Wrong));
        time.fetch_add(299, Ordering::SeqCst);
        assert_eq!(code(&p), fixed);
        assert!(p.redeem(&fixed, "terminal", &mut config).is_ok());
    }

    #[test]
    fn token_is_stored_only_as_hash() {
        let (mut p, _) = pairing();
        let mut config = Config::default();
        let code = p.new_code();
        let token = p.redeem(&code, "iPhone", &mut config).unwrap();
        assert_eq!(config.devices.len(), 1);
        assert_ne!(config.devices[0].token_sha256, token);
        assert!(device_for(&token, &config).is_some());
        assert!(device_for("other", &config).is_none());
    }

    #[test]
    fn link_has_the_spec_shape() {
        assert_eq!(
            link(&["192.168.1.5".into(), "100.64.0.2".into()], 50551, "ABCD2345", "ab12"),
            "listen://pair?host=192.168.1.5,100.64.0.2&port=50551&code=ABCD2345&fp=ab12"
        );
    }
}
