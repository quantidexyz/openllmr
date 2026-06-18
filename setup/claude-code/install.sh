# Configure Claude Code to use OpenLLM as its Anthropic-compatible API
# provider. Sourced into the install pipeline; `$GATEWAY_ORIGIN`,
# `$API_KEY`, and `$USAGE_URL` are populated by the gateway preamble
# before this script runs.

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

ensure_dir "$CLAUDE_DIR"

# No custom header to inject: the local daemon authenticates with the SAME
# `sk-llm` key Claude Code carries (`ANTHROPIC_API_KEY`), and the gateway
# detects a live daemon from that key's server-side activity — so it 307s
# subscription hops (claude_code) to THIS machine's daemon with no client
# header. See `docs/proposals/daemon-control-via-neon-longpoll.md`.

# Write a fresh settings.json containing ONLY our env keys. Used solely when no
# settings.json exists yet — NEVER to replace a populated file (that would wipe
# the user's hooks / permissions / model / statusLine / …).
write_settings() {
  cat > "$SETTINGS_FILE" <<JSONEOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${GATEWAY_ORIGIN}",
    "ANTHROPIC_API_KEY": "${API_KEY}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "ultra",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "plus",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "lite"
  }
}
JSONEOF
}

# Merge our env keys into an existing settings.json with jq, preserving every
# other key. Returns non-zero (leaving the file untouched) if jq fails.
merge_with_jq() {
  local tmp
  tmp=$(mktemp)
  if jq --arg key "$API_KEY" --arg url "${GATEWAY_ORIGIN}" \
     --arg opus "ultra" --arg sonnet "plus" --arg haiku "lite" '
    .env.ANTHROPIC_API_KEY = $key |
    .env.ANTHROPIC_BASE_URL = $url |
    .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $opus |
    .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet |
    .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $haiku
  ' "$SETTINGS_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS_FILE"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Merge our env keys into an existing settings.json with python3 (the json
# stdlib), preserving every other key. Fails closed: if the existing file does
# NOT parse, it is left exactly as-is and a non-zero status is returned — we
# never silently overwrite a populated-but-unparseable file.
merge_with_python() {
  GATEWAY_ORIGIN="$GATEWAY_ORIGIN" API_KEY="$API_KEY" SETTINGS_FILE="$SETTINGS_FILE" \
  python3 - <<'PYEOF'
import json, os, sys

path = os.environ["SETTINGS_FILE"]
try:
    with open(path) as f:
        settings = json.load(f)
except Exception as e:
    print(f"Error: {path} exists but is not valid JSON — refusing to overwrite ({e}).", file=sys.stderr)
    print("  Fix or remove it, then re-run; your file was left untouched.", file=sys.stderr)
    sys.exit(1)

if not isinstance(settings, dict):
    print(f"Error: {path} is not a JSON object — refusing to overwrite.", file=sys.stderr)
    sys.exit(1)

env = settings.get("env")
if not isinstance(env, dict):
    env = {}
env["ANTHROPIC_BASE_URL"] = os.environ["GATEWAY_ORIGIN"]
env["ANTHROPIC_API_KEY"] = os.environ["API_KEY"]
env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "ultra"
env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "plus"
env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "lite"
settings["env"] = env

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
PYEOF
}

if [ ! -f "$SETTINGS_FILE" ]; then
  # No existing config — a fresh write is safe.
  write_settings
elif has_command jq; then
  if ! merge_with_jq; then
    echo "Error: jq failed to update $SETTINGS_FILE — left untouched." >&2
    echo "  Your settings were NOT modified. Fix the file or install python3 and re-run." >&2
    exit 1
  fi
elif has_command python3; then
  # merge_with_python exits non-zero (and leaves the file as-is) on a parse
  # error; propagate that under `set -e` so we never claim a false success.
  merge_with_python
else
  # Neither merger available: do NOT clobber the user's existing settings.
  echo "Error: neither jq nor python3 found — cannot safely update $SETTINGS_FILE." >&2
  echo "  Refusing to overwrite your existing settings. Install jq or python3, then re-run." >&2
  echo "  Or add these keys under .env manually:" >&2
  echo "    ANTHROPIC_BASE_URL=${GATEWAY_ORIGIN}" >&2
  echo "    ANTHROPIC_API_KEY=<your sk-llm key>" >&2
  echo "    ANTHROPIC_DEFAULT_OPUS_MODEL=ultra, ANTHROPIC_DEFAULT_SONNET_MODEL=plus, ANTHROPIC_DEFAULT_HAIKU_MODEL=lite" >&2
  exit 1
fi

echo "Claude Code configured."
echo "  API base: ${GATEWAY_ORIGIN}"
echo "  Settings: $SETTINGS_FILE"
echo "  Daemon:   subscription models (claude_code) run on your local daemon —"
echo "            start it + connect the provider; the gateway routes to it"
echo "            automatically via your API key (no extra setup)."
