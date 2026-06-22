# Remove the OpenLLM provider from the Kimi CLI. Sourced into the uninstall
# pipeline; `$GATEWAY_ORIGIN` and the `has_command` / `ensure_dir` helpers are
# populated by the gateway preamble before this script runs.
#
# Best-effort + idempotent: strips the `# >>> openllm … <<<` managed regions
# install.sh wrote (the selection keys + the [providers.openllm] / per-model
# tables), leaving every other config.toml line intact. No-op when the config
# is absent.

KIMI_DIR="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
CONFIG_FILE="$KIMI_DIR/config.toml"

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

echo "Kimi CLI OpenLLM configuration removed."
