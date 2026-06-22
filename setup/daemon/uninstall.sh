#!/usr/bin/env bash
# Remove the OpenLLM local daemon. The setup wrapper runs THIS extracted script
# as a child `bash` process, so it must be self-contained: `$GATEWAY_ORIGIN`
# arrives as an exported env var, but the `has_command` helper is defined
# locally below (a child bash does NOT inherit the wrapper's shell functions).
#
# Delegates to the daemon's own full teardown (`openllmd uninstall --yes` —
# stops + disables the service, removes the binary, PATH symlink, env, paired
# key, and all local state). No-op with a hint when `openllmd` isn't on PATH.

set -euo pipefail

has_command() {
  command -v "$1" &>/dev/null
}

FALLBACK_BIN="$HOME/.openllm/bin/openllmd"
if has_command openllmd; then
  openllmd uninstall --yes
  echo "OpenLLM daemon removed."
elif [ -x "$FALLBACK_BIN" ]; then
  # Not on PATH (the symlink was removed, or PATH doesn't include it) but the
  # binary is still where the installer put it — run it directly.
  "$FALLBACK_BIN" uninstall --yes
  echo "OpenLLM daemon removed."
else
  echo "  openllmd not found on PATH or at $FALLBACK_BIN — already removed." >&2
fi
