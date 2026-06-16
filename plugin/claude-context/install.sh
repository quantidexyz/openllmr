#!/usr/bin/env bash
# claude-context plugin install.
#
# Wires two things into Claude Code:
#   1. MCP server  → ~/.claude.json      (via `claude mcp add-json -s user`)
#   2. Hooks       → ~/.claude/settings.json
#
# The MCP entry MUST live in ~/.claude.json — Claude Code's MCP loader ignores
# settings.json. The hooks legitimately belong in settings.json.
set -euo pipefail

# --- Configuration from wrapper ---
SETTINGS_DIR="${SETTINGS_DIR:-$HOME/.claude}"
PLUGIN_DIR="${PLUGIN_DIR:-$SETTINGS_DIR/plugins/claude-context}"
PLUGIN_SRC_DIR="${PLUGIN_SRC_DIR:-}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-http://localhost:14041}"

if [ -z "${API_KEY:-}" ]; then
    echo "Error: API_KEY is not set. Pass via the wrapper install script." >&2
    exit 1
fi
if [ -z "$PLUGIN_SRC_DIR" ]; then
    echo "Error: PLUGIN_SRC_DIR is not set." >&2
    exit 1
fi

for bin in bun claude python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' is required but not found on PATH." >&2
        exit 1
    fi
done

SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
STATE_DIR="${SETTINGS_DIR}/plugin-state/claude-context"
mkdir -p "$SETTINGS_DIR" "$STATE_DIR"

# --- Create settings.json if missing (hooks live here) ---
if [ ! -f "$SETTINGS_FILE" ]; then
    cat > "$SETTINGS_FILE" << 'EOF'
{
  "env": {},
  "permissions": { "allow": [], "deny": [], "ask": [] }
}
EOF
    echo "  Created settings.json"
fi

# --- Register MCP server in ~/.claude.json ---
MCP_JSON=$(
  PLUGIN_SRC_DIR="$PLUGIN_SRC_DIR" \
  GATEWAY_ORIGIN="$GATEWAY_ORIGIN" \
  API_KEY="$API_KEY" \
  STATE_DIR="$STATE_DIR" \
  python3 -c '
import json, os
print(json.dumps({
    "command": "bun",
    "args": ["run", os.path.join(os.environ["PLUGIN_SRC_DIR"], "src", "index.ts")],
    "env": {
        "LLM_GATEWAY_URL": os.environ["GATEWAY_ORIGIN"],
        "LLM_GATEWAY_API_KEY": os.environ["API_KEY"],
        "CLAUDE_CONTEXT_STATE_DIR": os.environ["STATE_DIR"],
    },
}))
'
)

# Idempotent: remove (ignore failure — may not exist) then add.
claude mcp remove -s user claude-context >/dev/null 2>&1 || true
claude mcp add-json -s user claude-context "$MCP_JSON" >/dev/null
echo "  Registered MCP server via \`claude mcp add-json\` (user scope)"

# --- Register hooks in ~/.claude/settings.json ---
python3 - "$SETTINGS_FILE" "$PLUGIN_SRC_DIR" "$GATEWAY_ORIGIN" "$API_KEY" "$STATE_DIR" << 'PYEOF'
import json, os, sys

settings_file, plugin_src, gateway_url, api_key, state_dir = sys.argv[1:6]

try:
    with open(settings_file, "r") as f:
        settings = json.load(f)
except Exception:
    settings = {"env": {}, "permissions": {"allow": [], "deny": [], "ask": []}}

hook_env = {
    "LLM_GATEWAY_URL": gateway_url,
    "LLM_GATEWAY_API_KEY": api_key,
    "CLAUDE_CONTEXT_STATE_DIR": state_dir,
    "CLAUDE_PLUGIN_ROOT": plugin_src,
}
session_start_cmd = os.path.join(plugin_src, "hooks", "session-start.sh")
prompt_submit_cmd = os.path.join(plugin_src, "hooks", "prompt-search.sh")
prompt_docs_cmd = os.path.join(plugin_src, "hooks", "prompt-docs-detect.sh")
grep_nudge_cmd = os.path.join(plugin_src, "hooks", "grep-nudge.sh")

settings.setdefault("hooks", {})

def _replace_or_append(group_key, marker_substr, hook_obj, matcher=None):
    group = settings["hooks"].setdefault(group_key, [])
    for entry in group:
        for h in entry.get("hooks", []):
            if marker_substr in (h.get("command") or ""):
                h.update(hook_obj)
                if matcher is not None:
                    entry["matcher"] = matcher
                return
    block = {"hooks": [hook_obj]}
    if matcher is not None:
        block["matcher"] = matcher
    group.append(block)

env_prefix = " ".join(f"{k}={json.dumps(v)}" for k, v in hook_env.items())
_replace_or_append(
    "SessionStart", "claude-context/hooks/session-start.sh",
    {"type": "command", "command": f"env {env_prefix} {session_start_cmd}", "timeout": 30},
)
_replace_or_append(
    "UserPromptSubmit", "claude-context/hooks/prompt-search.sh",
    {"type": "command", "command": f"env {env_prefix} {prompt_submit_cmd}", "timeout": 5},
)
_replace_or_append(
    "UserPromptSubmit", "claude-context/hooks/prompt-docs-detect.sh",
    {"type": "command", "command": f"env {env_prefix} {prompt_docs_cmd}", "timeout": 3},
)
_replace_or_append(
    "PreToolUse", "claude-context/hooks/grep-nudge.sh",
    {"type": "command", "command": f"env {env_prefix} {grep_nudge_cmd}", "timeout": 3},
    matcher="Grep|Glob|Bash",
)

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
print("  Registered SessionStart + UserPromptSubmit hooks in settings.json")
PYEOF

# --- Ensure hook scripts are executable ---
for hook in \
    "${PLUGIN_SRC_DIR}/hooks/session-start.sh" \
    "${PLUGIN_SRC_DIR}/hooks/prompt-search.sh" \
    "${PLUGIN_SRC_DIR}/hooks/prompt-docs-detect.sh" \
    "${PLUGIN_SRC_DIR}/hooks/grep-nudge.sh"; do
    [ -f "$hook" ] && chmod +x "$hook"
done

# --- Hydrate plugin node_modules (one-time) ---
if [ -f "${PLUGIN_SRC_DIR}/package.json" ] && [ ! -d "${PLUGIN_SRC_DIR}/node_modules" ]; then
    echo "  Installing plugin dependencies via bun install..."
    (cd "$PLUGIN_SRC_DIR" && bun install --silent) || {
        echo "  Warning: bun install failed. Run manually: (cd $PLUGIN_SRC_DIR && bun install)" >&2
    }
fi

echo "Setup complete — restart Claude Code to load the claude-context MCP server."
