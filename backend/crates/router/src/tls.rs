//! The router's own certificate. Apps trust it by its fingerprint, which they get when pairing.

use crate::pairing::sha256_hex;
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::CertificateDer;
use std::io;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct Identity {
    pub cert_pem: String,
    pub key_pem: String,
    /// SHA-256 of the certificate's DER bytes, lower-case hex.
    pub fingerprint: String,
}

/// The name every client asks for; the certificate is checked by fingerprint, not by address.
pub const SERVER_NAME: &str = "listen-router";

/// Reads the certificate in `dir`, or makes one on the first start.
pub fn load_or_create(dir: &Path) -> io::Result<Identity> {
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    if !cert_path.exists() || !key_path.exists() {
        let made = rcgen::generate_simple_self_signed(vec![SERVER_NAME.to_string(), "localhost".to_string()])
            .map_err(|e| io::Error::other(e.to_string()))?;
        std::fs::create_dir_all(dir)?;
        std::fs::write(&cert_path, made.cert.pem())?;
        std::fs::write(&key_path, made.signing_key.serialize_pem())?;
    }
    let cert_pem = std::fs::read_to_string(&cert_path)?;
    let key_pem = std::fs::read_to_string(&key_path)?;
    let fingerprint = fingerprint_of_pem(&cert_pem)?;
    Ok(Identity { cert_pem, key_pem, fingerprint })
}

pub fn fingerprint_of_pem(cert_pem: &str) -> io::Result<String> {
    let der = CertificateDer::from_pem_slice(cert_pem.as_bytes())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;
    Ok(sha256_hex(der.as_ref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_created_once_and_reused() {
        let dir = tempfile::tempdir().unwrap();
        let first = load_or_create(dir.path()).unwrap();
        let second = load_or_create(dir.path()).unwrap();
        assert_eq!(first.fingerprint, second.fingerprint);
        assert_eq!(first.fingerprint.len(), 64);
        assert!(first.fingerprint.bytes().all(|b| b.is_ascii_hexdigit()));
    }
}
