#!/usr/bin/env bash
# Uninstall image-generation skill — reverses what install.sh did
# Cross-OS: macOS (BSD) and Linux (GNU)
set -euo pipefail

# --- Configuration from wrapper ---
SKILLS_DIR="${SKILLS_DIR:-~/.claude/skills}"
SETTINGS_DIR="${SETTINGS_DIR:-~/.claude}"
SKILL_SLUG="${SKILL_SLUG:-image-generation}"

# Expand tilde (cross-OS)
SKILLS_DIR="$(echo "$SKILLS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_DIR="$(echo "$SETTINGS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
HOOKS_DIR="${SETTINGS_DIR}/hooks"
HOOK_FILE="${HOOKS_DIR}/${SKILL_SLUG}-skill-hook.sh"
SKILL_DIR="${SKILLS_DIR}/${SKILL_SLUG}"

echo "Uninstalling ${SKILL_SLUG} skill..."

# --- Helper: revert settings.json changes ---
revert_settings() {
    local settings_file="$1"
    local hook_file="$2"

    if [ ! -f "$settings_file" ]; then
        echo "  No settings.json found, nothing to revert"
        return 0
    fi

    if command -v python3 &>/dev/null; then
        python3 << PYEOF
import json
import sys

settings_file = "${settings_file}"
hook_file = "${hook_file}"
changed = False

try:
    with open(settings_file, "r") as f:
        settings = json.load(f)
except Exception as e:
    print(f"Warning: Could not read settings.json: {e}", file=sys.stderr)
    sys.exit(0)

# Remove hook registration
hooks_list = settings.get("hooks", {}).get("UserPromptSubmit", [])
new_hooks_list = []
for entry in hooks_list:
    if isinstance(entry, dict) and "hooks" in entry:
        filtered = [h for h in entry["hooks"] if h.get("command") != hook_file]
        if filtered:
            entry["hooks"] = filtered
            new_hooks_list.append(entry)
        else:
            changed = True
            print("  Removed UserPromptSubmit hook entry")
    else:
        new_hooks_list.append(entry)

if "hooks" in settings and "UserPromptSubmit" in settings["hooks"]:
    if new_hooks_list:
        settings["hooks"]["UserPromptSubmit"] = new_hooks_list
    else:
        del settings["hooks"]["UserPromptSubmit"]
        if not settings["hooks"]:
            del settings["hooks"]
    changed = True

if changed:
    with open(settings_file, "w") as f:
        json.dump(settings, f, indent=2)
    print("  settings.json updated")
else:
    print("  No settings changes needed")
PYEOF
    elif command -v jq &>/dev/null; then
        if jq -e --arg hf "$hook_file" '.hooks.UserPromptSubmit[]? | select(.hooks[]? | .command == $hf)' "$settings_file" >/dev/null 2>&1; then
            jq --arg hf "$hook_file" '
                .hooks.UserPromptSubmit |= [
                    .[] | .hooks |= [.[] | select(.command != $hf)] | select(.hooks | length > 0)
                ] |
                if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end |
                if (.hooks | length) == 0 then del(.hooks) else . end
            ' "$settings_file" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
            echo "  Removed UserPromptSubmit hook"
        else
            echo "  Hook was not registered"
        fi
    else
        echo "  Warning: Neither python3 nor jq available — cannot revert settings.json"
        echo "  Manually remove the hook entry from hooks.UserPromptSubmit"
        return 1
    fi
}

# --- Revert settings.json ---
revert_settings "$SETTINGS_FILE" "$HOOK_FILE"

# --- Remove hook file ---
if [ -f "$HOOK_FILE" ]; then
    rm -f "$HOOK_FILE"
    echo "  Removed hook: ${HOOK_FILE}"
else
    echo "  Hook file not found (already removed)"
fi

# --- Remove skill directory ---
if [ -d "$SKILL_DIR" ]; then
    rm -rf "$SKILL_DIR"
    echo "  Removed skill directory: ${SKILL_DIR}"
else
    echo "  Skill directory not found (already removed)"
fi

echo ""
echo "${SKILL_SLUG} skill uninstalled successfully!"
echo "  Hook removed"
echo "  Skill files cleaned up"
