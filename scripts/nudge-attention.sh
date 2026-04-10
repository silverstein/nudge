#!/bin/bash
# Thin wrapper so humans/agents can run one command without remembering subcommands.
set -euo pipefail
exec "$HOME/scripts/nudge-epic.sh" attention
