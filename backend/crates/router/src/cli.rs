//! Which command-line tool a session runs, behind one interface for the session.

use crate::claude::{self, Out, Spawn};
use crate::codex;
use std::io;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Cli {
    #[default]
    Claude,
    Codex,
}

pub enum Process {
    Claude(claude::Process),
    Codex(codex::Process),
}

impl Process {
    pub fn start(spawn: &Spawn) -> io::Result<Process> {
        Ok(match spawn.cli {
            Cli::Claude => Process::Claude(claude::Process::start(spawn)?),
            Cli::Codex => Process::Codex(codex::Process::start(spawn)?),
        })
    }

    pub async fn send(&mut self, text: &str) -> io::Result<()> {
        match self {
            Process::Claude(p) => p.send(text).await,
            Process::Codex(p) => p.send(text).await,
        }
    }

    pub async fn next(&mut self) -> Option<Out> {
        match self {
            Process::Claude(p) => p.next().await,
            Process::Codex(p) => p.next().await,
        }
    }

    pub async fn kill(self) {
        match self {
            Process::Claude(p) => p.kill().await,
            Process::Codex(p) => p.kill().await,
        }
    }
}
