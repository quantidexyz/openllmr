#!/usr/bin/env bash
# image-generation skill — unified install / uninstall / state script.
#
#   (no flag)  install: register UserPromptSubmit hook, install hook.sh,
#              inject config into run.sh.
#   -u         uninstall: strip the hook, remove hook file + skill dir.
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
# Cross-OS: macOS (BSD) and Linux (GNU)
set -euo pipefail

# --- Configuration from wrapper ---
SKILLS_DIR="${SKILLS_DIR:-~/.claude/skills}"
SETTINGS_DIR="${SETTINGS_DIR:-~/.claude}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-http://localhost:14041}"
SKILL_SLUG="${SKILL_SLUG:-image-generation}"
SKILL_DIR="${SKILL_DIR:-${SKILLS_DIR}/${SKILL_SLUG}}"

# Expand tilde (cross-OS)
SKILLS_DIR="$(echo "$SKILLS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_DIR="$(echo "$SETTINGS_DIR" | sed "s|^~|$HOME|g")"
SKILL_DIR="$(echo "$SKILL_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
HOOKS_DIR="${SETTINGS_DIR}/hooks"
HOOK_FILE="${HOOKS_DIR}/${SKILL_SLUG}-skill-hook.sh"

# Marker used by both uninstall (strip) and state (detect): the hook file path.
HOOK_MARKER="${SKILL_SLUG}-skill-hook.sh"

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

do_install() {
    # --- Validate API key ---
    if [ -z "${API_KEY:-}" ]; then
        echo "Error: API_KEY is not set. This should be passed from the wrapper install script."
        exit 1
    fi

    echo "Configuring Claude Code settings for image-generation skill..."

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
import os
# Fail closed: only synthesize a skeleton when there is NO existing file. An
# existing-but-unparseable settings.json (hand-edit typo, half-written save)
# must be left untouched rather than overwritten — clobbering it would wipe
# every key the user had.
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
    local HOOK_SOURCE="${SKILL_DIR}/hook.sh"

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
    local RUN_SH="${SKILLS_DIR}/image-generation/run.sh"
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
}

do_uninstall() {
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
}

# Print one JSON line describing install state. Installed ⇔ the UserPromptSubmit
# hook is wired into settings.json (the durable, config-side signal). Exit 0
# always; the JSON IS the payload. No key, no network.
do_state() {
    local installed="false"
    if [ -f "$SETTINGS_FILE" ] && command -v python3 >/dev/null 2>&1; then
        if MARKER="$HOOK_MARKER" python3 - "$SETTINGS_FILE" << 'PYEOF' 2>/dev/null
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
    elif [ -f "$SETTINGS_FILE" ] && grep -qF "$HOOK_MARKER" "$SETTINGS_FILE" 2>/dev/null; then
        installed="true"
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
