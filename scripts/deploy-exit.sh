#!/usr/bin/env bash
# Installs the exit side of the entry <-> exit tunnel on the host in
# secret/exit-access.yaml. Creates secret/tunnel.yaml on the first run (never
# replaces it). One ssh connection: install, then status.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

"$ROOT/scripts/tunnel-keys.sh"

EXIT_HOST="$(host_of "$EXIT_ACCESS")"
[[ -n "$EXIT_HOST" ]] || { echo "error: no host in $EXIT_ACCESS" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -m 700 "$TMP/pkg"
(umask 077 && "$ROOT/scripts/render-tunnel.sh" exit "$EXIT_HOST" >"$TMP/pkg/awg-exit.conf")
cp "$ROOT/deploy/exit/install.sh" "$ROOT/deploy/exit/vpn-awg-exit.service" "$ROOT/deploy/exit/exit-fw.sh" \
  "$ROOT/deploy/awg-module.sh" "$ROOT/deploy/awg-tools.sh" "$ROOT/deploy/99-vpn.conf" \
  "$ROOT/deploy/nf_conntrack-modules.conf" "$ROOT/deploy/nf_conntrack-modprobe.conf" "$TMP/pkg/"

echo "▶ Installing on the exit server $EXIT_HOST"
# One ssh login. The package, with the private key, goes through stdin, never
# argv. The last lines print the status; a service that is not active or an
# interface that is missing fails. Unpacked as root without owners and
# modes: the Mac's uid must not carry over to the server.
tar -C "$TMP/pkg" -cz . | remote_exit "sudo bash -euo pipefail -c '
S=\$(mktemp -d /tmp/vpn-awg-exit.XXXXXX)
trap \"rm -rf \$S\" EXIT
tar --no-same-owner --no-same-permissions -xz -C \$S
chmod 700 \$S
bash \$S/install.sh
sleep 3
st=\$(systemctl is-active vpn-awg-exit.service || true)
echo \"vpn-awg-exit: \$st\"
awg show awg-exit | head -3
[ \"\$st\" = active ] && awg show awg-exit >/dev/null
'"
echo "✔ Exit server ready"
