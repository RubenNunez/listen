//! Trusting a router by the fingerprint of its certificate.
//!
//! The router's certificate is its own, signed by nobody. The pairing link carries the SHA-256
//! of it. This connects once, takes whatever certificate the other side shows, and accepts it
//! only if its fingerprint is the one from the link. From then on exactly that certificate is trusted.

use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use tokio::net::TcpStream;
use tokio_rustls::rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use tokio_rustls::rustls::crypto::{ring, verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use tokio_rustls::rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use tokio_rustls::rustls::{ClientConfig, DigitallySignedStruct, Error, SignatureScheme};
use tokio_rustls::TlsConnector;

/// Lets the handshake finish with any certificate and keeps it for the fingerprint check.
#[derive(Debug)]
struct Capture {
    provider: Arc<CryptoProvider>,
    seen: Mutex<Option<Vec<u8>>>,
}

impl ServerCertVerifier for Capture {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        *self.seen.lock().unwrap() = Some(end_entity.as_ref().to_vec());
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// The certificate the machine at `host:port` shows, as PEM, if its fingerprint is `fingerprint`.
/// Nothing is sent over this connection.
pub async fn certificate(host: &str, port: u16, fingerprint: &str) -> Result<String, Box<dyn std::error::Error>> {
    let provider = Arc::new(ring::default_provider());
    let capture = Arc::new(Capture { provider: provider.clone(), seen: Mutex::new(None) });
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(capture.clone())
        .with_no_client_auth();
    let stream = tokio::time::timeout(std::time::Duration::from_secs(5), TcpStream::connect((host, port)))
        .await
        .map_err(|_| "no answer")??;
    let name = ServerName::try_from("listen-router")?;
    drop(TlsConnector::from(Arc::new(config)).connect(name, stream).await?);
    let der = capture.seen.lock().unwrap().take().ok_or("the router showed no certificate")?;
    let shown: String = Sha256::digest(&der).iter().map(|b| format!("{b:02x}")).collect();
    if shown != fingerprint.to_ascii_lowercase() {
        return Err("this is not the router the link names: its certificate has another fingerprint".into());
    }
    Ok(pem(&der))
}

fn pem(der: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::new();
    for chunk in der.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                encoded.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                encoded.push('=');
            }
        }
    }
    let lines: Vec<&str> = encoded.as_bytes().chunks(64).map(|line| std::str::from_utf8(line).unwrap_or("")).collect();
    format!("-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n", lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pem_encodes_base64_with_padding() {
        assert_eq!(pem(b"Ma"), "-----BEGIN CERTIFICATE-----\nTWE=\n-----END CERTIFICATE-----\n");
        assert_eq!(pem(b"Man"), "-----BEGIN CERTIFICATE-----\nTWFu\n-----END CERTIFICATE-----\n");
        assert_eq!(pem(b"M"), "-----BEGIN CERTIFICATE-----\nTQ==\n-----END CERTIFICATE-----\n");
    }
}
