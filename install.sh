#!/bin/bash
# Install the nudge daemon + slash command for Claude Code + $-mention skill for Codex.
#
# Usage:
#   ./install.sh              # Install daemon + Claude plugin + Codex skill
#   ./install.sh --daemon     # Install daemon only
#   ./install.sh --uninstall  # Remove daemon, Claude plugin, and Codex skill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"
NUDGE_DIR="$HOME_DIR/.nudge"
SCRIPTS_DIR="$HOME_DIR/scripts"
PLIST_NAME="com.nudge.daemon.plist"
PLIST_SRC="$SCRIPT_DIR/scripts/$PLIST_NAME"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/$PLIST_NAME"
PLUGIN_DIR="$HOME_DIR/.claude/plugins/nudge"
AGENTS_SKILL_DIR="$HOME_DIR/.agents/skills/nudge"
AGENTS_SKILL_FILE="$AGENTS_SKILL_DIR/SKILL.md"
CODEX_SKILL_LINK="$HOME_DIR/.codex/skills/nudge"

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
    rm -f "$SCRIPTS_DIR/nudge-epic.sh"
    rm -f "$SCRIPTS_DIR/nudge-attention.sh"
    rm -f "$SCRIPTS_DIR/nudge-status.sh"
    rm -rf "$PLUGIN_DIR"
    info "Removed Claude Code plugin symlink"
    if [[ -L "$CODEX_SKILL_LINK" ]]; then
        rm -f "$CODEX_SKILL_LINK"
        info "Removed Codex skill symlink"
    fi
    if [[ -L "$AGENTS_SKILL_FILE" ]]; then
        rm -f "$AGENTS_SKILL_FILE"
        rmdir "$AGENTS_SKILL_DIR" 2>/dev/null || true
        info "Removed ~/.agents/skills/nudge symlink"
    fi
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
mkdir -p "$SCRIPTS_DIR" "$NUDGE_DIR/snapshots" "$NUDGE_DIR/runtime"

cp "$SCRIPT_DIR/scripts/nudge.sh" "$SCRIPTS_DIR/nudge.sh"
chmod +x "$SCRIPTS_DIR/nudge.sh"
info "Installed daemon script to $SCRIPTS_DIR/nudge.sh"

cp "$SCRIPT_DIR/scripts/nudge-epic.sh" "$SCRIPTS_DIR/nudge-epic.sh"
chmod +x "$SCRIPTS_DIR/nudge-epic.sh"
info "Installed epic helper to $SCRIPTS_DIR/nudge-epic.sh"

cp "$SCRIPT_DIR/scripts/nudge-attention.sh" "$SCRIPTS_DIR/nudge-attention.sh"
chmod +x "$SCRIPTS_DIR/nudge-attention.sh"
info "Installed attention helper to $SCRIPTS_DIR/nudge-attention.sh"

cp "$SCRIPT_DIR/scripts/nudge-status.sh" "$SCRIPTS_DIR/nudge-status.sh"
chmod +x "$SCRIPTS_DIR/nudge-status.sh"
info "Installed status helper to $SCRIPTS_DIR/nudge-status.sh"

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

# --- Install Claude Code plugin + Codex skill ---
if [[ "${1:-}" != "--daemon" ]]; then
    # Claude Code plugin (gives /nudge in Claude Code)
    mkdir -p "$HOME_DIR/.claude/plugins"
    if [[ -L "$PLUGIN_DIR" ]]; then
        rm "$PLUGIN_DIR"
    fi
    ln -s "$SCRIPT_DIR" "$PLUGIN_DIR"
    info "Installed Claude Code plugin (symlinked to $SCRIPT_DIR)"
    info "Use /nudge in Claude Code to manage sessions"

    # Codex skill (gives $nudge in Codex). The Codex TUI's skill popup ($ prefix)
    # loads SkillMetadata from ~/.codex/skills/*/SKILL.md — NOT from
    # ~/.codex/prompts/ (which is an unrelated RepoPrompt convention).
    # Convention on this machine: ~/.codex/skills/<name> -> ../../.agents/skills/<name>.
    # We mirror that so the skill is shared with any other agent that reads ~/.agents.
    #
    # IMPORTANT: Codex does NOT follow symlinked SKILL.md files — the skill
    # silently fails to load. So the SKILL.md itself must be a regular file
    # (cp), even though the ~/.codex/skills/<name> dir can be a symlink into
    # ~/.agents/skills/<name>. Re-run ./install.sh after editing
    # commands/nudge.md to refresh the copy.
    mkdir -p "$AGENTS_SKILL_DIR"
    if [[ -L "$AGENTS_SKILL_FILE" || -f "$AGENTS_SKILL_FILE" ]]; then
        rm -f "$AGENTS_SKILL_FILE"
    fi
    cp "$SCRIPT_DIR/commands/nudge.md" "$AGENTS_SKILL_FILE"
    info "Installed ~/.agents/skills/nudge/SKILL.md (copied from $SCRIPT_DIR/commands/nudge.md)"

    if [[ -d "$HOME_DIR/.codex/skills" ]]; then
        if [[ -L "$CODEX_SKILL_LINK" || -e "$CODEX_SKILL_LINK" ]]; then
            rm -rf "$CODEX_SKILL_LINK"
        fi
        ln -s "../../.agents/skills/nudge" "$CODEX_SKILL_LINK"
        info "Installed Codex skill at $CODEX_SKILL_LINK"
        info "Use \$nudge in Codex to reference the skill"
    else
        warn "~/.codex/skills not found — skipping Codex skill install"
    fi
fi

echo ""
info "Installation complete!"
echo ""
echo "  Quick start:"
echo "    /nudge add my-session \"Working on feature X\""
echo "    cp examples/nudge.json /path/to/repo/nudge.json"
echo "    ~/scripts/nudge-epic.sh bootstrap dojo /path/to/repo epic-id --start"
echo "    ~/scripts/nudge-status.sh"
echo "    /nudge status"
echo "    /nudge help"
echo ""
