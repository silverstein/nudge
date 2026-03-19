#!/bin/bash
# Install the nudge daemon and Claude Code plugin.
#
# Usage:
#   ./install.sh              # Install daemon + Claude Code plugin
#   ./install.sh --daemon     # Install daemon only
#   ./install.sh --uninstall  # Remove daemon and plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"
NUDGE_DIR="$HOME_DIR/.nudge"
SCRIPTS_DIR="$HOME_DIR/scripts"
PLIST_NAME="com.nudge.daemon.plist"
PLIST_SRC="$SCRIPT_DIR/scripts/$PLIST_NAME"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/$PLIST_NAME"
PLUGIN_DIR="$HOME_DIR/.claude/plugins/nudge"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[nudge]${NC} $1"; }
warn()  { echo -e "${YELLOW}[nudge]${NC} $1"; }
error() { echo -e "${RED}[nudge]${NC} $1" >&2; }

# --- Uninstall ---
if [[ "${1:-}" == "--uninstall" ]]; then
    info "Uninstalling nudge..."
    if [[ "$(uname)" == "Darwin" ]]; then
        launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
        rm -f "$PLIST_DST"
        info "Removed launchd daemon"
    fi
    rm -f "$SCRIPTS_DIR/nudge.sh"
    rm -rf "$PLUGIN_DIR"
    info "Removed plugin symlink"
    warn "Config at ~/.nudge/ preserved (remove manually if desired)"
    info "Done."
    exit 0
fi

# --- Check dependencies ---
for cmd in tmux jq; do
    if ! command -v "$cmd" &>/dev/null; then
        error "$cmd is required but not found."
        if [[ "$(uname)" == "Darwin" ]]; then
            echo "  Install: brew install $cmd"
        else
            echo "  Install: sudo apt install $cmd (Debian/Ubuntu)"
        fi
        exit 1
    fi
done

# --- Install daemon script ---
mkdir -p "$SCRIPTS_DIR" "$NUDGE_DIR/snapshots"

cp "$SCRIPT_DIR/scripts/nudge.sh" "$SCRIPTS_DIR/nudge.sh"
chmod +x "$SCRIPTS_DIR/nudge.sh"
info "Installed daemon script to $SCRIPTS_DIR/nudge.sh"

# --- Create default config if missing ---
if [[ ! -f "$NUDGE_DIR/sessions.json" ]]; then
    cat > "$NUDGE_DIR/sessions.json" << 'JSONEOF'
{
  "sessions": {},
  "config": {
    "nudgeMessage": "continue",
    "intervalSeconds": 180,
    "cooldownNudges": 20,
    "completionPhrases": [
      "all tasks complete",
      "all beads closed",
      "epic is empty",
      "nothing left to do",
      "no more tasks",
      "everything is done",
      "all items done",
      "finished all",
      "completed all",
      "no remaining work"
    ],
    "blockedPhrases": [
      "I am blocked",
      "I cannot proceed without your",
      "waiting for your input",
      "need your permission",
      "please provide",
      "I need you to"
    ]
  }
}
JSONEOF
    info "Created default config at $NUDGE_DIR/sessions.json"
else
    info "Config already exists at $NUDGE_DIR/sessions.json (preserved)"
fi

# --- Install launchd daemon (macOS only) ---
if [[ "$(uname)" == "Darwin" ]]; then
    mkdir -p "$HOME_DIR/Library/LaunchAgents"

    # Substitute __HOME__ placeholder
    sed "s|__HOME__|$HOME_DIR|g" "$PLIST_SRC" > "$PLIST_DST"

    # Load daemon
    launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    info "Loaded launchd daemon (runs every 3 minutes)"
else
    warn "Not macOS — skipping launchd setup."
    warn "Set up a cron job or systemd timer to run ~/scripts/nudge.sh every 3 minutes:"
    echo "  */3 * * * * $SCRIPTS_DIR/nudge.sh"
fi

# --- Install Claude Code plugin ---
if [[ "${1:-}" != "--daemon" ]]; then
    mkdir -p "$HOME_DIR/.claude/plugins"
    # Symlink to the repo so updates are automatic
    if [[ -L "$PLUGIN_DIR" ]]; then
        rm "$PLUGIN_DIR"
    fi
    ln -s "$SCRIPT_DIR" "$PLUGIN_DIR"
    info "Installed Claude Code plugin (symlinked to $SCRIPT_DIR)"
    info "Use /nudge in Claude Code to manage sessions"
fi

echo ""
info "Installation complete!"
echo ""
echo "  Quick start:"
echo "    /nudge add my-session \"Working on feature X\""
echo "    /nudge status"
echo "    /nudge help"
echo ""
