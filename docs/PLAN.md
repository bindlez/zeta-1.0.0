# Zeta — design & decisions

> **One line:** `oh-my-zsh`-class framework for PowerShell. Same shell semantics you already
> have (every cmdlet, every module, every .NET type), a modern prompt/framework on top.

Status: **v0.1 "vertical slice" implemented**, see `README.md` and `docs/MEASURED.md`.

---

## 1. What "a port of z" means here

"z" in terminal culture has two meanings, so the scope covers both and says so:

| Reading | What it is | How Zeta covers it |
|---|---|---|
| **z = zsh / oh-my-zsh** (framework) | themeable prompt, plugin ecosystem, alias packs, history UX | **primary target** — theme engine, plugin system, PSReadLine integration, alias packs |
| **z = zoxide** (`z dir` frecency jump) | jump to a directory by typing part of its name | shipped as the `z` plugin, backed by the Rust frecency index |

Critically, Zeta is a **framework, not a replacement shell**. It never intercepts parsing,
never wraps `Invoke-Expression`, never replaces the host. Every existing script, module and
`$PSVersionTable` behaviour stays intact — that is the "complete functionality of PowerShell"
requirement. Anything that would change PS semantics (custom tokenizer, custom pipeline) is
out of scope by design.

## 2. Non-goals (explicit, so the surface stays small)

- Not a new shell (no NuShell-style syntax, no custom parser).
- Not a package manager for PowerShell modules (`Install-Module` exists).
- Not a terminal emulator. It *themes* one (Windows Terminal fragment, iTerm/Termux-safe ANSI).
- No telemetry, no network call on prompt render, no remote code execution during `Update`.

## 3. Stack decision: PowerShell core + Rust sidecar

The question "ps1 or rust?" is a false binary. Both, with a hard boundary.

### 3.1 Measured facts (this machine, full detail in `docs/MEASURED.md`)

| Metric | Measured |
|---|---|
| prompt render, warm, async | **4.48 ms** P50 (8.16 ms P95) |
| prompt render, all sensors blocking, cold cache | **17.38 ms** P50 |
| first render in a process (JIT) | up to 251 ms, once |
| startup to first prompt (5.1, OneDrive profile) | ~1.1 s |
| sensor binary | 267 KB, zero crates, 8 Rust unit tests |
| PowerShell suite | 25/25 on 5.1 |

The 3.9× gap between blocking and async rendering is the justification for the whole cache +
worker design. What is *not* separately measured: `zeta-core git` versus `git status` in
isolation. Both were verified to produce identical state on the same repository, and the
sidecar avoids one process spawn, but no isolated microbenchmark was run - so no speed claim
is made for the Rust path beyond "it agrees and it costs one spawn instead of two".

**Conclusion:** the expensive part of a prompt is *not* string building, it is **spawning
child processes and touching the filesystem**. So:

- **PowerShell owns composition**: config, theme model, segment registry, layout, ANSI
  emission, plugin loading, PSReadLine integration, user-facing cmdlets. It is the part that
  must be hackable by the user, and PS is the best language on earth for that on Windows.
- **Rust owns sensors**: git state, frecency index, fast path probes. One static binary,
  **zero crate dependencies** (std only) → 2 s build, ~260 KB, no supply chain, no C toolchain
  risk, and it degrades to a pure-PS fallback when absent.
- **Boundary = TSV over argv/stdout**, not JSON. Rust stays dependency-free; PowerShell's
  `-split "\t"` is free. The protocol is documented and versioned (`zeta-core version`).

A pure-Rust prompt renderer (oh-my-posh style) was rejected: it forces a full config schema
in Rust, a second config format, and a cross-process call **per prompt** just to draw text.
A pure-PS implementation was also rejected: `git status` and directory indexing get
unbearably slow when done naively per prompt.

### 3.2 Compatibility matrix

| Host | Status | Notes |
|---|---|---|
| PowerShell 7.x (Windows/macOS/Linux) | **primary** | truecolor, predictive intellisense, PSReadLine 2.2+ |
| Windows PowerShell 5.1 | **supported, degraded** | no `??`/ternary in code, 16/256-color path, no predictions |
| PSReadLine 2.0 (ships with 5.1) | supported | predictions gated, ListView/MenuComplete still on |

Everything is capability-detected (`Private/Compat.ps1`), never version-sniffed with a single
number. `zeta doctor` prints the resulting matrix for the user's machine.

## 4. Architecture

```
                 ┌──────────────────────────── profile ────────────────────────────┐
                 │  Import-Module Zeta; Initialize-Zeta                            │
                 └───────────────┬─────────────────────────────────────────────────┘
                                 │
   ┌─────────────────────────────▼──────────────────────────────────────────────┐
   │  Zeta.psm1  (pure PowerShell, 5.1 + 7)                                      │
   │                                                                             │
   │  Config.ps1 ── defaults ⊕ user json ⊕ $env:ZETA_*                          │
   │  Theme.ps1  ── palette → ANSI (truecolor/256/16) + glyph tier               │
   │  Segments.ps1 ─ registry: dir, git, status, duration, langs, cloud, …       │
   │  Render.ps1 ── left/right layout, pills, separators, width-aware truncation │
   │  Prompt.ps1 ── writes prompt, records duration, exit code, transient line   │
   │  Cache.ps1  ── TTL cache + ONE background runspace (stale-while-revalidate)  │
   │  Plugins.ps1── discovery, enable/disable state, lazy dot-source             │
   └───────────────┬──────────────────────────────────────────┬──────────────────┘
                   │ TTL-miss / stale                          │ one-shot exec
      ┌────────────▼─────────────┐              ┌─────────────▼─────────────────┐
      │ background runspace      │              │ zeta-core.exe  (Rust, std)    │
      │ (never blocks prompt)    │              │  git   → branch/ahead/dirty   │
      │                          │              │  z     → frecency add/query   │
      └──────────────────────────┘              └───────────────────────────────┘
```

### 4.1 The prompt must never block

The single most important design rule. Two mechanisms:

1. **TTL cache + stale-while-revalidate.** A segment declares a TTL (e.g. git = 2 s, langs =
   60 s). On a prompt render: fresh → use; stale but present → **use the stale value and
   enqueue a refresh**; absent → render a placeholder and enqueue. The user never waits for
   `git status` on a cold prompt.
2. **One background runspace, serialized queue.** Not a runspace per segment (thread-pool
   explosion, PS 5.1 instability). Work is a `[powershell]` instance bound to one runspace;
   the prompt drains at most one completed job per render, so a slow repo cannot pile up.

Cache keys include `$PWD` + config hash, so switching directories never shows foreign data.

### 4.2 Renderer

Segments return a **model** (`Text`, `Icon`, `Fg`, `Bg`, `Style`), never a coloured string.
One renderer turns models into ANSI. Consequences: `NO_COLOR`/`ZETA_NO_COLOR` is one branch,
`zeta theme preview` can render to a string for tests, and width math (truncation, right
alignment) is honest because it measures the *model*, not escape-laden text.

Glyph tiers, auto-detected:
`nerd` (powerline ``/``, requires a Nerd Font) → `unicode` (`` `│ ╭ ╰ › ``) → `ascii`
(`| - >`). Detection: installed font families on Windows, `ZETA_GLYPHS` force-override.
This machine has no Nerd Font, so `unicode` is the default here and every theme is designed
to look correct in both tiers.

### 4.3 Theme model

```jsonc
{
  "name": "tokyo-night",
  "meta": { "variant": "dark", "author": "…" },
  "palette": { "bg": "#1a1b26", "fg": "#c0caf5", "blue": "#7aa2f7" },
  "prompt": {
    "left":  [ { "segment": "context", "style": "plain" },
               { "segment": "dir", "style": "pill", "bg": "blue", "fg": "bg" } ],
    "right": [ { "segment": "duration" }, { "segment": "clock" } ],
    "second": [ { "segment": "git" }, { "segment": "langs" } ]
  },
  "terminal": { …Windows Terminal color scheme, `cursorColor`, `opacity`… }
}
```

`style`: `plain | pill | soft | block`. Colour values are palette names **or** raw hex, so a
theme can be re-coloured without editing the layout. Unknown segment ids are skipped with a
one-time warning (never a crash — a broken theme must not brick your shell).

## 5. Feature parity with oh-my-zsh

| oh-my-zsh | Zeta | Status |
|---|---|---|
| themes, `ZSH_THEME` | `Set-ZetaTheme`, 6 shipped, JSON | done |
| plugins `(git docker …)` | folder-per-plugin, lazy load | done |
| `plugins=(…)` list | `Enable-ZetaPlugin` / config `plugins` | done |
| alias packs | plugin `*.aliases.ps1` | done (git, docker, dotnet, python) |
| `z` / `zoxide` | `z` plugin + Rust index | done |
| `extract`, `take`, `mkcd`, `up` | `core` plugin | done |
| history substring search | PSReadLine `HistorySearchBackward` + key handlers | done (capability-gated) |
| zsh-autosuggestions | PSReadLine predictive intellisense (7.x) | done on 7, `doctor` reports on 5.1 |
| Tab completion styles | `Set-ZetaCompletion tab\|menu\|predictive`, alternate on Shift+Tab | done, verified live |
| zsh-syntax-highlighting | PSReadLine's built-in colouring, themed `-Colors` | done |
| transient prompt | `prompt.transient` (experimental) | opt-in |
| `omz update` | `Update-Zeta` | done |
| `omz doctor` | `Invoke-ZetaDoctor` | done |
| `copypath`, `copyfile` | `clip` plugin | done |
| `alias`/`unalias` | native + `Get-ZetaAlias` listing | native |
| `d` dir history | `dirhistory` plugin (Alt+← / Alt+→) | done |
| p10k-style right prompt | `prompt.right`, width-aware | done |
| instant prompt | stale-while-revalidate cache | done |

## 6. Security model

1. **No network at prompt time.** Only `Update-Zeta` touches the network, on explicit call.
2. **Plugins are local files only.** No `https://…` plugin install in v0.1 — installing code
   by string is the #1 supply-chain hole in shell frameworks. `Enable-ZetaPlugin` accepts a
   local path; remote install is a roadmap item with signature verification.
3. **No `Invoke-Expression` over downloaded content**, no base64 payloads, no autorun from
   the current directory (plugins are resolved inside the module, never `$PWD`).
4. **Atomic writes** for config/frecency (temp file + rename) so a killed prompt can't corrupt
   user state.
5. **Prompts never execute user code paths**; segment params are values, not expressions.

## 7. Repo layout

```
zeta/
  install.ps1               one-command installer (module + profile + WT fragment)
  build.ps1                 build Rust, stage bin/, package
  src/                      PowerShell module source (shipped verbatim)
    Zeta.psd1 Zeta.psm1
    Private/ Public/ Plugins/ Themes/ bin/
  crates/zeta-core/         Rust sidecar, std only, `cargo test` covered
  tests/Verify.ps1          dependency-free assertion harness (runs on 5.1 + 7)
  docs/PLAN.md docs/MEASURED.md
```

## 8. Roadmap

**v0.1 (this delivery)** — core module, 6 themes, 10 plugins, Rust git+frecency, installer,
doctor, bench, tests.

**v0.1.1 (shipped)** — completion modes: `tab` (default) / `menu` dropdown / `predictive`,
toggleable at runtime via `zeta completion`, alternate style always on Shift+Tab. Also fixed
two latent bugs found while testing it: prompt exit-code capture (`$?` was reset before it was
read) and config save writing the whole merged default tree instead of a delta.

**v0.2** — `zeta dash` (ratatui TUI: fuzzy dir/file jump, git branch switch, process killer);
persistent sidecar over named pipe (kills the last ~8 ms of spawn cost); theme hot-reload on
file save; bash/zsh-compatible prompt export (so `PS1`-only tools behave).

**v0.3** — plugin registry with signature verification + `zeta plugin add <git-url>` pinned to
a commit; profile migration for p10k/oh-my-posh users; Windows Terminal settings merge (not
just fragment); accessibility pass (screen-reader-safe prompt, `ZETA_PLAIN=1`).

**Later** — WASM plugin sandbox, `zeta shell-integration` for VS Code/JetBrains terminals.

---

## 8a. Terminal system: PowerShell + Git Bash in one window (0.3 handoff, 0.4 parity, 0.5 studio)

Goal: one terminal, both shells, **the same directory**, jumping back and forth without losing
the place you were in.

### Layer 1 - in-place handoff (works in any terminal)

`zeta shell bash` starts Git Bash in the current directory. The part that is usually missing is
the return trip: a child process cannot change its parent's working directory, so bailing out of
bash normally drops you in the directory you *started* from.

Mechanism: Zeta generates a temporary rcfile that sources the normal startup files and installs
an `EXIT` trap writing `$PWD` to a token file. PowerShell launches
`bash --rcfile <generated> -i`, waits, then reads the token file and `Set-Location`s there.
Bidirectional and lossless, no native code, no PTY.

`exit` in bash returns you to PowerShell **in the directory bash ended in**.

### Layer 2 - peer tabs (Windows Terminal)

`zeta shell tab bash|pwsh` opens a sibling tab at the same directory via
`wt -w 0 new-tab -d <dir> <shell>`. `Ctrl+Tab` moves between them; each tab keeps its own
history and prompt. Reuses the fragment we already install, so both tabs are themed.

### Explicitly rejected for now: a ConPTY multiplexer

A tmux-style single-tab switcher (ConPTY + byte pump + chord interception) is the "pure" answer,
but it is ~800 lines of `unsafe` FFI, it must reimplement resize/scrollback/alt-screen handling,
and a TUI cannot be verified in a headless harness. Shipping it unverified would be worse than
not shipping it. It stays on the roadmap for a phase where it can be watched failing in a real
window.

### Bash parity (0.4.0)

The bash half is generated, not duplicated by hand: `Export-ZetaBashTheme` compiles the active
theme JSON into `~/.zeta/theme.bash` (palette, glyphs, per-segment style + ANSI fragments).
`src/Shell/zeta.bash` renders the prompt from that file and exposes `zeta`.

- **Parity is tested, not asserted:** the suite renders both prompts at width 100 and compares
them after stripping ANSI - they must be byte-identical, or the test fails.
- **Live sync:** every theme change rewrites the file; bash re-sources it when the mtime moves
  (checked every 10 prompts, so the hot path stays fork-free).
- **Hot path:** segment functions write to `REPLY` instead of forking; time comes from
  `EPOCHREALTIME` and `printf %()T`; only git shells out, cached for 2s.
- **`~/.bashrc` hook:** `Install-ZetaBashProfile` covers Git Bash started outside
  `zeta shell bash`. Marker-delimited, interactive-only, idempotent.

### Studio, split and diagnosis (0.5.0)

- **`zeta ui`** - loopback HTTP server (raw TcpListener, no dependencies) plus a single-page
  palette editor. Every API call needs a per-session token; the socket binds 127.0.0.1 only.
  Saves go to the user theme directory and immediately recompile the bash view.
- **`zeta shell split`** - Windows Terminal `split-pane -V`, so both shells are visible at once
  and share a starting directory. Argument vector is built as data and asserted without
  opening a window.
- **`zeta shell diagnose`** - names the broken link in the five-part handoff.
- **mtime-aware caches** - theme and config caches re-stat their files every few calls, which is
  what makes a Studio save show up in a live shell (and in the other shell) without a reload.

### Test plan (what must pass before this ships)
1. `Get-ZetaShell` discovers pwsh, Windows PowerShell, Git Bash and WSL when present, with paths.
2. Generated rcfile passes `bash -n` (real syntax check, not a guess).
3. Round trip: non-interactive `bash --rcfile … -i -c 'cd <dir>; exit'` writes the token file and
   PowerShell adopts that directory - asserted, not assumed.
4. WT tab arguments are built as data (`Get-ZetaShellTabArguments`) and asserted without
   launching a window; `-WhatIf` covers the launch path.
5. Missing bash produces an actionable error (`winget install Git.Git`), never a stack trace.

---

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| PS 5.1 lacks modern syntax → runtime parse errors | CI-style smoke run *on 5.1* in `tests/Verify.ps1`; no `??`, no ternary, no `-AsHashtable` |
| Nerd Font missing → boxes | 3-tier glyph fallback, auto-detected, `doctor` tells you what to install |
| Slow repo stalls prompt | stale-while-revalidate; `ZETA_NO_ASYNC=1` escape hatch |
| Prompt breaks after PSReadLine update | all PSReadLine calls wrapped in capability checks + `try/catch` |
| Rust absent on user machine | pure-PS fallback for every sensor; installer builds only if `cargo` exists |
| Terminal can't show truecolor | `COLORTERM`/WT detection → 256/16 colour quantisation |
| User's `$PROFILE` is precious | marker-delimited idempotent block, `-WhatIf`-able install, `Uninstall-Zeta` removes only that block |

## 10. The commands (what the user actually types)

```powershell
# install (one line, current user, no admin)
.\install.ps1                      # or: .\install.ps1 -Theme tokyo-night

# daily
zeta theme list / zeta theme set nord
zeta plugin list / zeta plugin add z
zeta doctor
zeta bench
```

`install.ps1` is idempotent: re-running upgrades in place and never duplicates profile lines.
(No hosted one-liner yet - the `irm | iex` form needs a release URL, which is roadmap.)

---

## 11. Engineering practices applied

These are the rules the implementation was actually held to, not aspirations:

1. **Capability detection over version sniffing.** `$PSStyle`, `PredictionSource`, Nerd Fonts,
   truecolor and PSReadLine features are each probed and gated. The 5.1 parser is the floor:
   no `??`, no ternary, no `` `e ``, no `-AsHashtable`.
2. **Two implementations, one contract.** Every Rust sensor has a PowerShell fallback, and the
   test suite asserts they agree (`ZETA_NO_CORE=1`). A missing binary degrades, never breaks.
3. **The prompt is a hot path with a budget.** State-keyed memoisation, TTL cache, one worker,
   deduplicated queue. Numbers in `docs/MEASURED.md`, measured with `zeta bench`.
4. **Failures are visible, not silent.** A broken theme warns once and falls back; a broken
   plugin is reported by `zeta doctor`; a broken prompt still prints `zeta> ` so the shell is
   never unusable.
5. **No network, no remote code.** Prompt time makes zero network calls; plugins are local files;
   `Update-Zeta` only runs the installer from the checkout it already trusts, and refuses on a
   dirty tree.
6. **Verification before claims.** 8 Rust tests + 25 PowerShell assertions on 5.1, and an
   explicit "not verified" list for anything a non-interactive environment cannot honestly cover.
7. **Atomic user state.** Config and frecency writes are temp-file-and-rename or append-only, so
   a killed process cannot corrupt them.

### What this is not

Zeta does not parse your commands, wrap `Invoke-Expression`, or replace the host. It is a
framework layered on top of PowerShell - which is why "all of PowerShell" keeps working and why
anything that *would* change PS semantics was rejected during design (section 2).
