//! Git sensor: one process spawn, parsed in-process, emitted as a single TSV line.
//!
//! Branch/stash are read straight from `.git` so they still work when the `git` binary is
//! missing; only the working-tree counters need `git status`.

use crate::paths;
use std::path::Path;
use std::process::Command;

pub const NOT_A_REPO: &str = "NOREPO";

#[derive(Debug, Default, PartialEq)]
pub struct GitState {
    pub branch: String,
    pub ahead: u32,
    pub behind: u32,
    pub staged: u32,
    pub modified: u32,
    pub untracked: u32,
    pub conflict: u32,
    pub stash: u32,
    pub detached: bool,
}

impl GitState {
    /// `OK branch ahead behind staged modified untracked conflict stash detached`
    pub fn to_tsv(&self) -> String {
        let branch = if self.branch.is_empty() {
            "HEAD".to_string()
        } else {
            self.branch.replace('\t', " ")
        };
        format!(
            "OK\t{branch}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            self.ahead,
            self.behind,
            self.staged,
            self.modified,
            self.untracked,
            self.conflict,
            self.stash,
            if self.detached { 1 } else { 0 }
        )
    }
}

pub fn run(args: &[String]) -> Result<String, String> {
    let target = paths::arg_value(args, "--path").unwrap_or_else(|| ".".to_string());
    let start = Path::new(&target);

    let root = paths::find_repo_root(start).ok_or_else(|| NOT_A_REPO.to_string())?;
    let git_dir = paths::resolve_git_dir(&root);

    let mut state = GitState::default();
    state.stash = read_stash_count(git_dir.as_deref());
    state.branch = read_branch(git_dir.as_deref());

    if let Some(output) = run_status(start) {
        parse_status(&output, &mut state);
    }

    Ok(state.to_tsv())
}

fn read_branch(git_dir: Option<&Path>) -> String {
    let dir = match git_dir {
        Some(value) => value,
        None => return String::new(),
    };
    let head_path = dir.join("HEAD");
    if let Ok(content) = std::fs::read_to_string(head_path) {
        let line = content.lines().next().unwrap_or("").trim();
        if let Some(reference) = line.strip_prefix("ref: refs/heads/") {
            return reference.to_string();
        }
        if line.len() >= 7 {
            return line[..7].to_string();
        }
    }
    String::new()
}

fn read_stash_count(git_dir: Option<&Path>) -> u32 {
    let dir = match git_dir {
        Some(value) => value,
        None => return 0,
    };
    match std::fs::read_to_string(dir.join("logs").join("refs").join("stash")) {
        Ok(content) => content.lines().filter(|line| !line.trim().is_empty()).count() as u32,
        Err(_) => 0,
    }
}

fn run_status(path: &Path) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args([
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=normal",
            "--ignore-submodules=dirty",
        ])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Exposed for unit tests: the parser is the part that breaks when git changes its format.
pub fn parse_status(output: &str, state: &mut GitState) {
    for line in output.lines() {
        if let Some(rest) = line.strip_prefix("# branch.head ") {
            let name = rest.trim();
            if name == "(detached)" {
                state.detached = true;
                if state.branch.is_empty() {
                    state.branch = "HEAD".to_string();
                }
            } else {
                state.branch = name.to_string();
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("# branch.ab ") {
            for token in rest.split_whitespace() {
                if let Some(value) = token.strip_prefix('+') {
                    state.ahead = value.parse().unwrap_or(0);
                } else if let Some(value) = token.strip_prefix('-') {
                    state.behind = value.parse().unwrap_or(0);
                }
            }
            continue;
        }
        if line.starts_with("? ") {
            state.untracked += 1;
            continue;
        }
        if line.starts_with("u ") {
            state.conflict += 1;
            continue;
        }
        if line.starts_with("1 ") || line.starts_with("2 ") {
            // "1 XY sub mH mI mW hH hI path"
            let bytes = line.as_bytes();
            if bytes.len() >= 4 {
                let x = bytes[2] as char;
                let y = bytes[3] as char;
                if x != '.' && x != ' ' {
                    state.staged += 1;
                }
                if y != '.' && y != ' ' {
                    state.modified += 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "# branch.oid 1234567\n\
# branch.head main\n\
# branch.ab +2 -1\n\
1 M. N... 100644 100644 100644 aaa bbb src/main.rs\n\
1 .M N... 100644 100644 100644 ccc ddd src/lib.rs\n\
2 R. N... 100644 100644 100644 eee fff R100 new.rs\told.rs\n\
? untracked.txt\n\
u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.rs\n";

    #[test]
    fn parses_counts_and_branch() {
        let mut state = GitState::default();
        parse_status(SAMPLE, &mut state);
        assert_eq!(state.branch, "main");
        assert_eq!(state.ahead, 2);
        assert_eq!(state.behind, 1);
        assert_eq!(state.staged, 2, "M. and R. are staged");
        assert_eq!(state.modified, 1, "one .M line in the sample");
        assert_eq!(state.untracked, 1);
        assert_eq!(state.conflict, 1);
        assert!(!state.detached);
    }

    #[test]
    fn parses_detached_head() {
        let mut state = GitState::default();
        parse_status("# branch.head (detached)\n# branch.ab +0 -0\n", &mut state);
        assert!(state.detached);
        assert_eq!(state.branch, "HEAD");
    }

    #[test]
    fn tsv_shape_is_stable() {
        let state = GitState {
            branch: "feat/x".into(),
            ahead: 1,
            behind: 2,
            staged: 3,
            modified: 4,
            untracked: 5,
            conflict: 6,
            stash: 7,
            detached: false,
        };
        let line = state.to_tsv();
        let fields: Vec<&str> = line.split('\t').collect();
        assert_eq!(fields.len(), 10);
        assert_eq!(fields[0], "OK");
        assert_eq!(fields[1], "feat/x");
        assert_eq!(fields[9], "0");
    }

    #[test]
    fn tabs_in_branch_are_neutralised() {
        let state = GitState {
            branch: "weird\tbranch".into(),
            ..Default::default()
        };
        assert_eq!(state.to_tsv().split('\t').count(), 10);
    }
}
