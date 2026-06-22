# Remove the OpenLLM provider from the Codex CLI. Sourced into the uninstall
# pipeline; `$GATEWAY_ORIGIN` and the `has_command` / `ensure_dir` helpers are
# populated by the gateway preamble before this script runs.
#
# Best-effort + idempotent: strips the `# >>> openllm … <<<` managed regions
# install.sh wrote (the selection keys + the [model_providers.openllm] table)
# and removes the fetched model catalog, leaving every other config.toml line
# intact. No-op when the config is absent.

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CODEX_DIR/config.toml"
MODELS_FILE="$CODEX_DIR/openllm-models.json"

if [ -f "$CONFIG_FILE" ]; then
  # Same region markers install.sh emits — drop every openllm-managed block.
  cleaned=$(awk '
    /^# >>> openllm/ { skip=1 }
    skip==1 { if ($0 ~ /^# <<< openllm/) skip=0; next }
    { print }
  ' "$CONFIG_FILE")
  # Atomic replace: write to a temp file then mv over the config, so an
  # interrupted write can't corrupt/truncate config.toml.
  tmp=$(mktemp)
  printf '%s\n' "$cleaned" > "$tmp" && mv "$tmp" "$CONFIG_FILE" || rm -f "$tmp"
  echo "  Removed OpenLLM managed regions from $CONFIG_FILE"
else
  echo "  No config.toml found — nothing to undo."
fi

if [ -f "$MODELS_FILE" ]; then
  rm -f "$MODELS_FILE"
  echo "  Removed model catalog: $MODELS_FILE"
fi

echo "Codex OpenLLM configuration removed."
