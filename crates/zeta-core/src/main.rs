//! zeta-core: the sensor half of Zeta.
//!
//! Contract with the PowerShell side is deliberately boring: argv in, one TSV line out.
//! No JSON, no daemon, no crate dependencies. If this binary is missing, every feature it
//! provides has a PowerShell fallback, so a broken build degrades instead of breaking the shell.

mod freq;
mod git;
mod paths;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match args.first().map(|value| value.as_str()) {
        Some("version") | Some("--version") | Some("-V") => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some("git") => match git::run(&args[1..]) {
            Ok(line) => {
                println!("{line}");
                ExitCode::SUCCESS
            }
            Err(message) => {
                // NOREPO is a normal state, not an error.
                if message == git::NOT_A_REPO {
                    println!("{message}");
                    ExitCode::SUCCESS
                } else {
                    println!("ERR\t{message}");
                    ExitCode::SUCCESS
                }
            }
        },
        Some("z") => match freq::run(&args[1..]) {
            Ok(output) => {
                print!("{output}");
                ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("zeta-core: {message}");
                ExitCode::FAILURE
            }
        },
        _ => {
            eprintln!(
                "zeta-core {}\n\nusage:\n  zeta-core version\n  zeta-core git --path <dir>\n  zeta-core z add --path <dir>\n  zeta-core z query [--term <text>] [--limit <n>]\n  zeta-core z compact",
                env!("CARGO_PKG_VERSION")
            );
            ExitCode::from(2)
        }
    }
}
