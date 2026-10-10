#!/bin/bash
# Install graphify (CLI + /graphify skill) in Claude Code cloud sessions,
# which start from a fresh container. Locally, run once yourself:
#   pip install graphifyy && graphify install
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

if ! command -v graphify >/dev/null 2>&1; then
  pip install -q graphifyy >/dev/null 2>&1 || { echo "graphify: pip install graphifyy failed" >&2; exit 0; }
fi

if [ ! -f "$HOME/.claude/skills/graphify/SKILL.md" ]; then
  graphify install >/dev/null 2>&1 || echo "graphify: graphify install failed" >&2
fi

exit 0
