#!/usr/bin/env bash
# Runs as root on the entry server from the unpacked deploy package
# (scripts/deploy.sh uploads it). Installs or updates the host tuning,
# AmneziaWG (awg0 for clients, the awg-exit tunnel), routing through the
# exit, DNS for clients and vpn-peer. Every step can run again: nothing is
# deleted, awg0 is never restarted, awg-exit and unbound restart only when
# their files changed. ROOT is a path prefix for tests.
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)" # removed by its creator (scripts/deploy.sh), not here
ROOT="${ROOT:-}"
SD="$ROOT/etc/systemd/system"
AW="$ROOT/etc/amnezia/amneziawg"

# 1. Host tuning: forwarding, conntrack size.
install -d "$ROOT/etc/sysctl.d" "$ROOT/etc/modules-load.d" "$ROOT/etc/modprobe.d"
install -m 644 "$S/99-vpn.conf" "$ROOT/etc/sysctl.d/"
install -m 644 "$S/nf_conntrack-modules.conf" "$ROOT/etc/modules-load.d/nf_conntrack.conf"
install -m 644 "$S/nf_conntrack-modprobe.conf" "$ROOT/etc/modprobe.d/nf_conntrack.conf"
install -m 644 "$S/amneziawg-modules.conf" "$ROOT/etc/modules-load.d/amneziawg.conf"
modprobe nf_conntrack || echo "warning: module nf_conntrack not loaded" >&2
# the live value follows the shipped file, so both always agree; the kernel
# rehashes in place, no connection drops
HS="$ROOT/sys/module/nf_conntrack/parameters/hashsize"
if [[ -w "$HS" ]]; then
  sed -n 's/.*hashsize=//p' "$S/nf_conntrack-modprobe.conf" >"$HS" || echo "warning: conntrack hash size not applied" >&2
else
  echo "warning: conntrack hash size not applied (module not loaded)" >&2
fi
sysctl -q -p "$ROOT/etc/sysctl.d/99-vpn.conf"

# 2. AmneziaWG (kernel module, awg/awg-quick) and the packages. unbound
# comes now: vpn.nft names its user. curl: `vpnctl.sh status` asks for the
# external IP with it.
bash "$S/awg-module.sh"
if ! dpkg -s unbound nftables curl >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq unbound nftables curl
fi
bash "$S/awg-tools.sh"

# 3. nft table and the routes units.
install -d -m 755 "$ROOT/opt/vpn"
install -m 755 "$S/vpn-routes.sh" "$S/awg0-check.sh" "$ROOT/opt/vpn/"
install -d -m 700 "$ROOT/etc/vpn"
install -m 600 "$S/vpn.nft" "$ROOT/etc/vpn/"
install -d "$SD/unbound.service.d" "$ROOT/etc/unbound/unbound.conf.d"
install -m 644 "$S"/*.service "$S"/*.timer "$SD/"
# systemd-networkd drops foreign ip rules and routes whenever it reconfigures
# a link (see networkd-vpn.conf). It reads this file at start only, so
# restart it once; a restart itself removes nothing.
ND="$ROOT/etc/systemd/networkd.conf.d"
if ! cmp -s "$S/networkd-vpn.conf" "$ND/vpn.conf"; then
  install -d "$ND"
  install -m 644 "$S/networkd-vpn.conf" "$ND/vpn.conf"
  if systemctl is-active --quiet systemd-networkd.service; then
    systemctl restart systemd-networkd.service
  fi
fi
systemctl daemon-reload
systemctl enable --quiet vpn-awg0.service vpn-awg-exit.service vpn-routes.service
# Reload, never restart: awg0 Requires= it, a restart would drop every client.
if systemctl is-active --quiet vpn-routes.service; then
  systemctl reload vpn-routes.service
else
  systemctl start vpn-routes.service
fi

# 4. awg-exit: restarted only when its conf changed. Stop first: `down` must
# run with the OLD conf. A failed start stops the deploy here.
install -d -m 700 "$AW"
if ! cmp -s "$S/awg-exit.conf" "$AW/awg-exit.conf"; then
  systemctl stop vpn-awg-exit.service 2>/dev/null || true
  install -m 600 "$S/awg-exit.conf" "$AW/awg-exit.conf"
fi
systemctl start vpn-awg-exit.service

# 5. awg0: the conf is created on the first install only, never overwritten;
# start, never restart (that would drop every client).
ROOT="$ROOT" bash "$S/awg0-init.sh"
bash "$S/awg0-check.sh" "$AW/awg0.conf" ||
  echo "warning: remove that line from awg0.conf: until then vpn-peer refuses every change" >&2
systemctl is-active --quiet vpn-awg0.service || systemctl start vpn-awg0.service
# ufw (if someone turned it on) drops forwarded and incoming traffic by default.
if command -v ufw >/dev/null && ufw status | grep '^Status: active' >/dev/null; then
  ufw allow 443/udp
  ufw route allow in on awg0
  ufw allow in on awg0 to 10.8.0.1 port 53
fi

# 6. unbound, restarted only when one of its two files changed (a deploy must
# not cut the clients' DNS).
unbound_new=0
cmp -s "$S/unbound-after-awg0.conf" "$SD/unbound.service.d/vpn.conf" || unbound_new=1
cmp -s "$S/unbound-vpn.conf" "$ROOT/etc/unbound/unbound.conf.d/vpn.conf" || unbound_new=1
install -m 644 "$S/unbound-after-awg0.conf" "$SD/unbound.service.d/vpn.conf"
install -m 644 "$S/unbound-vpn.conf" "$ROOT/etc/unbound/unbound.conf.d/vpn.conf"
systemctl daemon-reload
# Ubuntu's unbound-resolvconf points the host resolver at 127.0.0.1, where
# this unbound does not listen.
systemctl disable --quiet --now unbound-resolvconf.service 2>/dev/null || true
systemctl enable --quiet unbound.service
if [[ "$unbound_new" == 1 ]]; then
  systemctl restart unbound.service
else
  systemctl start unbound.service
fi

# 7. vpn-peer, the MSS clamp and the 15-second routes check.
install -d "$ROOT/usr/local/sbin"
install -m 700 "$S/vpn-peer.sh" "$ROOT/usr/local/sbin/vpn-peer"
systemctl enable --quiet --now vpn-mss.service
systemctl enable --quiet --now vpn-routes-check.timer
