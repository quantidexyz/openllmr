#!/usr/bin/env bash
# claude-context plugin — unified install / uninstall / state script.
#
#   (no flag)  install: wire MCP server (~/.claude.json) + hooks (settings.json)
#   -u         uninstall: remove the MCP server + strip hooks + delete plugin dir
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
#
# The MCP entry MUST live in ~/.claude.json — Claude Code's MCP loader ignores
# settings.json. The hooks legitimately belong in settings.json.
set -euo pipefail

# --- Configuration from wrapper (install needs API_KEY + PLUGIN_SRC_DIR; the
#     uninstall/state paths need neither, so they validate inside do_install). ---
SETTINGS_DIR="${SETTINGS_DIR:-$HOME/.claude}"
PLUGIN_DIR="${PLUGIN_DIR:-$SETTINGS_DIR/plugins/claude-context}"
PLUGIN_SRC_DIR="${PLUGIN_SRC_DIR:-}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-http://localhost:14041}"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

# Markers used by both uninstall (strip) and state (detect). Kept beside the
# install paths so the three stay in lockstep.
SESSION_HOOK_MARKER="claude-context/hooks/session-start.sh"

do_install() {
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

    local STATE_DIR="${SETTINGS_DIR}/plugin-state/claude-context"
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
    local MCP_JSON
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

# Fail closed: a fresh skeleton is only safe when there is NO existing file.
# If settings.json exists but does not parse (a hand-edit trailing comma, a
# half-written save, …) we must NOT overwrite it — that would wipe every key
# the user had. Leave it untouched and abort.
if os.path.exists(settings_file):
    try:
        with open(settings_file, "r") as f:
            settings = json.load(f)
    except Exception as e:
        print(f"Error: {settings_file} exists but is not valid JSON — refusing to overwrite ({e}).", file=sys.stderr)
        print("  Your settings were left untouched. Fix or remove the file, then re-run.", file=sys.stderr)
        sys.exit(1)
    if not isinstance(settings, dict):
        print(f"Error: {settings_file} is not a JSON object — refusing to overwrite.", file=sys.stderr)
        sys.exit(1)
else:
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
}

do_uninstall() {
    # --- Remove MCP server registration ---
    if command -v claude >/dev/null 2>&1; then
        if claude mcp remove -s user claude-context >/dev/null 2>&1; then
            echo "  Removed MCP server via \`claude mcp remove\`"
        else
            echo "  MCP server not registered (nothing to remove)"
        fi
    else
        echo "  claude CLI not found; skipping MCP server removal"
    fi

    # --- Strip hooks from settings.json ---
    if [ -f "$SETTINGS_FILE" ]; then
        if command -v python3 >/dev/null 2>&1; then
        python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
settings_file = sys.argv[1]
# Fail closed: if settings.json exists but does not parse (a hand-edit trailing
# comma, a half-written save), we cannot know what to strip — and must NOT
# overwrite it (that would wipe every key the user had). Leave it untouched and
# bail. Uninstall is best-effort, so a clean exit is correct here.
try:
    with open(settings_file) as f:
        settings = json.load(f)
except Exception as e:
    print(f"  Warning: {settings_file} is not valid JSON — leaving it untouched ({e}).", file=sys.stderr)
    print("  Remove the claude-context hook entries manually if needed.", file=sys.stderr)
    sys.exit(0)
if not isinstance(settings, dict):
    print(f"  Warning: {settings_file} is not a JSON object — leaving it untouched.", file=sys.stderr)
    sys.exit(0)

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
        else
            echo "  Warning: python3 not found — leaving settings.json hooks untouched." >&2
        fi
    fi

    if [ -d "$PLUGIN_DIR" ]; then
        local expected_plugin_dir="${SETTINGS_DIR}/plugins/claude-context"
        if [ "$PLUGIN_DIR" != "$expected_plugin_dir" ] || [ "$PLUGIN_DIR" = "/" ]; then
            echo "Error: refusing to remove unexpected PLUGIN_DIR '$PLUGIN_DIR' (expected '$expected_plugin_dir')." >&2
            exit 1
        fi
        rm -rf -- "$PLUGIN_DIR"
        echo "  Removed $PLUGIN_DIR"
    fi

    echo "claude-context plugin uninstalled."
    echo "Note: vector data in the gateway DB is NOT deleted. Use clear_index or admin tooling to purge."
}

# Print one JSON line describing install state. Installed ⇔ the SessionStart
# hook is wired into settings.json (the durable, config-side signal — the plugin
# dir may be deleted while the wiring remains, and vice-versa). Exit 0 always;
# the JSON IS the payload. No key, no network.
do_state() {
    local installed="false"
    if [ -f "$SETTINGS_FILE" ] && command -v python3 >/dev/null 2>&1; then
        if MARKER="$SESSION_HOOK_MARKER" python3 - "$SETTINGS_FILE" << 'PYEOF' 2>/dev/null
import json, os, sys
marker = os.environ["MARKER"]
try:
    with open(sys.argv[1]) as f:
        settings = json.load(f)
except Exception:
    sys.exit(1)
hooks = settings.get("hooks", {}) if isinstance(settings, dict) else {}
for group in hooks.values():
    if not isinstance(group, list):
        continue
    for entry in group:
        for h in entry.get("hooks", []):
            if marker in (h.get("command") or ""):
                sys.exit(0)
sys.exit(1)
PYEOF
        then
            installed="true"
        fi
    fi
    printf '{"installed":%s,"version":null}\n' "$installed"
}

MODE="install"
while getopts "us" opt; do
    case "$opt" in
        u) MODE="uninstall" ;;
        s) MODE="state" ;;
        *) echo "usage: install.sh [-u|-s]" >&2; exit 2 ;;
    esac
done

case "$MODE" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    state)     do_state ;;
esac
