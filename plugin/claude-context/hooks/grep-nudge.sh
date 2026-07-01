#!/usr/bin/env bash
# claude-context PreToolUse hook.
#
# Fires on Grep / Glob / Bash(grep|rg). Emits a one-time-per-session
# additionalContext nudge telling the model to prefer search_code for
# conceptual queries. Nudges, never blocks — the user's grep still runs.
#
# Throttling: one nudge per session, keyed by session_id in a marker file
# under $CLAUDE_CONTEXT_STATE_DIR. Claude learns after one reminder;
# repeating on every grep call just burns tokens and annoys the model.
set -u

[ "${CLAUDE_CONTEXT_GREP_NUDGE:-1}" = "1" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

EVENT=$(cat)
TOOL=$(printf '%s' "$EVENT" | jq -r '.tool_name // empty')
SESSION=$(printf '%s' "$EVENT" | jq -r '.session_id // empty')
CWD=$(printf '%s' "$EVENT" | jq -r '.cwd // empty')
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

# Only nudge on search-shaped tools.
case "$TOOL" in
    Grep|Glob) ;;
    Bash)
        CMD=$(printf '%s' "$EVENT" | jq -r '.tool_input.command // empty')
        # Match `grep`, `rg`, `ag`, `ack` at the start or after a pipe/&&/;.
        if ! printf '%s' "$CMD" | grep -qE '(^|[|&;[:space:]])(grep|rg|ag|ack)([[:space:]]|$)'; then
            exit 0
        fi
        ;;
    *) exit 0 ;;
esac

# Only nudge inside indexed-capable repos (has origin remote). Avoids noise
# in non-repo directories where search_code would error anyway.
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || exit 0

STATE_DIR="${CLAUDE_CONTEXT_STATE_DIR:-$HOME/.claude/plugin-state/claude-context}"
mkdir -p "$STATE_DIR"
# Stable-ish session key: prefer the explicit session_id, fall back to PPID so
# we still throttle within a single `claude` process when session_id is empty.
KEY="${SESSION:-ppid-$PPID}"
# Sanitize (session ids are usually safe, but guard anyway).
KEY=$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '_')
MARKER="$STATE_DIR/grep-nudge.${KEY}"
[ ! -e "$MARKER" ] || exit 0
: > "$MARKER"

MSG="claude-context: this repo is indexed. Prefer \`mcp__claude-context__search_code\` over $TOOL for conceptual queries (\"where is X\", \"how does Y work\"). Grep is still the right call for exact identifiers, regex, or filename globs — this nudge fires once per session."

jq -n --arg ctx "$MSG" '{
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $ctx
    }
}'
