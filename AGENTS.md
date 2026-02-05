# Agent Notes (Ticker)

This file captures repository-specific workflow, conventions, and environment pitfalls discovered during active work.
It is intended for coding agents (Codex/Claude/GPT) so future sessions don’t have to rediscover these constraints.

## Follow CLAUDE.md

`CLAUDE.md` is the authoritative collaboration/workflow guide for this repo. In particular:
- Work in small, verifiable slices.
- Get GPT-5.2 review after each slice before moving on.
- Do not expand scope without asking.

## Proxy integration (alpha)

- The canonical backlog + acceptance criteria live in `docs/GITHUB_BACKLOG_ALPHA.md` (Epic C for proxy, Epic D + D8 for Ticker integration, and C12 for vision).
- Device/serial keys must be stored in **Keychain (Swift)** and must never be written to localStorage or logs.
- Ticker is moving from user-supplied provider API keys to proxy-based AI calls; treat existing “API Keys” settings UI as legacy until D is complete.
- Vision (D8): keep it lightweight — send images as **base64 message parts** (do not rely on URL images or add upload endpoints unless explicitly scoped).

## Repo Orientation (high-level)

- Swift app lives in `Sources/Ticker/` (WKWebView host + services).
- Web UI lives in `Web/` (Vite + React + TipTap).
- Local build outputs (by convention):
  - Dev/prod derived data: `./.build/xcode`
  - Release derived data: `./.build/xcode-release`
  - Release artifacts: `./.build/releases/v<version>/`

## Shell / Sandbox Pitfall: Login zsh runs Homebrew/RVM

In some environments, running commands through a **login zsh** sources user dotfiles that invoke Homebrew/RVM.
Those scripts may try to create temp files or call `ps`, which can fail under sandboxing with errors like:
- `brew.sh: cannot create temp file ... Operation not permitted`
- `.../ps: Operation not permitted`

**Agent guidance:**
- Prefer running tool shell commands with **non-login** semantics (e.g., `login=false` when supported by the harness).
- Avoid relying on Homebrew/RVM in automated tool execution.

**Human fix (optional):**
- Guard `brew shellenv` / `rvm` init behind an interactive-shell check in `~/.zshrc` / `~/.zprofile`, e.g.:
  - `[[ -o interactive ]] || return`

## Tooling + Distribution Notes (Sparkle / Releases)

- `./tickerctl.sh` is the “single entry point” for common dev/prod/release tasks.
- If you see errors like “There is no XCFramework found … Sparkle.xcframework”, it’s usually stale SwiftPM artifacts:
  - Run `./tickerctl.sh clean-derived-data -y` and rebuild.
- Sparkle CLI tools for signing updates are installed into the repo (gitignored) for repeatability:
  - Run `./tickerctl.sh install-sparkle-tools`
  - Tools live at `tools/sparkle/Sparkle/bin/` (e.g. `sign_update`, `generate_appcast`).
- `release-alpha` will install Sparkle tools automatically if missing, and by default builds into `./.build/xcode-release`.
- GitHub Pages/appcast work is typically done via a separate `gh-pages` worktree (recommended), not by checking out `gh-pages` in the main repo.

## Bash Strict Mode Footguns

Scripts use `set -euo pipefail`. In bash with `set -u`, expanding empty arrays can error:
- Prefer `if (( ${#arr[@]} > 0 )); then …` rather than `[[ -n "${arr[*]}" ]]`.
- Avoid expanding `"${arr[@]}"` if the array may be unset/empty; build a command array and append conditionally.

## Unified Editor Invariants (do not break)

- Cell identity is UUID-based: `cellBlock.attrs.id` must be a UUID that matches persistence expectations.
- Schema is `doc -> cellBlock+` and `cellBlock -> block+` (rich block content).
- Paste must rewrite pasted `cellBlock` UUIDs to avoid persistence collisions.
- Avoid parsing arbitrary HTML as a full `doc` under `cellBlock+`; parse inside a dummy `cellBlock` and insert its content.
- Drag reorder persists via `reorderBlocks` bridge message; suppress content-save storms during reorder.

## UX Polish (Completed)

UX polish slices (toast hardening, drag reorder, overlay focus, thinking window, side panel focus) were completed in this phase. Cell-level error overlay/state-machine work remains explicitly deferred unless re-approved.

## Collaboration Notes (Claude + GPT)

- Keep changes small and verifiable; describe assumptions vs facts; avoid scope creep.
- When handing off, include: what changed, why, how to verify, and any known risks/edge cases.
