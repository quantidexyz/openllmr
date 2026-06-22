#!/usr/bin/env bash
# Install the OpenLLM local daemon (openllmd). The setup wrapper downloads +
# verifies the bundle, then runs THIS extracted script as a child `bash`
# process — so it must be self-contained. `$GATEWAY_ORIGIN`, `$API_KEY`, and
# `$USAGE_URL` arrive as exported env vars from the wrapper; the cross-OS
# helpers (`has_command` + `ensure_dir`) are defined locally below (a child
# bash does NOT inherit the wrapper's shell functions).
#
# Steps: detect os/arch → download the published binary + its .sha256 sidecar
# → VERIFY the checksum (refuse on mismatch) → install to
# ~/.openllm/bin/openllmd → symlink it onto PATH as `openllmd` → write the
# single config file ~/.openllm/daemon.env (cloud origin + port + the paired
# API key, mode 0600; the daemon mints OPENLLM_DEVICE_ID into it on first boot)
# → hand off to `openllmd start`, which registers the launch agent (macOS) /
# systemd user unit (Linux) in self-restore mode and (re)starts it, and
# installs shell completion. The daemon dials OUT to the cloud with that key;
# the dashboard drives it from there (no browser→localhost). Idempotent:
# re-run with a different key to re-pair. Manage it after install with
# `openllmd start | stop | status`.

set -euo pipefail

# Surface the failing step instead of dying mutely. Under `set -e` a transient
# non-zero anywhere below aborts with NO output, leaving the user to guess what
# broke — the field-diagnosed failure mode (a one-off non-zero in the
# mv/codesign/start chain aborted the install silently). Name the line + command
# on the way out.
trap 'rc=$?; echo "openllmd install failed (exit $rc) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

has_command() {
  command -v "$1" &>/dev/null
}

ensure_dir() {
  mkdir -p "$1"
}

OPENLLM_DIR="$HOME/.openllm"
BIN_DIR="$OPENLLM_DIR/bin"
BIN_PATH="$BIN_DIR/openllmd"
ENV_FILE="$OPENLLM_DIR/daemon.env"

ensure_dir "$BIN_DIR"

# --- detect os/arch → artifact suffix -------------------------------
uname_s=$(uname -s)
uname_m=$(uname -m)
case "$uname_s" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *) echo "Unsupported OS: $uname_s (daemon supports macOS + Linux only)" >&2; return 1 2>/dev/null || exit 1 ;;
esac
case "$uname_m" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x64" ;;
  *) echo "Unsupported arch: $uname_m" >&2; return 1 2>/dev/null || exit 1 ;;
esac
suffix="${os}-${arch}"
binary_url="${GATEWAY_ORIGIN}/api/daemon/binary/${suffix}"
sha_url="${binary_url}.sha256"

echo "Downloading openllmd (${suffix})..."
# Stage the (tens-of-MB) binary INSIDE $BIN_DIR rather than $TMPDIR/tmpfs: it's
# on the same filesystem as $BIN_PATH (so the final mv is an atomic rename, not
# a cross-device copy) and on the roomy root disk (minimal cloud images mount a
# tiny RAM-backed /tmp where a download this size fails with "Disk quota
# exceeded" while the real disk is near-empty). The sidecar is tiny — keep it
# alongside. trap cleans both on any exit.
tmp_dl="$BIN_DIR/.openllmd.download.$$"
tmp_bin="$BIN_DIR/.openllmd.bin.$$"
tmp_sha="$BIN_DIR/.openllmd.sha.$$"
trap 'rm -f "$tmp_dl" "$tmp_bin" "$tmp_sha"' EXIT
curl -fsSL "$binary_url" -o "$tmp_dl" || { echo "Download failed: $binary_url" >&2; return 1 2>/dev/null || exit 1; }

# The published asset is gzipped (`openllmd-<target>.gz`). Decompress it; if the
# payload isn't gzip (e.g. the gateway served a raw binary), fall back to using
# it as-is. Either way the sha256 below verifies the FINAL (decompressed) binary
# — what actually runs — so any bad/truncated download fails closed there.
# gunzip is universal on the minimal images this runs on; no magic-byte tooling
# (od/file) needed, which keeps it portable across busybox/coreutils.
if has_command gunzip && gunzip -c "$tmp_dl" > "$tmp_bin" 2>/dev/null; then
  : # decompressed a gzip asset
else
  cp "$tmp_dl" "$tmp_bin" # not gzip (or no gunzip) — verify it as-is
fi

# --- verify the published checksum (refuse on mismatch) -------------
if curl -fsSL "$sha_url" -o "$tmp_sha" 2>/dev/null; then
  expected=$(cut -d' ' -f1 < "$tmp_sha")
  if has_command shasum; then
    actual=$(shasum -a 256 "$tmp_bin" | cut -d' ' -f1)
  elif has_command sha256sum; then
    actual=$(sha256sum "$tmp_bin" | cut -d' ' -f1)
  else
    echo "No shasum/sha256sum available to verify the download — refusing to install." >&2
    return 1 2>/dev/null || exit 1
  fi
  if [ "$expected" != "$actual" ]; then
    echo "Checksum mismatch — refusing to install." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1 2>/dev/null || exit 1
  fi
  echo "Checksum verified."
else
  echo "Warning: no published checksum at $sha_url — proceeding unverified." >&2
fi

# --- daemon.env: the single config file (cloud origin + port + key) -----
# Written FIRST — immediately after the checksum verifies, BEFORE the binary
# mv / codesign / start chain. The credentials must NEVER depend on signing or
# start succeeding: the field-diagnosed bug was a transient non-zero in that
# chain aborting the install AFTER the binary upgraded but BEFORE the key was
# rewritten, leaving the daemon paired with a stale key → a 401 reconnect loop.
# Writing the key up front means a later transient failure can't strand the old
# key; the final `openllmd start` restarts the daemon to load this file.
#
# This is the ONE file the daemon (and its launch agent / systemd unit) boots
# from. The daemon authenticates to the cloud with OPENLLM_API_KEY (the SAME
# key your clients use) and the gateway routes that key's subscription models
# to this machine; it mints OPENLLM_DEVICE_ID into this file on first boot.
# Written 0600. Re-running the installer with a different key re-pairs the
# daemon — that's how you "change the daemon's key".
umask 077
# Preserve a device id already minted into daemon.env (or a legacy standalone
# device-id file) — it must stay stable per machine across a re-pair.
DEVICE_ID=""
if [ -f "$ENV_FILE" ]; then
  # `|| true`: when daemon.env exists but has no OPENLLM_DEVICE_ID line yet
  # (installed but the daemon hasn't booted to mint it), grep returns 1, which
  # under `set -euo pipefail` would abort the command-substitution assignment
  # BEFORE the key is rewritten — re-introducing the stale-key strand this very
  # script exists to prevent. Keep the lookup non-fatal.
  DEVICE_ID=$(grep -E '^OPENLLM_DEVICE_ID=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)
fi
if [ -z "$DEVICE_ID" ] && [ -f "$OPENLLM_DIR/device-id" ]; then
  DEVICE_ID=$(head -n1 "$OPENLLM_DIR/device-id" 2>/dev/null)
fi
{
  echo "OPENLLM_CLOUD_ORIGIN=${GATEWAY_ORIGIN}"
  echo "OPENLLM_DAEMON_PORT=8787"
  echo "OPENLLM_API_KEY=${API_KEY}"
  [ -n "$DEVICE_ID" ] && echo "OPENLLM_DEVICE_ID=${DEVICE_ID}"
} > "$ENV_FILE"
chmod 0600 "$ENV_FILE"
# Drop the legacy standalone device-id file now that it lives in daemon.env.
rm -f "$OPENLLM_DIR/device-id" 2>/dev/null || true

# --- install the verified binary into place -------------------------
# A rename on the same filesystem is atomic and safe even while the old daemon
# runs (it keeps the now-unlinked inode); the final `start` swaps it in.
mv "$tmp_bin" "$BIN_PATH"
chmod 0755 "$BIN_PATH"

# --- macOS: make the binary executable by the kernel --------------------
# The released binaries aren't notarized, and cross-compiled targets aren't
# even ad-hoc signed — so on Apple Silicon the kernel SIGKILLs an unsigned
# Mach-O the instant launchd spawns it ("didn't stay running"). Strip the
# Gatekeeper quarantine xattr and ad-hoc sign locally IFF the existing
# signature is missing/invalid (so a future real signature is preserved).
# NOTE: `codesign --verify` takes NO `--quiet` flag — macOS 15 rejects it with
# "unrecognized option '--quiet'" (rc=2), which (swallowed by 2>/dev/null) made
# every run treat the binary as unsigned and needlessly re-sign it.
if [ "$os" = "darwin" ]; then
  xattr -dr com.apple.quarantine "$BIN_PATH" 2>/dev/null || true
  if has_command codesign && ! codesign --verify "$BIN_PATH" 2>/dev/null; then
    codesign --force --sign - "$BIN_PATH" 2>/dev/null || \
      echo "Note: could not codesign the daemon; macOS may block it. Run: codesign --force --sign - $BIN_PATH" >&2
  fi
fi

# --- put openllmd on PATH -------------------------------------------
# Symlink the real binary into the first PATH-friendly dir we can write to
# (prefer /usr/local/bin, else ~/.local/bin) so the user can run
# `openllmd start|stop|status`. The service itself runs $BIN_PATH directly, so
# this link is purely for the user's convenience.
link_dir=""
for cand in "/usr/local/bin" "$HOME/.local/bin"; do
  if [ -d "$cand" ] && [ -w "$cand" ]; then link_dir="$cand"; break; fi
done
[ -z "$link_dir" ] && { link_dir="$HOME/.local/bin"; ensure_dir "$link_dir"; }
ln -sf "$BIN_PATH" "$link_dir/openllmd"
echo "Linked $link_dir/openllmd → $BIN_PATH"
case ":$PATH:" in
  *":$link_dir:"*) ;;
  *) echo "  Add $link_dir to your PATH to run 'openllmd' directly." ;;
esac

# --- register + start the service (self-restore mode) ---------------
# The binary supervises itself: `openllmd start` writes the launch agent /
# systemd unit (KeepAlive / Restart=always + linger), enables it, and starts
# it. `openllmd stop` later stops it AND disables all self-restore.
if ! "$BIN_PATH" start; then
  echo "Failed to start the daemon. Try: $BIN_PATH start" >&2
  return 1 2>/dev/null || exit 1
fi

# --- shell completion (best-effort) ---------------------------------
"$BIN_PATH" completion install 2>/dev/null || \
  echo "  Enable completion later with: openllmd completion install"

echo
echo "OpenLLM daemon installed + paired. It listens on http://127.0.0.1:8787."
echo "The gateway routes this key's subscription models here automatically."
echo "Open the dashboard's Providers tab to connect each vendor."
echo
echo "Manage it:  openllmd status | openllmd stop | openllmd start"
if [ "$os" = "darwin" ]; then
  echo "Logs:       ~/.openllm/openllmd.log (also openllmd.err.log)"
  echo "If it doesn't stay running, open System Settings → General → Login"
  echo "Items → 'Allow in the Background' and enable openllmd."
else
  echo "Logs:       journalctl --user -u openllmd -f   (or ~/.openllm/openllmd.log)"
fi
