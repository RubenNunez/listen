//! Announcing the router in the local network, so a Mac at home finds it without typing an address.
//! The record carries the version and the certificate's fingerprint, never a pairing code.

use mdns_sd::{ServiceDaemon, ServiceInfo};

pub const SERVICE: &str = "_listen-router._tcp.local.";

/// The record for this router: instance `name`, gRPC `port`, TXT `v` and `fp`.
pub fn service_info(service: &str, name: &str, port: u16, fingerprint: &str) -> Result<ServiceInfo, String> {
    let host: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    let properties = [("v", "1"), ("fp", fingerprint)];
    ServiceInfo::new(service, name, &format!("{host}.local."), "", port, &properties[..])
        .map(|info| info.enable_addr_auto())
        .map_err(|e| e.to_string())
}

/// While this lives the router is announced; dropping it withdraws the record.
pub struct Announcement {
    daemon: ServiceDaemon,
    fullname: String,
}

pub fn announce(name: &str, port: u16, fingerprint: &str) -> Result<Announcement, String> {
    announce_as(SERVICE, name, port, fingerprint)
}

pub fn announce_as(service: &str, name: &str, port: u16, fingerprint: &str) -> Result<Announcement, String> {
    let info = service_info(service, name, port, fingerprint)?;
    let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
    let fullname = info.get_fullname().to_string();
    if let Err(e) = daemon.register(info) {
        let _ = daemon.shutdown();
        return Err(e.to_string());
    }
    Ok(Announcement { daemon, fullname })
}

impl Drop for Announcement {
    fn drop(&mut self) {
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}
