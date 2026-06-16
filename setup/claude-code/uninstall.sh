# Remove the OpenLLM configuration from Claude Code. Sourced into the
# uninstall pipeline; `$GATEWAY_ORIGIN` and the `has_command` / `ensure_dir`
# helpers are populated by the gateway preamble before this script runs.
#
# Best-effort + idempotent: strips ONLY the `env` keys install.sh wrote
# (`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,
# HAIKU}_MODEL`) and leaves the rest of settings.json intact. No-op when the
# file is absent.

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "  No settings.json found — nothing to undo."
else
  if has_command jq; then
    tmp=$(mktemp)
    # Only overwrite + claim success if jq actually succeeded — otherwise clean
    # up the temp file and leave settings.json untouched (no false success).
    if jq '
      if .env then
        .env |= del(
          .ANTHROPIC_BASE_URL,
          .ANTHROPIC_API_KEY,
          .ANTHROPIC_DEFAULT_OPUS_MODEL,
          .ANTHROPIC_DEFAULT_SONNET_MODEL,
          .ANTHROPIC_DEFAULT_HAIKU_MODEL
        )
        | if (.env | length) == 0 then del(.env) else . end
      else . end
    ' "$SETTINGS_FILE" > "$tmp"; then
      mv "$tmp" "$SETTINGS_FILE"
      echo "  Removed OpenLLM keys from $SETTINGS_FILE"
    else
      rm -f "$tmp"
      echo "  Warning: jq failed — leaving settings.json untouched." >&2
    fi
  else
    echo "  Warning: jq not found — leaving settings.json untouched." >&2
    echo "  Manually remove the ANTHROPIC_* keys under .env from $SETTINGS_FILE" >&2
  fi
fi

echo "Claude Code OpenLLM configuration removed."
