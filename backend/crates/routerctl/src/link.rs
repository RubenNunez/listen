//! The pairing link a router prints: `listen://pair?host=<a>,<b>&port=<n>&code=<c>&fp=<f>`.

#[derive(Debug, PartialEq, Eq)]
pub struct Link {
    pub hosts: Vec<String>,
    pub port: u16,
    pub code: String,
    pub fingerprint: String,
}

pub fn parse(link: &str) -> Result<Link, String> {
    let query = link.trim().strip_prefix("listen://pair?").ok_or("not a listen://pair?… link")?;
    let part = |name: &str| {
        query
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .find(|(key, _)| *key == name)
            .map(|(_, value)| value.to_string())
            .filter(|value| !value.is_empty())
            .ok_or(format!("the link has no {name}"))
    };
    let hosts: Vec<String> = part("host")?.split(',').filter(|h| !h.is_empty()).map(str::to_string).collect();
    if hosts.iter().any(|h| !h.chars().all(|c| c.is_ascii_alphanumeric() || ".-:".contains(c))) {
        return Err("the link has an address that is none".into());
    }
    let fingerprint = part("fp")?.to_ascii_lowercase();
    if !fingerprint.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("the link's fingerprint is not hex".into());
    }
    Ok(Link {
        hosts,
        port: part("port")?.parse().map_err(|_| "the link's port is not a number")?,
        code: part("code")?,
        fingerprint,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_parses() {
        let link = parse("listen://pair?host=192.168.1.5,100.64.0.2&port=50551&code=ABCD2345&fp=ab12").unwrap();
        assert_eq!(
            link,
            Link {
                hosts: vec!["192.168.1.5".into(), "100.64.0.2".into()],
                port: 50551,
                code: "ABCD2345".into(),
                fingerprint: "ab12".into()
            }
        );
    }

    #[test]
    fn other_links_are_refused() {
        for bad in [
            "https://pair?host=a&port=1&code=c&fp=ab",
            "listen://pair?host=a&port=1&code=c",
            "listen://pair?port=1&code=c&fp=ab",
            "listen://pair?host=a&port=x&code=c&fp=ab",
            "listen://pair?host=a/b&port=1&code=c&fp=ab",
            "listen://pair?host=a&port=1&code=c&fp=zz",
            "",
        ] {
            assert!(parse(bad).is_err(), "{bad}");
        }
    }
}
