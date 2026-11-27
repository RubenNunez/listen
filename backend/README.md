# Optional personal Listen Router

Rust workspace for the owner's own Listen devices and official local CLI tools.
It does not distribute a shared account or pooled subscription inference service.

```sh
cargo test --locked --workspace --exclude listen-router-app
cargo run -p listen-router
```

`listen-routerctl` supplies pairing/status commands. `listen-router-app` is the
optional Tauri desktop interface. Its platform dependencies and distribution are
separate from the native voice-assistant app.

Pair your own devices. Keep TLS, per-tool topic scope and owner-selected command
permissions explicit. Never copy tool passwords, cookies or OAuth tokens into the
router. CLI tools retain their own sandbox/approval behavior.

The Linux desktop GUI's glib 0.18 dependency advisory RUSTSEC-2024-0429 remains open;
this source alpha does not distribute a Linux GUI artifact. Do not interpret a
headless workspace test as validation of every desktop platform.
