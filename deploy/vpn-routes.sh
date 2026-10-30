#!/usr/bin/env bash
# Routing of VPN clients on the entry server (vpn-routes.service, start and
# reload): the nft table (deploy/vpn.nft), the fwmark rule and the
# fail-closed `unreachable` route of table 100. Every step is idempotent and
# nothing is deleted, so a reload has no window.
# `vpn-routes.sh rules` (vpn-routes-check.timer, every 15 s) only re-asserts
# the ip rule and the routes: systemd-networkd or a manual `netplan apply`
# may drop them. It loads the nft table only when that is gone.
# ROOT is a path prefix for tests.
set -euo pipefail
ROOT="${ROOT:-}"

mode="${1:-}"
# An `nft flush ruleset` or a start of nftables.service removes the table:
# client packets are then neither marked nor filtered. Load it as at start.
if [[ "$mode" == rules ]] && ! nft list chain inet vpn pre 2>/dev/null | grep 'mark set' >/dev/null; then
  echo "warning: nft table inet vpn was missing, loaded again" >&2
  mode=""
fi
if [[ "$mode" != rules ]]; then
  nft -f "$ROOT/etc/vpn/vpn.nft"
fi
ip route replace unreachable default metric 4096 table 100
# `ip rule add` of an existing rule fails (EEXIST): add only when missing
# (grep without -q: an early exit could fail the pipe under pipefail).
if ! ip rule show prio 110 | grep 'fwmark 0x1 lookup 100' >/dev/null; then
  # at start the rule is new; in the check a missing rule means something
  # wiped it: leave a trace of when
  [[ "${1:-}" != rules ]] || echo "warning: routing rule was missing, re-added" >&2
  ip rule add fwmark 0x1 lookup 100 prio 110
fi
# The tunnel conf's PostUp sets this route once; put it back if it was
# dropped while the tunnel is up (without it only `unreachable` is left).
# Not fatal: a link that is not up yet refuses the route, traffic stays
# fail-closed on `unreachable`, and the next check tries again.
if ip link show awg-exit >/dev/null 2>&1; then
  ip route replace default dev awg-exit table 100 ||
    echo "warning: exit route not set yet (awg-exit not up?)" >&2
fi
