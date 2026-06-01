#!/usr/bin/env bash
# Squirrel installer.
#
# Idempotent one-command setup:
#   1. Build all binaries via scripts/build-app.sh (cksum guard catches regressions)
#   2. Symlink CLI binaries into /usr/local/bin
#   3. Register squirrel-mcp with Claude Code at user scope
#   4. Install the UserPromptSubmit hook in ~/.claude/settings.json
#   5. Install the /stash slash command at ~/.claude/commands/stash.md
#
# Re-runnable: every step checks-then-acts. Pre-existing config is preserved
# (settings.json is backed up; existing MCP registration is refreshed; existing
# squirrel hook entries are replaced rather than duplicated).
#
# Run from the repo root:
#   ./install.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ── output helpers ──────────────────────────────────────────────────────────
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }
die()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }

# ── prerequisites ───────────────────────────────────────────────────────────
command -v swift >/dev/null   || die "swift not found — install Xcode command line tools (xcode-select --install)"
command -v claude >/dev/null  || die "claude CLI not found — install Claude Code from claude.com/code"
command -v jq >/dev/null      || die "jq not found — brew install jq"

# ── 1. build ────────────────────────────────────────────────────────────────
echo
echo "==> Building binaries"
./scripts/build-app.sh

CLI_BIN="$ROOT/build/bin/squirrel-hook"
MCP_BIN="$ROOT/build/bin/squirrel-mcp"

[[ -x "$CLI_BIN" ]] || die "missing $CLI_BIN after build"
[[ -x "$MCP_BIN" ]] || die "missing $MCP_BIN after build"

# ── 2. symlinks ─────────────────────────────────────────────────────────────
# Prefer ~/.local/bin (user-writable, no sudo). Fall back to /usr/local/bin only
# if the user explicitly asks (SQUIRREL_INSTALL_DIR=/usr/local/bin) or if
# ~/.local/bin isn't on PATH and /usr/local/bin is.
echo
if [[ -n "${SQUIRREL_INSTALL_DIR:-}" ]]; then
    SYMLINK_DIR="$SQUIRREL_INSTALL_DIR"
elif [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || [[ ! -d "/usr/local/bin" ]] || [[ ! -w "/usr/local/bin" ]]; then
    SYMLINK_DIR="$HOME/.local/bin"
else
    SYMLINK_DIR="/usr/local/bin"
fi

echo "==> Symlinking binaries into $SYMLINK_DIR"
mkdir -p "$SYMLINK_DIR"

if [[ ! -w "$SYMLINK_DIR" ]]; then
    die "$SYMLINK_DIR not writable. Re-run from a Terminal where sudo can prompt, or set SQUIRREL_INSTALL_DIR to a writable directory (e.g. SQUIRREL_INSTALL_DIR=\$HOME/.local/bin ./install.sh)."
fi

ln -sfn "$CLI_BIN" "$SYMLINK_DIR/squirrel-hook"
ok "linked $SYMLINK_DIR/squirrel-hook → $CLI_BIN"
ln -sfn "$MCP_BIN" "$SYMLINK_DIR/squirrel-mcp"
ok "linked $SYMLINK_DIR/squirrel-mcp → $MCP_BIN"

# If we used ~/.local/bin and it isn't on PATH, warn loudly — the hook command
# will be the absolute symlink path, so it still works, but users running the
# binaries by name won't find them.
if [[ "$SYMLINK_DIR" == "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    warn "~/.local/bin is not on your PATH. The hook itself is fine (uses absolute path),"
    warn "but you'll want this in your shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── 3. register MCP server with Claude Code ─────────────────────────────────
echo
echo "==> Registering squirrel-mcp with Claude Code (user scope)"

# `claude mcp add` fails on duplicate; remove-then-add is the safe idempotent path.
claude mcp remove -s user squirrel >/dev/null 2>&1 || true
if claude mcp add -s user squirrel "$SYMLINK_DIR/squirrel-mcp" >/dev/null; then
    ok "registered squirrel MCP server"
else
    die "claude mcp add failed — check 'claude mcp list' for diagnosis"
fi

# ── 4. UserPromptSubmit hook ────────────────────────────────────────────────
echo
echo "==> Installing UserPromptSubmit hook in ~/.claude/settings.json"

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo "{}" >"$SETTINGS"

# Backup before mutating (timestamped, kept indefinitely — small files).
BACKUP="$SETTINGS.squirrel-backup.$(date +%Y%m%d_%H%M%S)"
cp "$SETTINGS" "$BACKUP"
ok "backed up settings.json to $BACKUP"

HOOK_CMD="$SYMLINK_DIR/squirrel-hook session-check"

# Use jq to (a) ensure .hooks.UserPromptSubmit exists, (b) strip any prior
# squirrel-* hook entry, (c) append the new one. All in one atomic write via
# temp file + mv.
TMP="$(mktemp)"
jq --arg cmd "$HOOK_CMD" '
    .hooks //= {}
    | .hooks.UserPromptSubmit //= []
    | .hooks.UserPromptSubmit |= (
        map(select(
            (.hooks // []) | all(
                ((.command // "") | test("squirrel-hook session-check|squirrel session-check")) | not
            )
        ))
        + [{ "matcher": "", "hooks": [{ "type": "command", "command": $cmd }] }]
      )
' "$SETTINGS" >"$TMP"

# Sanity-check the result before swapping in.
if ! jq -e '.hooks.UserPromptSubmit | length > 0' "$TMP" >/dev/null; then
    rm -f "$TMP"
    die "hook JSON manipulation produced invalid output — settings.json untouched, see backup"
fi

mv "$TMP" "$SETTINGS"
ok "installed UserPromptSubmit hook → $HOOK_CMD"

# ── 5. slash commands ───────────────────────────────────────────────────────
echo
echo "==> Installing slash commands"

COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$COMMANDS_DIR"
SRC_DIR="$ROOT/Resources/commands"

[[ -d "$SRC_DIR" ]] || die "missing $SRC_DIR — repo is incomplete"

shopt -s nullglob
for src in "$SRC_DIR"/*.md; do
    name="$(basename "$src" .md)"
    cp "$src" "$COMMANDS_DIR/$(basename "$src")"
    ok "installed /$name → $COMMANDS_DIR/$(basename "$src")"
done
shopt -u nullglob

# ── done ────────────────────────────────────────────────────────────────────
echo
echo "${GREEN}Done.${RESET} Next steps:"
echo "  1. Launch ${ROOT}/build/Squirrel.app (drag to /Applications if you want)"
echo "  2. Set hotkeys in Squirrel's preferences (⌘⇧Space voice, ⌘⇧I text by default)"
echo "  3. Open Claude Code in any project — squirrel-mcp will auto-initialize"
echo "     ${YELLOW}restart any existing Claude Code sessions to pick up the MCP server${RESET}"
echo "  4. From inside Claude Code, type /stash <an idea> to capture without leaving the conversation"
