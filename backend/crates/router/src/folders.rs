//! Where things live on the router's machine: one folder per topic.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, PartialEq, Eq)]
pub struct FolderError(pub String);

impl fmt::Display for FolderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for FolderError {}

/// True for a name that can be a folder or file name and nothing else:
/// 1 to 64 characters of letters, digits, `-` and `_`.
pub fn is_plain_name(name: &str) -> bool {
    (1..=64).contains(&name.len()) && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A topic's id, checked so that it can never name a way out of the router's folder.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TopicId(String);

impl TopicId {
    pub fn parse(id: &str) -> Result<TopicId, FolderError> {
        if is_plain_name(id) {
            Ok(TopicId(id.to_string()))
        } else {
            Err(FolderError("a topic id is 1 to 64 letters, digits, '-' or '_'".into()))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The folders of one topic.
#[derive(Debug, Clone)]
pub struct TopicDir {
    pub root: PathBuf,
    pub context: PathBuf,
    pub work: PathBuf,
    pub sessions: PathBuf,
}

/// The router's own folder.
#[derive(Debug, Clone)]
pub struct Home {
    root: PathBuf,
}

impl Home {
    pub fn new(root: PathBuf) -> Home {
        Home { root }
    }

    pub fn root(&self) -> &PathBuf {
        &self.root
    }

    pub fn config_path(&self) -> PathBuf {
        self.root.join("router.toml")
    }

    pub fn tls_dir(&self) -> PathBuf {
        self.root.join("tls")
    }

    pub fn topics_dir(&self) -> PathBuf {
        self.root.join("topics")
    }

    /// The topic's folders, created when they are missing.
    pub fn topic(&self, id: &TopicId) -> io::Result<TopicDir> {
        topic_at(&self.topics_dir(), None, id)
    }
}

/// A topic's folders under `base`. With a folder of the user's own, that folder is the sessions'
/// working directory and nothing is created in it; the router's records of the sessions stay
/// under `base` all the same. A folder of one's own that does not exist is an error.
pub fn topic_at(base: &Path, own: Option<&Path>, id: &TopicId) -> io::Result<TopicDir> {
    let records = base.join(id.as_str());
    let sessions = records.join("sessions");
    std::fs::create_dir_all(&sessions)?;
    match own {
        Some(folder) => {
            if !folder.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("the topic's own folder {} does not exist", folder.display()),
                ));
            }
            Ok(TopicDir { context: folder.to_path_buf(), work: folder.to_path_buf(), sessions, root: folder.to_path_buf() })
        }
        None => {
            let dir = TopicDir { context: records.join("context"), work: records.join("work"), sessions, root: records };
            for part in [&dir.context, &dir.work] {
                std::fs::create_dir_all(part)?;
            }
            Ok(dir)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topic_id_refuses_ways_out() {
        let long = "x".repeat(65);
        for bad in ["", "..", "../x", "a/b", "a\\b", "C:", "a b", ".", "a.b", long.as_str()] {
            assert!(TopicId::parse(bad).is_err(), "{bad}");
        }
        assert!(TopicId::parse("3F2A-interview_1").is_ok());
    }

    #[test]
    fn topic_folder_has_three_parts() {
        let dir = tempfile::tempdir().unwrap();
        let home = Home::new(dir.path().into());
        let t = home.topic(&TopicId::parse("t1").unwrap()).unwrap();
        assert!(t.context.is_dir() && t.work.is_dir() && t.sessions.is_dir());
        assert!(t.root.ends_with("topics/t1"));
    }
}
