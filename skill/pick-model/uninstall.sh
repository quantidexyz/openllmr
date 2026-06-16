#!/usr/bin/env bash
# Uninstall pick-model skill — reverses what install.sh did.
set -euo pipefail

SKILLS_DIR="${SKILLS_DIR:-~/.claude/skills}"
SETTINGS_DIR="${SETTINGS_DIR:-~/.claude}"
SKILL_SLUG="${SKILL_SLUG:-pick-model}"

SKILLS_DIR="$(echo "$SKILLS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_DIR="$(echo "$SETTINGS_DIR" | sed "s|^~|$HOME|g")"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
HOOKS_DIR="${SETTINGS_DIR}/hooks"
HOOK_FILE="${HOOKS_DIR}/pick-model-sync.sh"
SKILL_DIR="${SKILLS_DIR}/${SKILL_SLUG}"
COMMANDS_DIR="${SETTINGS_DIR}/commands"

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
    removed=0
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
