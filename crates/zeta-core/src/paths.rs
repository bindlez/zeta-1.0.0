//! Path helpers shared by the git sensor and the frecency index.

use std::path::{Path, PathBuf};

/// Walk up from `start` looking for a `.git` entry (directory or worktree file).
pub fn find_repo_root(start: &Path) -> Option<PathBuf> {
    let mut current = if start.is_dir() {
        start.to_path_buf()
    } else {
        start.parent()?.to_path_buf()
    };

    loop {
        if current.join(".git").exists() {
            return Some(current);
        }
        if !current.pop() {
            return None;
        }
    }
}

/// Resolve the real git directory, following the `gitdir: <path>` indirection used by
/// worktrees and submodules.
pub fn resolve_git_dir(repo_root: &Path) -> Option<PathBuf> {
    let dot_git = repo_root.join(".git");
    if dot_git.is_dir() {
        return Some(dot_git);
    }

    let contents = std::fs::read_to_string(&dot_git).ok()?;
    let line = contents.lines().next()?;
    let target = line.strip_prefix("gitdir:")?.trim();
    let target_path = Path::new(target);
    if target_path.is_absolute() {
        Some(target_path.to_path_buf())
    } else {
        Some(repo_root.join(target_path))
    }
}

/// Home-relative user data directory, matching the PowerShell `Get-ZetaDataRoot`.
pub fn data_root() -> PathBuf {
    if let Ok(explicit) = std::env::var("ZETA_ROOT") {
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }

    if cfg!(windows) {
        if let Ok(local) = std::env::var("LOCALAPPDATA") {
            if !local.is_empty() {
                return PathBuf::from(local).join("Zeta");
            }
        }
    } else if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("zeta");
        }
    }

    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".local").join("share").join("zeta")
}

pub fn frecency_db() -> PathBuf {
    data_root().join("db").join("frecency.tsv")
}

/// `--name value` reader shared by the subcommands.
pub fn arg_value(args: &[String], name: &str) -> Option<String> {
    let mut index = 0;
    while index + 1 < args.len() {
        if args[index] == name {
            return Some(args[index + 1].clone());
        }
        index += 1;
    }
    None
}
