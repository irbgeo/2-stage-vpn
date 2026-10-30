#!/usr/bin/env bash
# Runs as root on the exit server from the unpacked package (scripts/deploy-exit.sh).
# Installs awg tools, the tunnel conf (its PostUp runs exit-fw.sh: forwarding/NAT) and the
# vpn-awg-exit service. Never touches docker or other services. ROOT is a
# path prefix for tests.
set -euo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-}"

bash "$S/awg-module.sh"
bash "$S/awg-tools.sh"

# The conf's PostUp/PostDown call it; in place before the tunnel starts.
install -d "$ROOT/usr/local/sbin"
install -m 755 "$S/exit-fw.sh" "$ROOT/usr/local/sbin/vpn-exit-fw.sh"

# The tunnel is restarted only when its conf changed (a run that changes
# nothing must not cut client traffic). Stop first: `down` must run the OLD
# conf's PostDown, before the conf is replaced.
if ! cmp -s "$S/awg-exit.conf" "$ROOT/etc/amnezia/amneziawg/awg-exit.conf"; then
  systemctl stop vpn-awg-exit.service 2>/dev/null || true
  install -d -m 700 "$ROOT/etc/amnezia/amneziawg"
  install -m 600 "$S/awg-exit.conf" "$ROOT/etc/amnezia/amneziawg/awg-exit.conf"
fi
install -d "$ROOT/etc/systemd/system" "$ROOT/etc/sysctl.d" "$ROOT/etc/modules-load.d" "$ROOT/etc/modprobe.d"
install -m 644 "$S/vpn-awg-exit.service" "$ROOT/etc/systemd/system/"
install -m 644 "$S/99-vpn.conf" "$ROOT/etc/sysctl.d/"
# conntrack must be loaded before systemd-sysctl at boot, or the two
# nf_conntrack settings fall back to the defaults after a reboot; the
# modprobe file sets the hash size at the next load of the module. Warnings
# only: the tunnel may be stopped here and must come back up.
install -m 644 "$S/nf_conntrack-modules.conf" "$ROOT/etc/modules-load.d/nf_conntrack.conf"
install -m 644 "$S/nf_conntrack-modprobe.conf" "$ROOT/etc/modprobe.d/nf_conntrack.conf"
modprobe nf_conntrack || echo "warning: module nf_conntrack not loaded" >&2
# the live value follows the shipped file, so nobody waits for a reboot (the
# entry install does the same); the kernel rehashes in place, no connection drops
HS="$ROOT/sys/module/nf_conntrack/parameters/hashsize"
if [[ -w "$HS" ]]; then
  sed -n 's/.*hashsize=//p' "$S/nf_conntrack-modprobe.conf" >"$HS" || echo "warning: conntrack hash size not applied" >&2
else
  echo "warning: conntrack hash size not applied (module not loaded)" >&2
fi
sysctl -q -p "$ROOT/etc/sysctl.d/99-vpn.conf" || echo "warning: sysctl settings not applied" >&2

# ufw (if someone turned it on) drops incoming and forwarded traffic by
# default: open the tunnel port and let the tunnel's traffic through.
if command -v ufw >/dev/null && ufw status | grep '^Status: active' >/dev/null; then
  port="$(sed -n 's/^ListenPort[[:space:]]*=[[:space:]]*//p' "$ROOT/etc/amnezia/amneziawg/awg-exit.conf")"
  ufw allow "$port/udp"
  ufw route allow in on awg-exit
fi

systemctl daemon-reload
systemctl enable --quiet vpn-awg-exit.service
systemctl start vpn-awg-exit.service
