#!/usr/bin/env bash
# pick-model skill install — runs inline during installation.
# Mirrors image-generation/install.sh conventions.
#
# What it does:
#   1. Copies sync.sh → $SETTINGS_DIR/hooks/pick-model-sync.sh.
#   2. Rewrites __GATEWAY_URL__ / __API_KEY__ placeholders in that copy.
#   3. Registers a SessionStart hook in $SETTINGS_DIR/settings.json that runs
#      the hook script.
#   4. Runs it once immediately so /m-* commands are available in the session
#      that just installed the skill.
set -euo pipefail

# --- Configuration from wrapper ---
SKILLS_DIR="${SKILLS_DIR:-~/.claude/skills}"
SETTINGS_DIR="${SETTINGS_DIR:-~/.claude}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-http://localhost:14041}"
SKILL_DIR="${SKILL_DIR:-${SKILLS_DIR}/pick-model}"

# Expand tilde (cross-OS)
SKILLS_DIR="$(echo "$SKILLS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_DIR="$(echo "$SETTINGS_DIR" | sed "s|^~|$HOME|g")"
SKILL_DIR="$(echo "$SKILL_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
HOOKS_DIR="${SETTINGS_DIR}/hooks"
HOOK_FILE="${HOOKS_DIR}/pick-model-sync.sh"
COMMANDS_DIR="${SETTINGS_DIR}/commands"

# --- Validate API key ---
if [ -z "${API_KEY:-}" ]; then
    echo "Error: API_KEY is not set. This should be passed from the wrapper install script." >&2
    exit 1
fi

echo "Configuring Claude Code settings for pick-model skill..."

# --- Helper: sed in-place (cross-OS) ---
sed_inplace() {
    local pattern="$1"
    local replacement="$2"
    local file="$3"
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "s|${pattern}|${replacement}|g" "$file"
    else
        sed -i '' "s|${pattern}|${replacement}|g" "$file"
    fi
}

# --- Register the SessionStart hook ---
configure_settings() {
    local settings_file="$1"
    local hook_file="$2"

    if command -v python3 &>/dev/null; then
        python3 << PYEOF
import json
import sys

settings_file = "${settings_file}"
try:
    with open(settings_file, "r") as f:
        settings = json.load(f)
except Exception as e:
    print(f"Warning: Could not read settings.json: {e}", file=sys.stderr)
    settings = {"env": {}, "permissions": {"allow": [], "deny": [], "ask": []}}

if "hooks" not in settings:
    settings["hooks"] = {}
if "SessionStart" not in settings["hooks"]:
    settings["hooks"]["SessionStart"] = []

hook_file = "${hook_file}"
hook_cmd = {"type": "command", "command": f"bash {hook_file}", "timeout": 15}

registered = False
for entry in settings["hooks"]["SessionStart"]:
    if isinstance(entry, dict) and "hooks" in entry:
        for h in entry["hooks"]:
            cmd = h.get("command", "")
            if hook_file in cmd:
                registered = True
                break
        if not registered:
            entry["hooks"].append(hook_cmd)
            registered = True
            print("  Registered SessionStart hook")
        break

if not registered:
    settings["hooks"]["SessionStart"].append({"hooks": [hook_cmd]})
    print("  Registered SessionStart hook")

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)

print("  settings.json updated")
PYEOF
    else
        echo "  Warning: python3 not available — cannot edit settings.json automatically." >&2
        echo "  Add this hook manually to ${settings_file}:" >&2
        echo "    hooks.SessionStart[].hooks[] = { type: command, command: bash ${hook_file}, timeout: 15 }" >&2
        return 1
    fi
}

# --- Main installation ---

mkdir -p "${SETTINGS_DIR}" "${HOOKS_DIR}" "${COMMANDS_DIR}"

if [ ! -f "$SETTINGS_FILE" ]; then
    cat > "$SETTINGS_FILE" << 'EOF'
{
  "env": {},
  "permissions": {
    "allow": [],
    "deny": [],
    "ask": []
  }
}
EOF
    echo "  Created settings.json"
fi

# Copy sync.sh to the hooks dir with injected config.
SYNC_SOURCE="${SKILL_DIR}/sync.sh"
if [ ! -f "$SYNC_SOURCE" ]; then
    echo "Error: sync.sh not found at ${SYNC_SOURCE}" >&2
    exit 1
fi

cp "$SYNC_SOURCE" "$HOOK_FILE"
chmod +x "$HOOK_FILE"
sed_inplace "__GATEWAY_URL__" "${GATEWAY_ORIGIN}" "$HOOK_FILE"
sed_inplace "__API_KEY__" "${API_KEY}" "$HOOK_FILE"
sed_inplace "__SKILL_CONFIGURED__" "yes" "$HOOK_FILE"
echo "  Hook installed: ${HOOK_FILE}"

# Register the hook in settings.json.
configure_settings "$SETTINGS_FILE" "$HOOK_FILE"

# Prime the pump — materialize /m-* commands right now so the current session
# sees them without needing a restart.
echo "  Running initial sync..."
if bash "$HOOK_FILE"; then
    :
else
    echo "  Warning: initial sync failed; hook will retry on next SessionStart." >&2
fi

echo "Setup complete!"
echo ""
echo "  Type /m- in Claude Code to fuzzy-pick a gateway model."
echo "  Selecting an entry prints the '/model <id>' line to paste, and pins"
echo "  that model as the default in ~/.claude/settings.json."
