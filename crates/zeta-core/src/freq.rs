//! Frecency index: an append-only visit log, scored at query time.
//!
//! Line format: `<unix-seconds>\t<absolute-path>`
//!
//! Appending means a killed process can lose at most one record, never the whole database -
//! the failure mode that plagues "rewrite the JSON on every cd" implementations.

use crate::paths;
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

const HALF_LIFE_DAYS: f64 = 30.0;
const COMPACT_THRESHOLD: usize = 5000;
const COMPACT_KEEP: usize = 2000;

pub fn run(args: &[String]) -> Result<String, String> {
    match args.first().map(|value| value.as_str()) {
        Some("add") => {
            let path = paths::arg_value(args, "--path").ok_or("z add: --path is required")?;
            add(&path)?;
            Ok(String::new())
        }
        Some("query") => query(args),
        Some("compact") => {
            compact()?;
            Ok(String::new())
        }
        _ => Err("usage: z add --path <dir> | z query [--term <text>] [--limit <n>] | z compact"
            .to_string()),
    }
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn add(path: &str) -> Result<(), String> {
    let db = paths::frecency_db();
    if let Some(parent) = db.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
    }

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&db)
        .map_err(|error| format!("cannot open {}: {error}", db.display()))?;

    writeln!(file, "{}\t{}", now_seconds(), path).map_err(|error| format!("write failed: {error}"))?;
    Ok(())
}

/// Score one path from its visit timestamps: each visit decays with a 30-day half-life.
pub fn score(visits: &[u64], now: u64) -> f64 {
    visits
        .iter()
        .map(|stamp| {
            let age_days = (now.saturating_sub(*stamp)) as f64 / 86_400.0;
            0.5_f64.powf(age_days / HALF_LIFE_DAYS)
        })
        .sum()
}

fn query(args: &[String]) -> Result<String, String> {
    let term = paths::arg_value(args, "--term").unwrap_or_default().to_lowercase();
    let limit: usize = paths::arg_value(args, "--limit")
        .and_then(|value| value.parse().ok())
        .unwrap_or(10);

    let db = paths::frecency_db();
    if !db.exists() {
        return Ok(String::new());
    }

    let content = std::fs::read_to_string(&db).map_err(|error| format!("cannot read db: {error}"))?;
    let now = now_seconds();

    let mut visits: HashMap<String, Vec<u64>> = HashMap::new();
    for line in content.lines() {
        let mut parts = line.splitn(2, '\t');
        let stamp = match parts.next().and_then(|value| value.parse::<u64>().ok()) {
            Some(value) => value,
            None => continue,
        };
        let path = match parts.next() {
            Some(value) if !value.is_empty() => value,
            _ => continue,
        };
        if !term.is_empty() && !path.to_lowercase().contains(&term) {
            continue;
        }
        visits.entry(path.to_string()).or_default().push(stamp);
    }

    let mut ranked: Vec<(f64, u64, String)> = visits
        .into_iter()
        .filter(|(path, _)| std::path::Path::new(path).exists())
        .map(|(path, stamps)| {
            let last = stamps.iter().copied().max().unwrap_or(0);
            (score(&stamps, now), last, path)
        })
        .collect();

    ranked.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal).then(b.1.cmp(&a.1)));
    ranked.truncate(limit);

    let mut out = String::new();
    for (value, _, path) in ranked {
        out.push_str(&format!("{value:.4}\t{path}\n"));
    }
    Ok(out)
}

fn compact() -> Result<(), String> {
    let db = paths::frecency_db();
    if !db.exists() {
        return Ok(());
    }
    let content = std::fs::read_to_string(&db).map_err(|error| format!("cannot read db: {error}"))?;
    let lines: Vec<&str> = content.lines().filter(|line| !line.trim().is_empty()).collect();
    if lines.len() <= COMPACT_THRESHOLD {
        return Ok(());
    }

    let kept = &lines[lines.len() - COMPACT_KEEP..];
    let temporary = db.with_extension("tmp");
    {
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&temporary)
            .map_err(|error| format!("cannot open temp db: {error}"))?;
        for line in kept {
            writeln!(file, "{line}").map_err(|error| format!("write failed: {error}"))?;
        }
    }
    std::fs::rename(&temporary, &db).map_err(|error| format!("rename failed: {error}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: u64 = 86_400;

    #[test]
    fn fresh_visit_scores_one() {
        assert!((score(&[1_000_000], 1_000_000) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn thirty_day_old_visit_halves() {
        let now = 100 * DAY;
        let value = score(&[now - 30 * DAY], now);
        assert!((value - 0.5).abs() < 1e-9);
    }

    #[test]
    fn frequent_recent_beats_single_old() {
        let now = 100 * DAY;
        let frequent = score(&[now - DAY, now - 2 * DAY, now - 3 * DAY], now);
        let single = score(&[now - 40 * DAY], now);
        assert!(frequent > single);
    }

    #[test]
    fn future_timestamps_do_not_panic() {
        // Clock skew must not produce NaN or a negative age.
        let value = score(&[2_000_000], 1_000_000);
        assert!(value.is_finite());
        assert!((value - 1.0).abs() < 1e-9);
    }
}
