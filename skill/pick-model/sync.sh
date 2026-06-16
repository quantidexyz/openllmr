#!/usr/bin/env bash
# pick-model skill — regenerates one slash-command file per gateway model.
#
# Runs at every Claude Code SessionStart (wired up by install.sh). Also safe
# to run manually: `bash ~/.claude/hooks/pick-model-sync.sh`.
#
# Contract:
#   * Hits $GATEWAY_URL/v1/models with $API_KEY.
#   * Writes $COMMANDS_DIR/m-<slug>.md for each returned model id.
#   * Deletes any stale m-*.md left over from a previous run (so renamed /
#     removed gateway models don't linger in the autocomplete).
#   * Never fails the SessionStart hook — prints a warning to stderr and
#     exits 0 even when the gateway is unreachable. A broken autocomplete is
#     preferable to a broken session.
#
# install.sh rewrites the __PLACEHOLDER__ lines below with the real gateway
# URL and API key before copying this file into ~/.claude/hooks/.

set -u  # deliberately NOT -e — see note above

# --- Injected configuration (install.sh rewrites these lines) -------------
: "${GATEWAY_URL:=__GATEWAY_URL__}"
: "${API_KEY:=__API_KEY__}"
_SKILL_CONFIGURED="__SKILL_CONFIGURED__"  # install.sh replaces with: yes

COMMANDS_DIR="${COMMANDS_DIR:-${HOME}/.claude/commands}"

if [ "${_SKILL_CONFIGURED:-no}" != "yes" ]; then
    echo "pick-model: hook not configured (placeholders still present). Re-run the installer." >&2
    exit 0
fi
if [ -z "$GATEWAY_URL" ] || [ -z "$API_KEY" ]; then
    echo "pick-model: GATEWAY_URL or API_KEY is empty — skipping sync." >&2
    exit 0
fi

mkdir -p "$COMMANDS_DIR"

RESP="$(mktemp)"
trap 'rm -f "$RESP"' EXIT

HTTP_CODE="$(
    curl -sS --max-time 10 \
        -o "$RESP" \
        -w '%{http_code}' \
        "${GATEWAY_URL%/}/v1/models" \
        -H "Authorization: Bearer $API_KEY" \
    || echo "000"
)"

if [ "$HTTP_CODE" = "000" ] || [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "pick-model: gateway returned HTTP $HTTP_CODE — leaving existing /m-* commands in place." >&2
    exit 0
fi

COMMANDS_DIR="$COMMANDS_DIR" RESP="$RESP" python3 <<'PY'
import json, os, re, pathlib, sys

commands_dir = pathlib.Path(os.environ["COMMANDS_DIR"])
try:
    doc = json.load(open(os.environ["RESP"]))
except Exception as e:
    print(f"pick-model: response was not JSON: {e}", file=sys.stderr)
    sys.exit(0)

models = [m.get("id") for m in (doc.get("data") or []) if m.get("id")]
if not models:
    print("pick-model: gateway returned no models — skipping.", file=sys.stderr)
    sys.exit(0)

# Clean out previous m-*.md files so renamed/removed models don't linger.
for f in commands_dir.glob("m-*.md"):
    try:
        f.unlink()
    except OSError:
        pass

slug_re = re.compile(r"[^a-zA-Z0-9]+")
seen = set()
written = 0
for mid in models:
    slug = slug_re.sub("-", mid).strip("-").lower()
    if not slug or slug in seen:
        continue
    seen.add(slug)
    body = f"""---
description: Switch active model to `{mid}`
---

!`python3 -c "import json,os; p=os.path.expanduser('~/.claude/settings.json'); d=json.load(open(p)) if os.path.exists(p) else {{}}; d['model']='{mid}'; json.dump(d, open(p,'w'), indent=2)" 2>/dev/null; printf '/model {mid}' | pbcopy 2>/dev/null; true`

Respond with exactly this one sentence: "Default model set to `{mid}` — `/model {mid}` is on your clipboard, paste it to activate this session."
"""
    (commands_dir / f"m-{slug}.md").write_text(body)
    written += 1

print(f"pick-model: wrote {written} /m-* commands to {commands_dir}")
PY
