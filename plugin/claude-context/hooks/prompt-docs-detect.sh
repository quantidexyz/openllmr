#!/usr/bin/env bash
# claude-context UserPromptSubmit hook: docs URL auto-index.
#
# Reads the prompt JSON, scrapes any HTTP URLs that look like documentation,
# and fires-and-forgets `bun … index-docs --url <base>` so the framework's
# pages get crawled in the background. The plugin short-circuits on the
# gateway side if the URL is already indexed and clean, so it's safe to fire
# on every prompt that mentions the same URL.
#
# Hook MUST exit 0 silently on any error — failing here would block the user's
# prompt. We never write to stdout because that would inject context into the
# session.
set -u

[ "${CLAUDE_CONTEXT_DOCS_AUTO_INDEX:-1}" = "1" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then exit 0; fi
if ! command -v bun >/dev/null 2>&1; then exit 0; fi

EVENT=$(cat 2>/dev/null || true)
PROMPT=$(printf '%s' "$EVENT" | jq -r '.prompt // empty' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0
case "$PROMPT" in /*) exit 0 ;; esac

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
    PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

STATE_DIR="${CLAUDE_CONTEXT_STATE_DIR:-$HOME/.claude/plugin-state/claude-context}"
mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/auto-index-docs.log"

# Hostname token allowlist: hosts that look documentation-y.
docs_host() {
    local host="$1"
    case "$host" in
        docs.*|doc.*|developer.*|developers.*|dev.*) return 0 ;;
        api.*|learn.*|wiki.*|manual.*|reference.*) return 0 ;;
        help.*|support.*) return 0 ;;
        *.dev) return 0 ;;
    esac
    return 1
}

# Path-segment token allowlist: any URL whose path contains one of these as a
# segment is treated as documentation regardless of host.
docs_path() {
    local path="$1"
    case "$path" in
        */docs/*|*/docs|*/doc/*|*/doc) return 0 ;;
        */developers/*|*/developers|*/developer/*|*/developer) return 0 ;;
        */api/*|*/api) return 0 ;;
        */reference/*|*/reference) return 0 ;;
        */guide/*|*/guide|*/guides/*|*/guides) return 0 ;;
        */learn/*|*/learn) return 0 ;;
        */manual/*|*/manual|*/handbook/*|*/handbook) return 0 ;;
        */tutorial/*|*/tutorial|*/tutorials/*|*/tutorials) return 0 ;;
        */wiki/*|*/wiki) return 0 ;;
        */help/*|*/help) return 0 ;;
        */getting-started/*|*/getting-started) return 0 ;;
        */quickstart/*|*/quickstart) return 0 ;;
    esac
    return 1
}

# Hosts we never index — repos and file hosts.
blocked_host() {
    case "$1" in
        github.com|gitlab.com|bitbucket.org) return 0 ;;
        gist.github.com|pastebin.com|raw.githubusercontent.com) return 0 ;;
        localhost|127.0.0.1|0.0.0.0) return 0 ;;
    esac
    return 1
}

# Block the gateway's own URL so the hook can't loop on a self-mention.
if [ -n "${LLM_GATEWAY_URL:-}" ]; then
    GATEWAY_HOST=$(printf '%s' "$LLM_GATEWAY_URL" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
fi

# Extract URLs. grep -oE returns each match on its own line.
URLS=$(printf '%s' "$PROMPT" | grep -oE 'https?://[A-Za-z0-9.-]+(/[A-Za-z0-9._~%/-]*)?' | sort -u)
[ -n "$URLS" ] || exit 0

while IFS= read -r URL; do
    [ -n "$URL" ] || continue

    # Skip media / non-HTML extensions.
    case "$URL" in
        *.pdf|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.webp|*.ico) continue ;;
        *.mp4|*.mp3|*.wav|*.webm|*.mov) continue ;;
        *.zip|*.tar|*.gz|*.rar|*.7z) continue ;;
        *.css|*.js|*.mjs|*.map) continue ;;
        *.xml|*.rss|*.atom) continue ;;
    esac

    HOST=$(printf '%s' "$URL" | sed -E 's#^https?://([^/:]+).*#\1#' | tr 'A-Z' 'a-z')
    PATH_PART=$(printf '%s' "$URL" | sed -E 's#^https?://[^/]+##')

    [ -n "$HOST" ] || continue
    blocked_host "$HOST" && continue
    [ -n "${GATEWAY_HOST:-}" ] && [ "$HOST" = "$GATEWAY_HOST" ] && continue

    # Generous match — either docs-y host or docs-y path qualifies.
    if ! docs_host "$HOST" && ! docs_path "$PATH_PART"; then
        continue
    fi

    # Fire-and-forget. Stale-job heartbeats and short-circuits live on the
    # gateway side, so re-firing for the same URL on every prompt is cheap.
    nohup bun run "$PLUGIN_ROOT/src/index.ts" index-docs --url "$URL" \
        >>"$LOG" 2>&1 </dev/null &
    disown 2>/dev/null || true
done <<< "$URLS"

exit 0
