#!/usr/bin/env bash
# claude-context SessionStart hook.
#
# If the project is in a git repo, fire-and-forget an index/sync against the
# plugin CLI so the codebase is ready by the time the user submits a prompt.
# Honors $CLAUDE_PROJECT_DIR (set by Claude Code) and falls back to PWD.
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0

[ "${CLAUDE_CONTEXT_AUTO_INDEX:-1}" = "1" ] || exit 0

# Collection identity is the normalized 'origin' remote URL so that every user
# who checks out the same repo shares one index. Without a remote we can't
# build a stable identifier → skip indexing silently.
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    # Resolve from this script's location: hooks/ → plugin root.
    PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

STATE_DIR="${CLAUDE_CONTEXT_STATE_DIR:-$HOME/.claude/plugin-state/claude-context}"
mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/auto-index.log"

# Fire-and-forget. Detached so the hook returns immediately.
nohup bun run "$PLUGIN_ROOT/src/index.ts" index --path "$ROOT" \
    >>"$LOG" 2>&1 </dev/null &
disown 2>/dev/null || true

# additionalContext: a directive that biases tool selection for the rest of
# the session. Claude Code injects this before the first user turn, so it
# functions as a mini system-prompt augmentation. Keep it short — long blocks
# here compete for the same attention as actual user instructions.
cat <<EOF
This repository is indexed for semantic search (claude-context MCP).
Indexing/syncing $ROOT in background (log: $LOG).

Tool preference for this session:
- For conceptual questions ("where is X handled?", "how does Y work?", "what
  code implements Z?") call \`mcp__claude-context__search_code\` FIRST — it's
  faster and more accurate than guessing a Grep keyword.
- Iterate: refine the query and call again if the first pass is off.
- Use Grep/Glob ONLY for exact identifiers, regex, or filename patterns.
EOF
