#!/usr/bin/env bash
# image-generation skill — runnable entry point.
#
# Reads config + arguments from environment variables, posts to
# $GATEWAY_URL/v1/images/generations, writes each returned image to $OUT_DIR
# and prints one absolute path per line.
#
# Design notes (UX-driven):
#   * Never silently eat the response body. On any HTTP error we print what
#     the gateway actually said — that's where "Invalid model name ..." lives.
#   * MODEL is auto-discovered if not set. Don't make the caller guess which
#     image model their key has access to.
#   * JSON payload is built by python3 from env vars (not shell-quoted), so
#     prompts with quotes / newlines / unicode can't break the request.
#   * Config (GATEWAY_URL, API_KEY) is injected by install.sh at the top of
#     this file. Env vars still win — handy for testing against another key
#     without reinstalling.

set -euo pipefail

# --- Injected configuration (install.sh rewrites these lines) -------------
: "${GATEWAY_URL:=__GATEWAY_URL__}"
: "${API_KEY:=__API_KEY__}"
_SKILL_CONFIGURED="__SKILL_CONFIGURED__"  # install.sh replaces with: yes

# --- Inputs ---------------------------------------------------------------
PROMPT="${PROMPT:-}"
MODEL="${MODEL:-}"
N="${N:-1}"
SIZE="${SIZE:-}"            # optional, e.g. 1024x1024 or 1200x630
OUT_DIR="${OUT_DIR:-/tmp}"

if [ -z "$PROMPT" ]; then
    echo "ERROR: set PROMPT to a detailed description of the image" >&2
    exit 2
fi
if [ "${_SKILL_CONFIGURED:-no}" != "yes" ]; then
    echo "ERROR: skill not properly installed (GATEWAY_URL / API_KEY not injected)." >&2
    echo "       Re-run the skill installer." >&2
    exit 2
fi
if [ -z "$GATEWAY_URL" ]; then
    echo "ERROR: GATEWAY_URL is empty. Re-run the skill installer." >&2
    exit 2
fi
if [ -z "$API_KEY" ]; then
    echo "ERROR: API_KEY is empty. Re-run the skill installer." >&2
    exit 2
fi

mkdir -p "$OUT_DIR"

# --- Helper: list image_generation models visible to this key -------------
# Queries the gateway's /api/models/extended (litellmctl-specific route that
# includes model_info.mode). Prints model IDs to stdout (one per line) and
# encodes the outcome in the return code so the caller can distinguish a
# network failure from an empty list:
#   0 — one or more models available
#   1 — gateway reachable but returned no image_generation models for this key
#   2 — network / auth / transport failure reaching the gateway
list_image_models() {
    local raw
    if ! raw="$(curl -fsS --max-time 15 "$GATEWAY_URL/api/models/extended" \
                -H "Authorization: Bearer $API_KEY" 2>/dev/null)"; then
        return 2
    fi
    local ids
    ids="$(printf '%s' "$raw" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get('models', []) or []:
    if m.get('mode') == 'image_generation':
        print(m.get('id'))
" 2>/dev/null)"
    if [ -z "$ids" ]; then
        return 1
    fi
    printf '%s\n' "$ids"
    return 0
}

# --- Auto-discover MODEL if unset -----------------------------------------
if [ -z "$MODEL" ]; then
    # Temporarily disable errexit so we can inspect the return code — `set -e`
    # otherwise makes a non-zero return from the function kill the script.
    set +e
    AVAIL="$(list_image_models)"
    RC=$?
    set -e
    case $RC in
        0)
            MODEL="$(printf '%s\n' "$AVAIL" | head -n1)"
            ;;
        1)
            echo "ERROR: no image_generation models are visible to this API key." >&2
            echo "       Check that the gateway has at least one model with" >&2
            echo "       model_info.mode: image_generation and that the key has" >&2
            echo "       access to it, or pass MODEL explicitly." >&2
            exit 3
            ;;
        2)
            echo "ERROR: could not reach $GATEWAY_URL to discover image models." >&2
            echo "       Check GATEWAY_URL, network, and API_KEY, or pass MODEL explicitly." >&2
            exit 4
            ;;
    esac
fi

# --- Build JSON payload (python handles all escaping) ---------------------
PAYLOAD_FILE="$(mktemp)"
RESP_BODY="$(mktemp)"
cleanup() { rm -f "$PAYLOAD_FILE" "$RESP_BODY"; }
trap cleanup EXIT

MODEL="$MODEL" PROMPT="$PROMPT" N="$N" SIZE="$SIZE" python3 - "$PAYLOAD_FILE" <<'PY'
import json, os, sys
payload = {
    "model":  os.environ["MODEL"],
    "prompt": os.environ["PROMPT"],
    "n":      int(os.environ.get("N") or 1),
}
size = os.environ.get("SIZE") or ""
if size:
    payload["size"] = size
with open(sys.argv[1], "w") as f:
    json.dump(payload, f)
PY

# --- Call the gateway -----------------------------------------------------
# -w writes the HTTP code after curl finishes streaming the body to $RESP_BODY.
# We *don't* use --fail / -f because we want to see 4xx bodies.
HTTP_CODE="$(
    curl -sS --max-time 240 \
        -o "$RESP_BODY" \
        -w '%{http_code}' \
        "$GATEWAY_URL/v1/images/generations" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$PAYLOAD_FILE" \
    || echo "000"
)"

if [ "$HTTP_CODE" = "000" ]; then
    echo "ERROR: could not reach $GATEWAY_URL (network / TLS / DNS failure)" >&2
    exit 4
fi

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "ERROR: $GATEWAY_URL returned HTTP $HTTP_CODE" >&2
    # Trim body to a readable size — the full thing is usually fine, but
    # LiteLLM sometimes returns multi-kB JSON.
    head -c 2000 "$RESP_BODY" >&2
    echo >&2

    # If it looks like an invalid-model error, list what IS available so
    # the caller can retry without another round-trip.
    if grep -qiE 'invalid model|not a valid model|model=.*not' "$RESP_BODY"; then
        echo >&2
        echo "Image models available to this key:" >&2
        avail="$(list_image_models)"
        if [ -n "$avail" ]; then
            printf '  - %s\n' $avail >&2
        else
            echo "  (none — no image_generation models visible to this key)" >&2
        fi
    fi
    exit 5
fi

# --- Decode base64 payloads into files ------------------------------------
TS="$(date +%s)" \
OUT_DIR="$OUT_DIR" \
RESP_BODY="$RESP_BODY" \
python3 <<'PY'
import os, json, base64, pathlib, sys
body = open(os.environ["RESP_BODY"]).read()
try:
    doc = json.loads(body)
except Exception as e:
    print(f"ERROR: response was not JSON: {e}", file=sys.stderr)
    print(body[:500], file=sys.stderr)
    sys.exit(6)

images = doc.get("data") or []
if not images:
    print("ERROR: no images returned", file=sys.stderr)
    print(json.dumps(doc)[:500], file=sys.stderr)
    sys.exit(7)

out_dir = pathlib.Path(os.environ["OUT_DIR"])
ts = os.environ["TS"]
written = 0
for i, img in enumerate(images):
    b64 = img.get("b64_json")
    if not b64:
        # Some providers return a URL instead — pass it through so the
        # caller can fetch it themselves if they want.
        url = img.get("url")
        if url:
            print(url)
            written += 1
        continue
    head = base64.b64decode(b64[:16], validate=False)
    ext = "png"
    if head.startswith(b"\xff\xd8\xff"): ext = "jpg"
    elif head.startswith(b"RIFF"):        ext = "webp"
    path = out_dir / f"image-{ts}-{i}.{ext}"
    path.write_bytes(base64.b64decode(b64))
    print(path)
    written += 1

if written == 0:
    print("ERROR: response contained no decodable images", file=sys.stderr)
    sys.exit(8)
PY
