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

if [ -f "$SETTINGS_FILE" ] && has_command jq; then
  tmp=$(mktemp)
  jq --arg key "$API_KEY" --arg url "${GATEWAY_ORIGIN}" \
     --arg opus "ultra" --arg sonnet "plus" --arg haiku "lite" '
    .env.ANTHROPIC_API_KEY = $key |
    .env.ANTHROPIC_BASE_URL = $url |
    .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $opus |
    .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet |
    .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $haiku
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
else
  [ -f "$SETTINGS_FILE" ] && echo "Warning: jq not found, overwriting settings.json" >&2
  write_settings
fi

echo "Claude Code configured."
echo "  API base: ${GATEWAY_ORIGIN}"
echo "  Settings: $SETTINGS_FILE"
echo "  Daemon:   subscription models (claude_code) run on your local daemon —"
echo "            start it + connect the provider; the gateway routes to it"
echo "            automatically via your API key (no extra setup)."
