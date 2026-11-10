# AGENTS.md

micro self-executable SAPI for PHP (a fork of dixyes/phpmicro): a PHP SAPI that builds `micro.sfx`, a PHP binary to which a PHP script or PHAR is concatenated to make a single self-executable file (PHP 8+, Windows, Linux, macOS). The C sources (`php_micro*.c/h`), `config.m4` / `config.w32` and `Makefile.frag*` are dropped into PHP's `sapi/micro`; `patches/` holds patches for the PHP source tree; `tests/` holds the sanity tests run by `make micro_test`; `docs/` is the VitePress documentation site; `.github/workflows/` builds the SFX and runs tests in CI. The `sibling-phar` branch adds a sibling-payload mode (the PHP payload sits next to the executable, including in macOS `../Resources` bundles) so the executable itself can be code-signed, plus Windows/Authenticode and CI changes for bundling in a desktop app. `build-sfx.yml` builds macOS and Windows fully static and Linux against glibc (dynamic, 2.35 floor; see the comments on its `build-linux` job and `.github/scripts/check-linux-sfx.sh`); every run publishes to the rolling `sfx-latest` release and to an immutable `sfx-<YYYYMMDD>.<run>` release that consumers pin by SHA-256. A manual run can build a subset (`platforms`), so fixing one platform does not rebuild, and change, the others. `.github/scripts/check-macos-sfx.sh` is the macOS counterpart of the Linux check (a thin Mach-O of the expected arch, `minos` ≤ 12.0 read from `LC_BUILD_VERSION`, only OS libraries, and every payload mode including the bundle's `../Resources/<basename>.phar` behind an extra-INI block, through a symlink, and signed ad hoc with and without the hardened runtime); the build job and the promotion run it. `.github/scripts/check-windows-sfx.sh` is the Windows one (grafida/grafida#91): the PE checks (PE32+ AMD64, the subsystem, imports only from DLLs that ship with Windows, so no Visual C++ runtime, and no overlay) are in `check-windows-sfx-pe.php` and run anywhere with `--static-only`; the runtime checks (`check-windows-sfx.ps1`: every payload mode, both sibling names `<self without .exe>.phar` and `<self>.phar`, the extra-INI block, a self-signed stub, 50 MiB through STDIN and STDOUT over real pipes, and no console window for the SFX's own children) need Windows and refuse to be skipped silently.

**The Windows SFX is a GUI-subsystem PE** (`--enable-micro-win32`), and that is fine for a worker spoken to over pipes: the CRT takes the redirected handles, and `php_micro.c` sets all three streams to binary mode as the CLI does (50 MiB round trip in `check-windows-sfx.sh`). ⚠️ **But its console children open a visible console window** (grafida/grafida#91): upstream PHP adds `CREATE_NO_WINDOW` to every `proc_open`/`popen` child outside the `cli` SAPI, and the `cli_checks` patch (`patches/cli_checks_84.patch`, and static-php-cli's copy, which is the one the build applies) makes `micro` count as `cli` there, so the flag is dropped. A GUI process has no console to share, so each child gets a new one: on Windows 11 a Windows Terminal window. A child cannot tell from its own console (with Windows Terminal as the default terminal every console has a "visible" 0x0 `PseudoConsoleWindow`), so the check watches the desktop with a WinEvent hook, and needs an interactive session. **The Windows job therefore drops exactly those two hunks** from static-php-cli's `cli_checks_*.patch` before it builds (`.github/scripts/keep-create-no-window.php`), restoring upstream PHP's `CREATE_NO_WINDOW` for micro; the step fails if a static-php-cli bump changes them. (`patches/` here is upstream phpmicro's own copy, which our build does not apply.)

## CI: what a push to `sibling-phar` does

**Every push to `sibling-phar` rebuilds every platform and rewrites `sfx-latest`**, whose assets Grafida's Boson-era release downloads: a rebuild picks up the newest PHP 8.4 patch release, so it changes what Boson ships. A commit that is not meant to rebuild (a check script, a doc, the workflow itself) carries **`[skip ci]`** in its message.

To pin a runtime that only exists in `sfx-latest` without rebuilding it, dispatch a **promotion**: `gh workflow run build-sfx.yml -R grafida/phpmicro --ref sibling-phar -f platforms=promote-macos-aarch64 -f sha256=<hash>`. It builds nothing and never writes `sfx-latest`: it checks the asset against the stated hash and the published `.sha256`, runs the check script on it, and publishes it alone to a new immutable release (grafida/grafida#88). To build a Windows runtime from the current workflow and pin it **without** touching `sfx-latest`, dispatch `platforms=windows-immutable`: it builds and checks Windows alone and publishes only the immutable release (grafida/grafida#91). Each is a mode of `build-sfx.yml` rather than a workflow of its own because GitHub only dispatches a workflow that is on the default branch (`master`, upstream's) or has already run.

## Git: commit and tag outside the sandbox

Commits and tags are always signed, with a key held in 1Password. The 1Password signing agent is reached
over a local socket that agent sandboxes do not expose, so a sandboxed `git commit` or `git tag` **always**
fails (e.g. `error: 1Password: Could not connect to socket. Is the agent running?`).

Run every `git commit` and `git tag` **outside the sandbox from the first attempt** — in Claude Code with
`dangerouslyDisableSandbox: true`, in other harnesses with their equivalent unsandboxed / escalated
execution. Do not try the sandboxed form first, do not diagnose the failure, and never work around it
with `--no-gpg-sign`, `-c commit.gpgsign=false` or unsigned tags.

## Project memory

Project memory lives in `.claude/memory/`, committed with the code, so that it is shared across machines
and across agentic harnesses (Claude Code, Codex, Qwen Code, Kimi Code, Junie, …).

There are no memory files yet. When there is something worth remembering, create `.claude/memory/`,
the topic file, and a table here mapping each file to a concrete trigger ("Before you… | Read").

### Recording new memories

This is the **default and only** place for project memory. Do not write memories for this project to a
harness's private memory store (such as Claude Code's auto-memory under `~/.claude/projects/`); write
them here instead:

- Add to the existing topic file when one fits; otherwise create a new kebab-case `.md` file named after
  the topic, and add a row for it to the table above with a concrete trigger.
- Plain Markdown, no frontmatter. State the rule, then **Why:** (the reason or incident behind it) and
  **How to apply:**. Link related files with relative Markdown links.
- Don't record what the code, Git history or an existing `AGENTS.md` already says — update that
  `AGENTS.md` instead when the rule belongs there. Remove or correct entries that turn out wrong.
- These files are committed: no secrets, credentials, customer data or personal details.
