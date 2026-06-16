#!/usr/bin/env bash
# image-generation skill install script - runs inline during installation
# Cross-OS: macOS (BSD) and Linux (GNU)
set -euo pipefail

# --- Configuration from wrapper ---
SKILLS_DIR="${SKILLS_DIR:-~/.claude/skills}"
SETTINGS_DIR="${SETTINGS_DIR:-~/.claude}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-http://localhost:14041}"
SKILL_DIR="${SKILL_DIR:-${SKILLS_DIR}/image-generation}"

# Expand tilde (cross-OS)
SKILLS_DIR="$(echo "$SKILLS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_DIR="$(echo "$SETTINGS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

# --- Validate API key ---
if [ -z "${API_KEY:-}" ]; then
    echo "Error: API_KEY is not set. This should be passed from the wrapper install script."
    exit 1
fi

echo "Configuring Claude Code settings for image-generation skill..."

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

# --- Register the UserPromptSubmit hook (if hook.sh was downloaded) ---
# Claude Code has no built-in image-generation tool to disable, so this is
# purely additive: we register a hook that nudges the user toward the skill
# when an image-y prompt comes in.
configure_settings() {
    local settings_file="$1"
    local hooks_dir="$2"
    local hook_file="${hooks_dir}/image-generation-skill-hook.sh"

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
if "UserPromptSubmit" not in settings["hooks"]:
    settings["hooks"]["UserPromptSubmit"] = []

hook_file = "${hook_file}"
hook_cmd = {"type": "command", "command": hook_file, "timeout": 5}

registered = False
for entry in settings["hooks"]["UserPromptSubmit"]:
    if isinstance(entry, dict) and "hooks" in entry:
        for h in entry["hooks"]:
            if h.get("command") == hook_file:
                registered = True
                break
        if not registered:
            entry["hooks"].append(hook_cmd)
            registered = True
            print("  Registered UserPromptSubmit hook")
        break

if not registered:
    settings["hooks"]["UserPromptSubmit"].append({"hooks": [hook_cmd]})
    print("  Registered UserPromptSubmit hook")

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)

print("  settings.json updated")
PYEOF
    elif command -v jq &>/dev/null; then
        if [ ! -f "$settings_file" ]; then
            cat > "$settings_file" << 'EOF'
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

        if ! jq -e --arg hf "$hook_file" '.hooks.UserPromptSubmit[]? | select(.hooks[]? | .command == $hf)' "$settings_file" >/dev/null 2>&1; then
            jq --arg hf "$hook_file" '
                if .hooks == null then .hooks = {} else . end |
                if .hooks.UserPromptSubmit == null then .hooks.UserPromptSubmit = [] else . end |
                .hooks.UserPromptSubmit += [{"hooks": [{"type": "command", "command": $hf, "timeout": 5}]}]
            ' "$settings_file" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
            echo "  Registered UserPromptSubmit hook"
        else
            echo "  Hook already registered"
        fi
    else
        echo "  Warning: Neither python3 nor jq available."
        echo "  Manual configuration required. See: https://docs.anthropic.com/en/docs/claude-code/hooks"
        return 1
    fi
}

# --- Main installation ---

# Ensure settings directory exists
mkdir -p "${SETTINGS_DIR}"

# Create settings.json if it doesn't exist
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

# Register hook in settings.json (no permission changes needed).
configure_settings "$SETTINGS_FILE" "$SETTINGS_DIR/hooks"

# Install hook - the wrapper downloaded hook.sh to SKILL_DIR
HOOK_SOURCE="${SKILL_DIR}/hook.sh"
HOOKS_DIR="${SETTINGS_DIR}/hooks"

if [ -f "$HOOK_SOURCE" ]; then
    mkdir -p "${HOOKS_DIR}"
    cp "$HOOK_SOURCE" "${HOOKS_DIR}/image-generation-skill-hook.sh"
    chmod +x "${HOOKS_DIR}/image-generation-skill-hook.sh"
    echo "  Hook installed: ${HOOKS_DIR}/image-generation-skill-hook.sh"
else
    echo "  Warning: hook.sh not found in ${SKILL_DIR}, skipping hook installation"
fi

# Inject gateway URL and API key into run.sh (the runnable entry point).
# SKILL.md stays free of secrets so it's safe to view / share.
RUN_SH="${SKILLS_DIR}/image-generation/run.sh"
if [ -f "$RUN_SH" ]; then
    echo "  Injecting configuration into run.sh..."
    sed_inplace "__GATEWAY_URL__" "${GATEWAY_ORIGIN}" "$RUN_SH"
    sed_inplace "__API_KEY__" "${API_KEY}" "$RUN_SH"
    sed_inplace "__SKILL_CONFIGURED__" "yes" "$RUN_SH"
    chmod +x "$RUN_SH"
    echo "  run.sh configured and made executable"
else
    echo "  Warning: run.sh not found at ${RUN_SH} — skill will not run."
fi

echo "Setup complete!"
