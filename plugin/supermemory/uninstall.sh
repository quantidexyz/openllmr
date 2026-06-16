#!/usr/bin/env bash
# supermemory plugin uninstall.
#   1. MCP server   → removed from ~/.claude.json via `claude mcp remove`
#   2. Hook         → stripped from ~/.claude/settings.json
#   3. Plugin dir   → deleted
set -euo pipefail

SETTINGS_DIR="${SETTINGS_DIR:-$HOME/.claude}"
PLUGIN_DIR="${PLUGIN_DIR:-$SETTINGS_DIR/plugins/supermemory}"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

for bin in claude python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' is required but not found on PATH." >&2
        exit 1
    fi
done

# --- Remove MCP server registration ---
if claude mcp remove -s user supermemory >/dev/null 2>&1; then
    echo "  Removed MCP server via \`claude mcp remove\`"
else
    echo "  MCP server not registered (nothing to remove)"
fi

# --- Strip hook from settings.json ---
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

_strip("UserPromptSubmit", "supermemory/hooks/recall-on-prompt.sh")
# Legacy UserPromptSubmit-based extractor (replaced by the Stop hook below).
_strip("UserPromptSubmit", "supermemory/hooks/extract-on-prompt.sh")
_strip("Stop", "supermemory/hooks/extract-on-stop.sh")
_strip("SessionStart", "supermemory/hooks/session-start.sh")

# Also strip legacy `_tag: "supermemory"` entries from previous install.sh versions
ups = settings.get("hooks", {}).get("UserPromptSubmit")
if isinstance(ups, list):
    before = len(ups)
    ups[:] = [h for h in ups if not (isinstance(h, dict) and h.get("_tag") == "supermemory")]
    if len(ups) != before:
        removed_hooks.append("UserPromptSubmit (legacy _tag)")

# Also strip a legacy mcpServers.supermemory entry from settings.json if a
# previous install.sh wrote it there (it was always inert, so just clean up).
mcp = settings.get("mcpServers")
if isinstance(mcp, dict) and "supermemory" in mcp:
    del mcp["supermemory"]
    print("  Cleaned legacy mcpServers.supermemory from settings.json")

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
if removed_hooks:
    print(f"  Removed supermemory hooks from: {', '.join(sorted(set(removed_hooks)))}")
PYEOF
fi

if [ -d "$PLUGIN_DIR" ]; then
    rm -rf "$PLUGIN_DIR"
    echo "  Removed $PLUGIN_DIR"
fi

echo "supermemory plugin uninstalled."
echo "Note: saved memories in the gateway DB are NOT deleted. Use the 'memory' tool to forget them one-by-one, or drop the 'memories' collection via admin tooling."
