# Squirrel

A journal for fleeting ideas. Hit a hotkey, talk for a few seconds, and Squirrel transcribes it with Whisper, summarizes it with Claude, and appends it to `~/forest.md`. Inside Claude Code, captures during the current session get an ambient nudge; older captures are pull-based via a `find_in_forest` MCP tool. When you decide an idea belongs to a project, "nest" it — it becomes a real `.md` file under `<repo>/.claude/nest/` that Claude Code auto-loads into every session for that project.

## Requirements

- macOS 14+
- Swift 6 + Xcode command-line tools (`xcode-select --install`)
- [Claude Code](https://claude.com/code) installed and on PATH
- `jq` (for the install script): `brew install jq`
- API keys: OpenAI (Whisper transcription) and Anthropic (Claude summarization)

## Install

```bash
./install.sh
```

That single command builds three binaries (`Squirrel.app`, `squirrel-hook`, `squirrel-mcp`), symlinks them into `/usr/local/bin`, registers the MCP server with Claude Code at user scope, writes the `UserPromptSubmit` hook into `~/.claude/settings.json` (with a backup of your existing file), and drops the `/stash` slash command into `~/.claude/commands/`. Idempotent — re-run any time to refresh.

After install:
1. Launch `build/Squirrel.app` (drag to `/Applications` if you want).
2. Click the menu bar icon → **Settings…** → paste your OpenAI and Anthropic API keys.
3. Set hotkey behavior (toggle vs push-to-talk). Push-to-talk needs Accessibility permission.
4. Restart any existing Claude Code sessions so they pick up the MCP server.

## Daily flow

### Capture (zero overhead, any time)

- `⌘⇧Space` — record voice idea anywhere on macOS
- `⌘⇧I` — type a text idea anywhere on macOS
- `/stash <text>` inside Claude Code — capture without leaving the conversation

All three land in the same `~/forest.md`, undirected. No project-tagging burden at capture time.

### Discovery (in a Claude Code session)

- **Captures during the current session** get an ambient one-line nudge on each prompt; Claude surfaces them conversationally and asks whether any belong to this project.
- **Older captures** are pull-based — ask Claude things like "did I stash anything about X?" and it'll search the forest via `find_in_forest`.

### Nesting (when an idea belongs here)

Say so in the conversation. Claude tags the global entry with `#project` and writes a `.claude/nest/{slug}.md` file. That file gets auto-loaded into every future Claude Code session for this project via a CLAUDE.md `@-import`, so the idea is part of permanent context — no retrieval needed.

Nest files have frontmatter (`status: open|deferred|resolved|archived`, optional `priority`) and a free-form `## Notes` section the model and you both grow over time.

## Architecture

Three binaries from one Swift package:

- **`Squirrel.app`** (menu bar) — hotkey capture pipeline: AVAudioRecorder → Whisper → Claude summarize → `ForestStore.append`. Also has a "Browse forest…" window.
- **`squirrel-mcp`** — MCP server registered with Claude Code. Exposes `stash_idea`, `nest_idea`, `archive_nest`, `session_captures`, `find_in_forest`, `refresh_nest_index`, plus a few query tools. On startup it auto-creates `.claude/nest/`, appends the CLAUDE.md snippet, regenerates `INDEX.md`, and stamps a session-start timestamp.
- **`squirrel-hook`** — `UserPromptSubmit` hook subprocess. Reads cwd's session-start timestamp, surfaces in-session captures plus an ambient count of older untagged entries. Read-only.

All three share `SquirrelCore`: `ForestStore`, `NestStore`, `ProjectRegistry`, `CaptureService`, `AnthropicService`, `WhisperService`, `Configuration`.

### Storage

- `~/forest.md` — global capture journal. Each entry has a metadata line like `` `<iso-ts>` · 4.2s · #project-slug ``. The `#tag` is the only structured field; multiple allowed (an idea can live in multiple project nests).
- `~/Library/Application Support/Squirrel/projects.json` — project registry, auto-managed by MCP startup.
- `~/Library/Application Support/Squirrel/secrets.json` (0600) — OpenAI + Anthropic keys. File-backed instead of Keychain because ad-hoc signing churn caused repeated auth prompts.
- `<repo>/.claude/nest/` — per-project nest files + `INDEX.md` (regenerated, grouped by priority) + `archive/`.
- `<repo>/.claude/squirrel-state.json` — `{ "session_start_ts": "<iso>" }`, written once per MCP startup, read by `squirrel-hook` and the `session_captures` tool.

## Permissions

- **Microphone** — prompted on first recording.
- **Accessibility** — only for push-to-talk hotkeys.

## Project layout

```
Package.swift
install.sh                       # one-command setup
scripts/build-app.sh             # swift build + bundle + ad-hoc sign
Resources/
├── Info.plist                   # LSUIElement, mic + apple events usage
└── commands/stash.md            # /stash slash command, copied to ~/.claude/commands/
Sources/
├── SquirrelCore/                # shared library: ForestStore, NestStore, ProjectRegistry, etc.
├── Squirrel/                    # menu bar app (target name; SwiftPM product "SquirrelMenuBar")
├── SquirrelHook/                # UserPromptSubmit hook subprocess (one subcommand: session-check)
└── SquirrelMCP/                 # MCP server: JSON-RPC over stdio
```

## Uninstall

```bash
claude mcp remove -s user squirrel
rm /usr/local/bin/squirrel-{hook,mcp}
rm ~/.claude/commands/stash.md
# Edit ~/.claude/settings.json to remove the UserPromptSubmit hook entry,
# or restore from the .squirrel-backup.<timestamp> file install.sh left.
```
