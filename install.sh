#!/usr/bin/env bash
# Squirrel installer.
#
# Idempotent one-command setup:
#   1. Build all binaries via scripts/build-app.sh (cksum guard catches regressions)
#   2. Symlink the squirrel-mcp binary into ~/.local/bin (or /usr/local/bin)
#   3. Install Squirrel.app into /Applications (so Spotlight can launch it)
#   4. Register squirrel-mcp with Claude Code at user scope
#   5. Remove any stale Squirrel UserPromptSubmit hook from ~/.claude/settings.json
#   6. Install the /stash slash command at ~/.claude/commands/stash.md
#
# Re-runnable: every step checks-then-acts. Pre-existing config is preserved
# (settings.json is backed up; existing MCP registration is refreshed). Squirrel
# no longer uses a per-prompt hook — capture surfacing is now an ambient menu-bar
# badge in the app — so step 5 strips any hook left by older installs.
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

MCP_BIN="$ROOT/build/bin/squirrel-mcp"

[[ -x "$MCP_BIN" ]] || die "missing $MCP_BIN after build"

# ── 2. symlink ──────────────────────────────────────────────────────────────
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

echo "==> Symlinking squirrel-mcp into $SYMLINK_DIR"
mkdir -p "$SYMLINK_DIR"

if [[ ! -w "$SYMLINK_DIR" ]]; then
    die "$SYMLINK_DIR not writable. Re-run from a Terminal where sudo can prompt, or set SQUIRREL_INSTALL_DIR to a writable directory (e.g. SQUIRREL_INSTALL_DIR=\$HOME/.local/bin ./install.sh)."
fi

ln -sfn "$MCP_BIN" "$SYMLINK_DIR/squirrel-mcp"
ok "linked $SYMLINK_DIR/squirrel-mcp → $MCP_BIN"

# Drop any squirrel-hook symlink left by an older install — the hook is gone.
if [[ -L "$SYMLINK_DIR/squirrel-hook" ]]; then
    rm -f "$SYMLINK_DIR/squirrel-hook"
    ok "removed stale $SYMLINK_DIR/squirrel-hook symlink"
fi

# ── 3. install the app into /Applications ───────────────────────────────────
# The menu-bar app must live in /Applications (or ~/Applications) so Spotlight
# reliably surfaces it in the launcher and so TCC grants stay stable. An app
# left inside the source tree's build/ dir is deprioritized by Spotlight and
# stops launching whenever the source dir is moved or renamed.
echo
APP_NAME="Squirrel"
APP_SRC="$ROOT/build/${APP_NAME}.app"
[[ -d "$APP_SRC" ]] || die "missing $APP_SRC after build"

if [[ -w "/Applications" ]]; then
    APP_DEST_DIR="/Applications"
else
    APP_DEST_DIR="$HOME/Applications"
    mkdir -p "$APP_DEST_DIR"
fi
APP_DEST="$APP_DEST_DIR/${APP_NAME}.app"

echo "==> Installing ${APP_NAME}.app into $APP_DEST_DIR"
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"
# Register with LaunchServices so Spotlight indexes it immediately.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
ok "installed $APP_DEST (launchable from Spotlight)"

# ── 4. register MCP server with Claude Code ─────────────────────────────────
echo
echo "==> Registering squirrel-mcp with Claude Code (user scope)"

# `claude mcp add` fails on duplicate; remove-then-add is the safe idempotent path.
claude mcp remove -s user squirrel >/dev/null 2>&1 || true
if claude mcp add -s user squirrel "$SYMLINK_DIR/squirrel-mcp" >/dev/null; then
    ok "registered squirrel MCP server"
else
    die "claude mcp add failed — check 'claude mcp list' for diagnosis"
fi

# ── 5. remove any stale UserPromptSubmit hook ───────────────────────────────
# Squirrel dropped the per-prompt hook: capture surfacing is now an ambient
# menu-bar badge in the app, not a model-rendered block. Older installs left a
# `squirrel-hook session-check` entry in settings.json — strip it (and prune an
# emptied UserPromptSubmit array / hooks object) so it stops firing.
echo
echo "==> Removing any stale Squirrel UserPromptSubmit hook from ~/.claude/settings.json"

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo "{}" >"$SETTINGS"

if jq -e '
    (.hooks.UserPromptSubmit // []) | any(
        (.hooks // []) | any(
            (.command // "") | test("squirrel-hook session-check|squirrel session-check")
        )
    )
' "$SETTINGS" >/dev/null 2>&1; then
    # Backup before mutating (timestamped, kept indefinitely — small files).
    BACKUP="$SETTINGS.squirrel-backup.$(date +%Y%m%d_%H%M%S)"
    cp "$SETTINGS" "$BACKUP"
    ok "backed up settings.json to $BACKUP"

    TMP="$(mktemp)"
    jq '
        if .hooks.UserPromptSubmit then
            .hooks.UserPromptSubmit |= map(select(
                (.hooks // []) | all(
                    ((.command // "") | test("squirrel-hook session-check|squirrel session-check")) | not
                )
            ))
            | (if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end)
            | (if (.hooks | length) == 0 then del(.hooks) else . end)
        else . end
    ' "$SETTINGS" >"$TMP"

    if ! jq -e . "$TMP" >/dev/null 2>&1; then
        rm -f "$TMP"
        die "settings.json edit produced invalid JSON — original untouched, see backup"
    fi
    mv "$TMP" "$SETTINGS"
    ok "removed stale Squirrel hook from settings.json"
else
    ok "no Squirrel hook present — nothing to remove"
fi

# ── 6. slash commands ───────────────────────────────────────────────────────
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
echo "  1. Launch Squirrel from Spotlight (installed at $APP_DEST)"
echo "  2. Set hotkeys in Squirrel's preferences (⌘⇧Space voice, ⌘⇧I text by default)"
echo "  3. Open Claude Code in any project — squirrel-mcp will auto-initialize and"
echo "     auto-register the project (it shows up in Squirrel's project list)."
echo "     ${YELLOW}restart any existing Claude Code sessions to pick up the MCP server${RESET}"
echo "  4. From inside Claude Code, type /stash <an idea> to capture without leaving the conversation"
echo "  5. A dot on the menu-bar icon means you have untagged ideas — click it to triage,"
echo "     or run /scan-forest inside a project to route them there."
