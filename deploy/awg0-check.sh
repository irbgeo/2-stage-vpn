#!/usr/bin/env bash
# Usage: awg0-check.sh <conf>. vpn-peer runs it on the new conf before every
# write, and install.sh on the live one. awg-quick runs PreUp/PostUp/PreDown/
# PostDown lines as root shell (SaveConfig rewrites the file as root): a conf
# with such a line is refused. awg-quick reads keys without case and with any
# indent, so the check does too.
set -euo pipefail
CONF="${1:?usage: awg0-check.sh <conf>}"
[[ -r "$CONF" ]] || { echo "error: $CONF is missing or unreadable" >&2; exit 1; }
if grep -Ein '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$CONF" >&2; then
  echo "error: $CONF holds a hook or SaveConfig line (above); awg-quick would run it as root. Remove it." >&2
  exit 1
fi
