#!/usr/bin/env bash
# Installs (or updates) the entry server in secret/entry-access.yaml: host
# AmneziaWG (awg0 for clients, the awg-exit tunnel to the exit server in
# secret/exit-access.yaml), routing through the exit, DNS for clients and
# vpn-peer. Safe to re-run: awg0.conf (server key, clients) is created on the
# first run only. One ssh connection.
#
# Server layout:
#   /etc/amnezia/amneziawg/awg0.conf      clients (root 600), created once
#   /etc/amnezia/amneziawg/awg-exit.conf  the tunnel (root 600)
#   /etc/vpn/vpn.nft                      mark, NAT, client guards
#   /opt/vpn/                             vpn-routes.sh, awg0-check.sh
#   /usr/local/sbin/vpn-peer              client changes (scripts/vpnctl.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

# The tunnel keys are created once, by `make deploy-exit` or `vpnctl.sh init`,
# never here: a new file would give this side keys the exit server does not
# know, and clients would have no internet until the next `make deploy-exit`.
TUNNEL="${TUNNEL_FILE:-$ROOT/secret/tunnel.yaml}"
if [[ ! -s "$TUNNEL" ]]; then
  echo "error: $TUNNEL is missing or empty. It holds the keys of the tunnel to the exit server: restore your copy. Only for a brand-new tunnel: run \`make deploy-exit\` first (it creates the file)." >&2
  exit 1
fi
EXIT_HOST="$(host_of "$EXIT_ACCESS")"
[[ -n "$EXIT_HOST" ]] || { echo "error: no host in $EXIT_ACCESS" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -m 700 "$TMP/pkg"
copy_entry_package "$TMP/pkg"
(umask 077 && "$ROOT/scripts/render-tunnel.sh" ru "$EXIT_HOST" >"$TMP/pkg/awg-exit.conf")

echo "▶ Installing on the entry server $(host_of "$ENTRY_ACCESS")"
# One connection: the package goes through stdin (secrets never in argv),
# install.sh runs from it as root, then the status. Unpacked as root without
# owners and modes: the Mac's uid must not carry over to the server.
tar -C "$TMP/pkg" -cz . | remote_entry "sudo bash -euo pipefail -c '
S=\$(mktemp -d /tmp/vpn-deploy.XXXXXX)
trap \"rm -rf \$S\" EXIT
tar --no-same-owner --no-same-permissions -xz -C \$S
chmod 700 \$S
bash \$S/install.sh
echo \"▶ Status\"
sleep 3
bad=0
for u in vpn-awg0 vpn-awg-exit vpn-routes unbound; do
  st=\$(systemctl is-active \$u.service || true)
  echo \"\$u: \$st\"
  [ \"\$st\" = active ] || bad=1
done
exit \$bad
'"
echo "✔ Entry server ready. Check: ./scripts/vpnctl.sh status"
