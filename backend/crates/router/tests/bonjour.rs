use listen_router::bonjour::{announce, announce_as, service_info, SERVICE};
use std::time::Duration;

#[test]
fn txt_has_version_and_fingerprint_only() {
    let info = service_info(SERVICE, "JOULE", 50551, "ab12").unwrap();
    let mut keys: Vec<String> = info.get_properties().iter().map(|p| p.key().to_string()).collect();
    keys.sort();
    assert_eq!(keys, ["fp", "v"]);
    assert_eq!(info.get_property_val_str("fp"), Some("ab12"));
    assert_eq!(info.get_port(), 50551);
}

#[test]
fn bonjour_failure_is_reported_not_fatal() {
    let failed = announce_as("not a service type", "JOULE", 50551, "ab12");
    assert!(failed.is_err());
    assert!(!failed.err().unwrap().is_empty());
}

#[test]
#[ignore = "needs a network interface with multicast"]
fn found_on_this_machine() {
    let name = format!("listen-test-{}", std::process::id());
    let _announced = announce(&name, 50999, "ab12").unwrap();
    let browser = mdns_sd::ServiceDaemon::new().unwrap();
    let events = browser.browse(SERVICE).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) {
        if let Ok(mdns_sd::ServiceEvent::ServiceResolved(info)) = events.recv_timeout(left) {
            if info.get_fullname().starts_with(&name) {
                assert_eq!(info.get_port(), 50999);
                return;
            }
        }
    }
    panic!("not found within 3 s");
}
