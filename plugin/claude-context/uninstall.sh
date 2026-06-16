#!/usr/bin/env bash
# claude-context plugin uninstall.
#   1. MCP server   → removed from ~/.claude.json via `claude mcp remove`
#   2. Hooks        → stripped from ~/.claude/settings.json
#   3. Plugin dir   → deleted
set -euo pipefail

SETTINGS_DIR="${SETTINGS_DIR:-$HOME/.claude}"
PLUGIN_DIR="${PLUGIN_DIR:-$SETTINGS_DIR/plugins/claude-context}"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

for bin in claude python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' is required but not found on PATH." >&2
        exit 1
    fi
done

# --- Remove MCP server registration ---
if claude mcp remove -s user claude-context >/dev/null 2>&1; then
    echo "  Removed MCP server via \`claude mcp remove\`"
else
    echo "  MCP server not registered (nothing to remove)"
fi

# --- Strip hooks from settings.json ---
if [ -f "$SETTINGS_FILE" ]; then
    python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
settings_file = sys.argv[1]
try:
    with open(settings_file) as f:
        settings = json.load(f)
except Exception:
    settings = {}

removed_hooks = []
def _strip(group_key, marker_substr):
    group = settings.get("hooks", {}).get(group_key)
    if not isinstance(group, list):
        return
    new_group = []
    for entry in group:
        kept_hooks = [h for h in entry.get("hooks", [])
                      if marker_substr not in (h.get("command") or "")]
        if kept_hooks:
            new_entry = dict(entry)
            new_entry["hooks"] = kept_hooks
            new_group.append(new_entry)
        elif entry.get("hooks"):
            removed_hooks.append(group_key)
    settings["hooks"][group_key] = new_group

_strip("SessionStart", "claude-context/hooks/session-start.sh")
_strip("UserPromptSubmit", "claude-context/hooks/prompt-search.sh")
_strip("UserPromptSubmit", "claude-context/hooks/prompt-docs-detect.sh")
_strip("PreToolUse", "claude-context/hooks/grep-nudge.sh")

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
if removed_hooks:
    print(f"  Removed claude-context hooks from: {', '.join(sorted(set(removed_hooks)))}")
PYEOF
fi

if [ -d "$PLUGIN_DIR" ]; then
    rm -rf "$PLUGIN_DIR"
    echo "  Removed $PLUGIN_DIR"
fi

echo "claude-context plugin uninstalled."
echo "Note: vector data in the gateway DB is NOT deleted. Use clear_index or admin tooling to purge."
