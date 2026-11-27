//! The Listen Router: sessions of the `claude` command-line tool, bound to a
//! topic's folder, offered to the Listen apps over gRPC.
//! Design: `docs/ROUTER_DESIGN.md`.

pub mod activity;
pub mod bonjour;
pub mod claude;
pub mod cli;
pub mod codex;
pub mod config;
pub mod folders;
pub mod manager;
pub mod pairing;
pub mod running;
pub mod service;
pub mod session;
pub mod settings;
pub mod snapshot;
pub mod tls;
