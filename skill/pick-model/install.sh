#!/usr/bin/env bash
# pick-model skill — unified install / uninstall / state script.
#
#   (no flag)  install: copy sync.sh → hooks/, inject config, register
#              SessionStart hook, run it once.
#   -u         uninstall: strip the hook, remove /m-* commands + hook + skill dir.
#   -s         state: print one JSON line {"installed":bool,"version":string|null}
set -euo pipefail

# --- Configuration from wrapper ---
SKILLS_DIR="${SKILLS_DIR:-~/.claude/skills}"
SETTINGS_DIR="${SETTINGS_DIR:-~/.claude}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-http://localhost:14041}"
SKILL_SLUG="${SKILL_SLUG:-pick-model}"
SKILL_DIR="${SKILL_DIR:-${SKILLS_DIR}/${SKILL_SLUG}}"

# Expand tilde (cross-OS)
SKILLS_DIR="$(echo "$SKILLS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_DIR="$(echo "$SETTINGS_DIR" | sed "s|^~|$HOME|g")"
SKILL_DIR="$(echo "$SKILL_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
HOOKS_DIR="${SETTINGS_DIR}/hooks"
HOOK_FILE="${HOOKS_DIR}/pick-model-sync.sh"
COMMANDS_DIR="${SETTINGS_DIR}/commands"

# Marker used by both uninstall (strip) and state (detect): the SessionStart hook.
HOOK_MARKER="pick-model-sync.sh"

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
        echo "Error: API_KEY is not set. This should be passed from the wrapper install script." >&2
        exit 1
    fi

    echo "Configuring Claude Code settings for pick-model skill..."

    # --- Register the SessionStart hook ---
    configure_settings() {
        local settings_file="$1"
        local hook_file="$2"

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
    local SYNC_SOURCE="${SKILL_DIR}/sync.sh"
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
}

do_uninstall() {
    echo "Uninstalling ${SKILL_SLUG} skill..."

    # --- Revert settings.json: remove the SessionStart hook registration ---
    revert_settings() {
        local settings_file="$1"
        local hook_file="$2"

        if [ ! -f "$settings_file" ]; then
            echo "  No settings.json found, nothing to revert"
            return 0
        fi

        if command -v python3 &>/dev/null; then
            python3 << PYEOF
import json, sys

settings_file = "${settings_file}"
hook_file = "${hook_file}"
changed = False

try:
    with open(settings_file, "r") as f:
        settings = json.load(f)
except Exception as e:
    print(f"Warning: Could not read settings.json: {e}", file=sys.stderr)
    sys.exit(0)

hooks_list = settings.get("hooks", {}).get("SessionStart", [])
new_hooks_list = []
for entry in hooks_list:
    if isinstance(entry, dict) and "hooks" in entry:
        filtered = [h for h in entry["hooks"] if hook_file not in h.get("command", "")]
        if filtered:
            entry["hooks"] = filtered
            new_hooks_list.append(entry)
        else:
            changed = True
            print("  Removed SessionStart hook entry")
    else:
        new_hooks_list.append(entry)

if "hooks" in settings and "SessionStart" in settings["hooks"]:
    if new_hooks_list:
        settings["hooks"]["SessionStart"] = new_hooks_list
    else:
        del settings["hooks"]["SessionStart"]
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
        else
            echo "  Warning: python3 not available — manually remove the hooks.SessionStart entry pointing at ${hook_file}" >&2
            return 1
        fi
    }

    revert_settings "$SETTINGS_FILE" "$HOOK_FILE"

    # --- Remove generated /m-*.md commands ---
    if [ -d "$COMMANDS_DIR" ]; then
        local removed=0
        for f in "$COMMANDS_DIR"/m-*.md; do
            [ -e "$f" ] || continue
            rm -f "$f"
            removed=$((removed + 1))
        done
        if [ "$removed" -gt 0 ]; then
            echo "  Removed ${removed} /m-* command files"
        fi
    fi

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
}

# Print one JSON line describing install state. Installed ⇔ the SessionStart
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
