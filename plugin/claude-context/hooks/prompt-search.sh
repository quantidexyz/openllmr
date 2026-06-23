#!/usr/bin/env bash
# claude-context UserPromptSubmit hook.
#
# Reads JSON event from stdin, runs a time-bounded semantic search against the
# indexed codebase, and emits hookSpecificOutput.additionalContext so the
# top-K matching chunks are injected into the prompt context. Silent on
# timeout / not-indexed / error so user input is never blocked.
set -u

[ "${CLAUDE_CONTEXT_AUTO_SEARCH:-1}" = "1" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
    # jq is required to parse the event payload — fail silently.
    exit 0
fi

EVENT=$(cat)
PROMPT=$(printf '%s' "$EVENT" | jq -r '.prompt // empty')
CWD=$(printf '%s' "$EVENT" | jq -r '.cwd // empty')
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -n "$PROMPT" ] || exit 0
# Skip trivial prompts and slash commands.
[ "${#PROMPT}" -ge 12 ] || exit 0
case "$PROMPT" in /*) exit 0 ;; esac

ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0

# Must have an origin remote (same as the session-start hook) — the CLI would
# exit with code 2 in this case but failing fast here avoids spawning bun.
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

LIMIT="${CLAUDE_CONTEXT_AUTO_SEARCH_LIMIT:-3}"
TIMEOUT_MS="${CLAUDE_CONTEXT_AUTO_SEARCH_TIMEOUT_MS:-1500}"
TIMEOUT_S=$(awk "BEGIN{printf \"%.2f\", $TIMEOUT_MS/1000}")

# search exits 2 silently when not indexed → no-op for the hook.
RESULTS=$(timeout "$TIMEOUT_S" \
    bun run "$PLUGIN_ROOT/src/index.ts" search \
        --path "$ROOT" --query "$PROMPT" --limit "$LIMIT" 2>/dev/null) || exit 0
[ -n "$RESULTS" ] || exit 0

BLOCK=$(printf '%s' "$RESULTS" | jq -r '
  .results // []
  | map("\(.relativePath):\(.startLine)-\(.endLine) (score=\(.score))\n```\(.language)\n\(.content)\n```")
  | join("\n\n")
')
[ -n "$BLOCK" ] || exit 0

# Trailing directive teaches iteration. Without it the model treats the
# injected block as "the answer" and reverts to Grep for sub-questions.
FOOTER='If these snippets do not cover the question, call `mcp__claude-context__search_code` with a refined query before reaching for Grep.'
CTX=$(printf '<claude-context relevance="top-%s">\n%s\n\n%s\n</claude-context>' "$LIMIT" "$BLOCK" "$FOOTER")
jq -n --arg ctx "$CTX" '{
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $ctx
    }
}'
