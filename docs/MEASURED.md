# Measured results

Everything here was measured on the machine this was built on. Numbers are only reported where
a command was actually run; anything unmeasured is listed as unmeasured.

## Environment

| | Windows PowerShell | PowerShell |
|---|---|---|
| Version | 5.1.26100.9818 (Desktop) | **7.6.6 (Core)** |
| PSReadLine | 2.0.0 | **2.4.5** |
| Module path | `…\Documents\WindowsPowerShell\Modules\Zeta` | `…\Documents\PowerShell\Modules\Zeta` |
| Predictions | unavailable (2.0) | available, refused when stdout is redirected |

Shared: Windows 11 build 26200, rustc/cargo 1.97.1 (`x86_64-pc-windows-msvc`), sensor
`zeta-core.exe` **267 KB** with zero crate dependencies, no Nerd Font installed,
Windows Terminal installed but never launched.

> Note: `Documents` is OneDrive-redirected on this machine, and `$env:OS` is stripped by the
> agent sandbox. Both facts broke naive path/platform assumptions; the code now uses
> `[Environment]::GetFolderPath('MyDocuments')` and `OSVersion.Platform`.

## Test results

| Suite | Windows PowerShell 5.1 | PowerShell 7.6.6 |
|---|---|---|
| `cargo test` (Rust) | **8 passed** | **8 passed** |
| `tests/Verify.ps1` | **48 passed, 0 failed** | **48 passed, 0 failed** |
| `build.ps1` parse check | clean | clean |

The suite covers: theme parsing for all 6 themes, truecolor/256/16-colour SGR emission,
`NO_COLOR`, glyph tiers, two-line rendering, escape-leak detection, narrow-width layout,
duration formatting, exit-status rendering, git sensor parity between the Rust and PowerShell
implementations, frecency ranking + dead-directory pruning, plugin discovery and loading,
module-scope plugin helpers, completion modes (reading the live PSReadLine bindings back),
predictive-mode acceptance where supported, delta config persistence, PSReadLine colour
acceptance, the Windows Terminal fragment, doctor, and the benchmark.

## Prompt latency

`Measure-ZetaPrompt`, warm state, width 100, truecolor, unicode glyphs, no repository in the
working directory.

| Host | Mode | Min | P50 | Avg | P95 | Max |
|---|---|---|---|---|---|---|
| 5.1 | async (warm) | 3.58 ms | **4.48 ms** | 7.71 ms | 8.16 ms | 251 ms¹ |
| 5.1 | synchronous | 15.33 ms | 17.38 ms | 18.09 ms | 21.49 ms | 29.99 ms |
| 7.6.6 | async (warm) | 1.84 ms | **2.05 ms** | 3.64 ms | 4.18 ms | 121.6 ms¹ |
| 7.6.6 | synchronous | 13.96 ms | 16.22 ms | 16.50 ms | 23.15 ms | 26.8 ms |

¹ first render in a process pays JIT for the render path. `zeta doctor` discards one warm-up
render before timing, which is why its figure is not skewed by it.

The async design is worth **3.9×** on 5.1 and **7.9×** on PS7 against the blocking path.

## Startup (fresh process → first prompt)

| Host | Import | Initialize | First `prompt` | **Time to prompt** |
|---|---|---|---|---|
| 5.1 (OneDrive profile) | 318 ms | ~608 ms | 188 ms | **~1.1 s** |
| 7.6.6 | 159 ms | 356 ms | 145 ms | **661 ms** |

5.1 phase breakdown: import 223 ms (directory-local), worker runspace + inner module import
142 ms, sensor prime 96 ms, PSReadLine hooks ~70 ms.

**Honest assessment:** 661 ms on PS7 and ~1.1 s on 5.1 are acceptable for a feature-rich
framework, not good. The dominant costs are module import and the one-time worker warm-up, not
the prompt itself. No attempt was made to hide this with a deferred prompt.

## Rust sensor vs PowerShell fallback

Identical results on a purpose-built dirty repository (`feat/terminal`, 1 staged, 1 modified,
1 untracked) — asserted in the suite via `ZETA_NO_CORE=1`:

| Field | Rust (`zeta-core git`) | PowerShell fallback |
|---|---|---|
| branch | `feat/terminal` | `feat/terminal` |
| staged / modified / untracked | 1 / 1 / 1 | 1 / 1 / 1 |
| clean | false | false |

An isolated `zeta-core git` vs `git status` microbenchmark was **not** run, so no speed claim is
made for the native path beyond "one spawn instead of two, same answer".

## Completion modes

Verified against the real PSReadLine key table, not just config state:

| Mode | After switching (`Get-PSReadLineKeyHandler`) |
|---|---|
| `tab` | Tab = `Complete`, Shift+Tab = `MenuComplete` |
| `menu` | Tab = `MenuComplete`, Shift+Tab = `Complete` |
| `predictive` | Tab = `MenuComplete`; on 5.1 refused with an explicit error, on PS7 accepted |

On PS7 with **redirected stdout**, PSReadLine itself refuses predictions:
*"The predictive suggestion feature cannot be enabled because the console output doesn't
support virtual terminal processing or it's redirected."* Zeta now surfaces that exact reason
instead of a generic warning, and `zeta doctor` flags the mismatch. In a real terminal window
the same call is expected to succeed — that visual confirmation is still outstanding.

## PSReadLine colour values

`Set-PSReadLineOption -Colors` accepts `ConsoleColor`, ANSI, or `#rrggbb`, and the ANSI form is
version-sensitive: on 5.1 the backtick-e escape does not exist, so an "ANSI" string is literally
`e[38;…` and is rejected. Zeta passes hex, which 2.0 and 2.4 both accept. The suite asserts the
call actually succeeds rather than assuming it.

## Bugs that only PS7 (or only the sandbox) exposed

1. **Installer binary suffix** — chosen from `PSEdition -eq 'Desktop'`, so under PS7 (`Core`) it
   looked for `zeta-core` with no `.exe` and aborted. Now keyed off `OSVersion.Platform`.
2. **`$env:OS` is not reliable** — the sandbox strips it. Any platform check relying on it is
   wrong; `OSVersion.Platform` is the portable signal.
3. **`Documents` is OneDrive-redirected** — `$HOME\Documents` is not the real path.
4. **Predictions fail silently when redirected** — now reported with PSReadLine's own message.

## Shell handoff (PowerShell + Git Bash)

Verified end to end without a terminal window, because every step is data:

| Assertion | Result |
|---|---|
| `Get-ZetaShell` finds pwsh, Windows PowerShell, Git Bash, WSL | pass (Git Bash at `C:\Program Files\Git\bin\bash.exe`, 5.3.15) |
| Generated rcfile is valid bash (`bash -n`) | pass, exit 0 |
| `bash --rcfile … -i -c 'cd /c/Windows; exit'` records its final dir | pass, token contains `/c/Windows` |
| posix -> Windows conversion restores `C:\Windows` | pass |
| Windows Terminal tab args target the same directory | pass (`new-tab`, `-d`, path, title) |
| Missing Git Bash gives an actionable error | pass (`winget install --id Git.Git`) |

Remaining unverified: the *feel* of an interactive `zeta shell bash` session (prompt, arrows,
Ctrl+D), and a real Windows Terminal tab actually opening and jumping with `Ctrl+Tab`. Both need
a human at a window.

## Bash parity (0.4.0)

The strongest evidence is a regression test rather than a claim: both prompts are rendered at
width 100 with the same theme and working directory, ANSI is stripped, and the two strings must
match exactly.

| Assertion | Result |
|---|---|
| `Export-ZetaBashTheme` output passes `bash -n` | pass |
| bash prompt == PowerShell prompt (stripped) | **identical** (`╭─ ▸ ~/projects/Default … 16:44` / `╰─❯`) |
| `zeta` exists in bash and lists all 6 themes | pass |
| theme change republishes `~/.zeta/theme.bash` | pass |
| generated rcfile boots the runtime with the right theme | pass (`gruvbox-dark\|function`) |
| `~/.bashrc` hook is idempotent and keeps user lines | pass |

## Studio, split and diagnosis (0.5.0)

| Assertion | Result |
|---|---|
| Studio starts on a free loopback port and answers `/api/state` | pass |
| `POST /api/save` writes the user theme file | pass |
| save recompiles `theme.bash` (`ZETA_THEME='studio-test'`) | pass |
| `POST /api/activate` persists the active theme | pass |
| `Stop-ZetaThemeStudio` shuts the job down cleanly | pass |
| split-pane arguments target the same directory | pass (`split-pane -V -d C:\Windows`) |
| `zeta shell diagnose` reports every link green | pass |
| external config write is picked up without reload | pass (flips on the 3rd read) |

Unverified: the studio's *appearance* in a browser (the API is tested, the page is not
screenshotted), and the split pane actually appearing on screen - Windows Terminal has never
launched in this environment.

## What is still not verified

1. **Interactive feel** — predictive suggestions, dropdown navigation, Esc/Enter behaviour and
   syntax-colour rendering are configured and asserted structurally, but this environment is
   non-interactive, so no human-equivalent check was possible.
2. **Nerd Font rendering** — no Nerd Font is installed; the `nerd` tier is tested structurally
   only. `unicode` and `ascii` were rendered and visually inspected via the preview image.
3. **Windows Terminal fragment appearance** — generated and validated as JSON, but WT has never
   launched here, so the themed tab was never seen.
4. **Transient prompt** (`prompt.transient`) — off by default, experimental; needs a real
   terminal session.
5. **Non-Windows hosts** — nothing was run on macOS/Linux; the code paths exist but are
   untested, so no claim is made.

## Reproduce

```powershell
.\build.ps1
.\tests\Verify.ps1                      # current host
powershell -NoProfile -File .\tests\Verify.ps1   # 5.1
Import-Module .\src\Zeta.psd1 -Force
Initialize-Zeta
Measure-ZetaPrompt -Count 100
Measure-ZetaPrompt -Synchronous -Count 30
```
