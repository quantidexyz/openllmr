#!/usr/bin/env bash
# UserPromptSubmit hook — auto-recall relevant memories from the LiteLLM
# gateway's supermemory store and inject them as additional context so the
# agent never has to call `recall` itself.
#
# Wire: a Claude Code hook under `hooks.UserPromptSubmit`. Input: the event
# JSON on stdin. Output: a JSON object with hookSpecificOutput.additionalContext,
# or empty stdout (exit 0) when nothing useful matched. Failures are SILENT —
# this hook runs on every prompt, so a down gateway must never surface as an
# error to the user.
#
# Env (populated by install.sh via a per-hook env prefix in settings.json):
#   LLM_GATEWAY_URL      required
#   LLM_GATEWAY_API_KEY  required
#   SUPERMEMORY_RECALL_MIN_SIMILARITY  optional, default 0.50
#   SUPERMEMORY_RECALL_LIMIT           optional, default 5
#   SUPERMEMORY_RECALL_PROJECT         optional hard override; if unset the
#                                      project slug is derived per-event from
#                                      the prompt's cwd (git-root basename,
#                                      slugified; falls back to cwd basename).
#                                      Memories from "default" are also
#                                      always searched as a global fallback.
#   SUPERMEMORY_RECALL_MAX_PROMPT      optional, default 2000 chars (cap on
#                                      the query we send to the gateway — the
#                                      gateway's own hard cap is 1000 so we
#                                      pre-trim)
set -u

# Guard: missing config → silently no-op.
if [ -z "${LLM_GATEWAY_URL:-}" ] || [ -z "${LLM_GATEWAY_API_KEY:-}" ]; then
    exit 0
fi

MIN_SIM="${SUPERMEMORY_RECALL_MIN_SIMILARITY:-0.50}"
RECALL_LIMIT="${SUPERMEMORY_RECALL_LIMIT:-5}"
RECALL_PROJECT="${SUPERMEMORY_RECALL_PROJECT:-}"
MAX_PROMPT_CHARS="${SUPERMEMORY_RECALL_MAX_PROMPT:-2000}"

# Read the event JSON (stdin). Everything below runs under python3 which parses
# the prompt, calls the gateway, formats the context, and emits the hook output.
# We require python3 — consistent with install.sh's hard dependency.
if ! command -v python3 >/dev/null 2>&1; then
    exit 0
fi

python3 - "$LLM_GATEWAY_URL" "$LLM_GATEWAY_API_KEY" "$MIN_SIM" "$RECALL_LIMIT" "$RECALL_PROJECT" "$MAX_PROMPT_CHARS" <<'PYEOF' 2>/dev/null || exit 0
import json, os, sys, re, subprocess, urllib.request, urllib.error

gateway, api_key, min_sim_s, limit_s, project_override, max_chars_s = sys.argv[1:7]

try:
    min_sim = float(min_sim_s)
except ValueError:
    min_sim = 0.50
try:
    limit = max(1, min(20, int(limit_s)))
except ValueError:
    limit = 5
try:
    max_chars = max(16, min(1000, int(max_chars_s)))  # gateway hard cap is 1000
except ValueError:
    max_chars = 1000

try:
    event = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = (event.get("prompt") or "").strip()
# Skip trivially short prompts — sending "ok" to semantic search is noise.
if len(prompt) < 6:
    sys.exit(0)

# Skip when prompt starts with `!` (Claude Code shell-escape) — not a real query.
if prompt.startswith("!"):
    sys.exit(0)

# Respect the gateway's 1000-char cap.
if len(prompt) > max_chars:
    prompt = prompt[:max_chars]


def _slugify(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9._-]+", "-", s)
    s = re.sub(r"-+", "-", s)
    s = s.strip("-._")[:64]
    return s if (s and re.match(r"^[a-z0-9]", s)) else ""


def _derive_project(cwd: str) -> str:
    if cwd:
        try:
            out = subprocess.run(
                ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=2.0,
            )
            if out.returncode == 0 and out.stdout.strip():
                slug = _slugify(os.path.basename(out.stdout.strip()))
                if slug:
                    return slug
        except Exception:
            pass
        slug = _slugify(os.path.basename(cwd.rstrip("/")))
        if slug:
            return slug
    return "default"


# Hard env override > derived from cwd > "default". Memories saved under
# "default" are always included as a fallback so global facts about the
# user surface even outside any project bucket.
if project_override:
    project = _slugify(project_override) or "default"
else:
    project = _derive_project(event.get("cwd") or os.getcwd())

projects = [project]
if project != "default":
    projects.append("default")

url = gateway.rstrip("/") + "/api/plugins/supermemory/search"
body = json.dumps({"query": prompt, "limit": limit, "projects": projects}).encode()
req = urllib.request.Request(
    url,
    data=body,
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(req, timeout=1.5) as resp:
        data = json.loads(resp.read())
except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError):
    # Gateway down, bad key, malformed response — fail open, no error to user.
    sys.exit(0)

results = data.get("results") or []
# Filter on similarity threshold and truncate content per-result so the
# injected context never explodes the conversation budget.
hits = []
for r in results:
    sim = r.get("similarity")
    if not isinstance(sim, (int, float)):
        continue
    if sim < min_sim:
        continue
    content = (r.get("content") or "").strip()
    if not content:
        continue
    if len(content) > 500:
        content = content[:500].rstrip() + "…"
    hits.append((sim, content, r.get("project") or project))

if not hits:
    sys.exit(0)

lines = ["[supermemory] Relevant saved memories (auto-recalled):"]
for sim, content, proj in hits:
    pct = round(sim * 100)
    lines.append(f"- ({pct}% · {proj}) {content}")

output = {
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": "\n".join(lines),
    }
}
json.dump(output, sys.stdout)
PYEOF

exit 0
