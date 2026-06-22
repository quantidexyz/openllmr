# Configure the Codex CLI to route through OpenLLM. Sourced into the install
# pipeline; `$GATEWAY_ORIGIN`, `$API_KEY`, and `$USAGE_URL` are populated by
# the gateway preamble (which also provides `has_command` + `ensure_dir`)
# before this script runs.

# Ensure the Codex CLI is present before configuring it: reuse the existing
# install if any, else run the official installer. (The daemon's isolated CLI is
# just a symlink to this same binary — one install path, the non-isolated one.)
ensure_cli "Codex" codex \
  "$HOME/.local/bin/codex" \
  "https://chatgpt.com/codex/install.sh"

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CODEX_DIR/config.toml"

ensure_dir "$CODEX_DIR"

# No custom header to inject: the local daemon authenticates with the SAME
# `sk-llm` key Codex carries, and the gateway detects a live daemon from that
# key's server-side activity — so it 307s subscription (chatgpt) hops to THIS
# machine's daemon with no client header. See
# `docs/proposals/daemon-control-via-neon-longpoll.md`.

# Fetch a Codex model catalog generated from YOUR activated models (fallback
# chains like `ultra`/`plus` + every connected provider model), keyed by slug
# with real context-window metadata. Without it Codex can't find metadata for
# our alias / non-OpenAI slugs and warns "Model metadata for <slug> not found.
# Defaulting to fallback metadata; this can degrade performance and cause
# issues" — then auto-compacts against a wrong 272k window. Authenticated with
# your API key so it reflects your own chains. Best-effort: if the fetch fails
# we skip the `model_catalog_json` line so the config stays valid (re-run to
# pick it up).
MODELS_FILE="$CODEX_DIR/openllm-models.json"
catalog_line=""
if curl -fsS -H "Authorization: Bearer ${API_KEY}" \
     "${GATEWAY_ORIGIN}/api/setup/codex/model-catalog" -o "$MODELS_FILE.tmp" 2>/dev/null; then
  mv "$MODELS_FILE.tmp" "$MODELS_FILE"
  catalog_line="model_catalog_json = \"${MODELS_FILE}\"
"
else
  rm -f "$MODELS_FILE.tmp"
fi

# TOML requires top-level keys BEFORE any [table], so the provider-selection
# keys and the provider table are two separate marked regions: the selection
# is prepended (stays above every table), the table is appended.
TOP_BLOCK="# >>> openllm (managed) >>>
model_provider = \"openllm\"
model = \"ultra\"
${catalog_line}# <<< openllm (managed) <<<
"
TABLE_BLOCK="# >>> openllm provider (managed) >>>
[model_providers.openllm]
name = \"OpenLLM\"
base_url = \"${GATEWAY_ORIGIN}/v1\"
wire_api = \"responses\"
experimental_bearer_token = \"${API_KEY}\"
# <<< openllm provider (managed) <<<
"

# Idempotent + TOML-safe merge. Strip any prior openllm-managed regions AND the
# user's existing top-level model_provider/model (those before the first
# [table]) so we never create duplicate keys; then PREPEND our selection block
# and APPEND our provider table, preserving everything else.
if [ -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "$CONFIG_FILE.openllm-bak"
  cleaned=$(awk '
    /^# >>> openllm/ { skip=1 }
    skip==1 { if ($0 ~ /^# <<< openllm/) skip=0; next }
    /^[[:space:]]*\[/ { seen_table=1 }
    seen_table==0 && $0 ~ /^[[:space:]]*(model_provider|model)[[:space:]]*=/ { next }
    { print }
  ' "$CONFIG_FILE")
else
  cleaned=""
fi
{
  printf '%s' "$TOP_BLOCK"
  [ -n "$cleaned" ] && printf '%s\n' "$cleaned"
  printf '%s' "$TABLE_BLOCK"
} > "$CONFIG_FILE"

echo "Codex configured."
echo "  Provider: openllm → ${GATEWAY_ORIGIN}/v1 (wire_api=responses)"
echo "  Config:   $CONFIG_FILE"
echo "  Model:    ultra (default fallback chain)"
echo "            Override per run with: codex -m <model>  (e.g. anthropic/claude-opus-4-8)"
echo "            Codex's in-app /model picker only lists OpenAI models — use -m or edit"
echo "            'model =' above to reach any OpenLLM catalog id / chain alias."
if [ -n "$catalog_line" ]; then
  echo "  Catalog:  $MODELS_FILE (model_catalog_json — silences 'metadata not found')"
else
  echo "  Catalog:  not fetched — Codex may warn 'model metadata not found'; re-run to add it."
fi
echo "  Daemon:   the chatgpt subscription runs on your local daemon —"
echo "            start it + connect; the gateway routes to it via your API key."
