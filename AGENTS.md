# AGENTS.md

micro self-executable SAPI for PHP (a fork of dixyes/phpmicro): a PHP SAPI that builds `micro.sfx`, a PHP binary to which a PHP script or PHAR is concatenated to make a single self-executable file (PHP 8+, Windows, Linux, macOS). The C sources (`php_micro*.c/h`), `config.m4` / `config.w32` and `Makefile.frag*` are dropped into PHP's `sapi/micro`; `patches/` holds patches for the PHP source tree; `tests/` holds the sanity tests run by `make micro_test`; `docs/` is the VitePress documentation site; `.github/workflows/` builds the SFX and runs tests in CI. The `sibling-phar` branch adds a sibling-payload mode (the PHP payload sits next to the executable, including in macOS `../Resources` bundles) so the executable itself can be code-signed, plus Windows/Authenticode and CI changes for bundling in a desktop app. `build-sfx.yml` builds macOS and Windows fully static and Linux against glibc (dynamic, 2.35 floor; see the comments on its `build-linux` job and `.github/scripts/check-linux-sfx.sh`); every run publishes to the rolling `sfx-latest` release and to an immutable `sfx-<YYYYMMDD>.<run>` release that consumers pin by SHA-256. A manual run can build a subset (`platforms`), so fixing one platform does not rebuild, and change, the others.

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
