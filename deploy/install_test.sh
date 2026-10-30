#!/usr/bin/env bash
# Tests deploy/install.sh (entry server) with ROOT=<tmp> and fake commands on PATH.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../scripts/testlib.sh"
has() { [[ -f "$1" ]] && echo 1 || echo 0; }
line() { grep -n "$1" "$TMP/calls" | head -1 | cut -d: -f1; } # first call matching
before() { [[ -n "$(line "$1")" && -n "$(line "$2")" && "$(line "$1")" -lt "$(line "$2")" ]] && echo 1; }

TAG="$(sed -n 's/^AWG_TOOLS_TAG="${AWG_TOOLS_TAG-\([^}]*\)}".*/\1/p' "$DIR/awg-tools.sh")"
R="$TMP/root"
SD="$R/etc/systemd/system"
AW="$R/etc/amnezia/amneziawg"

mkdir "$TMP/bin"
for c in modprobe sysctl nft ip apt-get chown git make iptables; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n' "$c" >"$TMP/bin/$c"
done
# dpkg -s: packages missing unless $DPKG_OK is set.
printf '#!/usr/bin/env bash\n[[ -n "${DPKG_OK:-}" ]]\n' >"$TMP/bin/dpkg"
# awg: --version prints the pinned tag (no build); genkey for awg0-init.
printf '#!/usr/bin/env bash\necho "awg $*" >>"$CALLS"\n[[ "$1" == genkey ]] && echo KEY || echo "amneziawg-tools %s"\n' "$TAG" >"$TMP/bin/awg"
printf '#!/usr/bin/env bash\necho "ufw $*" >>"$CALLS"\n[[ "$1" != status ]] || echo "Status: $UFW"\n' >"$TMP/bin/ufw"
# systemctl also logs the awg-exit conf it sees, to prove the order.
cat >"$TMP/bin/systemctl" <<'X'
#!/usr/bin/env bash
echo "systemctl $* conf=$(cat "$ROOT/etc/amnezia/amneziawg/awg-exit.conf" 2>/dev/null)" >>"$CALLS"
case "$*" in
  *is-active*vpn-routes*) [[ -n "${ROUTES_ACTIVE:-}" ]] ;;
  *is-active*vpn-awg0*) [[ -n "${AWG0_ACTIVE:-}" ]] ;;
  *is-active*systemd-networkd*) [[ -z "${NO_NETWORKD:-}" ]] ;;
  *start*vpn-awg-exit*) [[ -z "${EXIT_FAIL:-}" ]] ;;
esac
X
chmod +x "$TMP/bin"/*

# The package exactly as scripts/deploy.sh builds it (copy_entry_package in lib.sh).
source "$DIR/../scripts/lib.sh"
run() { # run <ufw state> [env...]: installs a fresh copy of the package.
  rm -rf "$TMP/pkg"; mkdir "$TMP/pkg"
  copy_entry_package "$TMP/pkg"
  echo "[Interface] NEW" >"$TMP/pkg/awg-exit.conf"
  : >"$TMP/calls"
  local ufw="$1"; shift
  env CALLS="$TMP/calls" UFW="$ufw" ROOT="$R" PATH="$TMP/bin:$PATH" "$@" \
    bash "$TMP/pkg/install.sh" >"$TMP/out" 2>&1
  local rc=$?
  cat "$TMP/calls" >>"$TMP/all-calls"
  return $rc
}
check "deploy.sh builds its package with the same helper" "1" "$(grep -cx 'copy_entry_package "$TMP/pkg"' "$DIR/../scripts/deploy.sh")"

mkdir -p "$R/sys/module/nf_conntrack/parameters" "$AW"
echo 7680 >"$R/sys/module/nf_conntrack/parameters/hashsize" # the kernel's default on 1 GB
echo "[Interface] OLD" >"$AW/awg-exit.conf"
run active
check "first install exits 0" "0" "$?"
for u in vpn-awg0.service vpn-awg-exit.service vpn-routes.service vpn-mss.service \
  vpn-routes-check.service vpn-routes-check.timer; do
  check "unit $u installed" "1" "$(has "$SD/$u")"
done
check "scripts in /opt/vpn" "1 1" "$(has "$R/opt/vpn/vpn-routes.sh") $(has "$R/opt/vpn/awg0-check.sh")"
check "vpn-peer installed, runnable by root only" "700" "$(mode "$R/usr/local/sbin/vpn-peer")"
check "nft file" "600" "$(mode "$R/etc/vpn/vpn.nft")"
ND="$R/etc/systemd/networkd.conf.d/vpn.conf"
check "networkd keeps foreign rules and routes" "1 1" \
  "$(grep -cx 'ManageForeignRoutingPolicyRules=no' "$ND") $(grep -cx 'ManageForeignRoutes=no' "$ND")"
check "networkd restarted once, before the routes" "1 1" "$(grep -c '^systemctl restart systemd-networkd' "$TMP/calls") $(before '^systemctl restart systemd-networkd' '^systemctl start vpn-routes')"
check "unbound drop-in and conf" "1 1" "$(has "$SD/unbound.service.d/vpn.conf") $(has "$R/etc/unbound/unbound.conf.d/vpn.conf")"
check "sysctl and conntrack files" "1 1 1 1" "$(has "$R/etc/sysctl.d/99-vpn.conf") $(has "$R/etc/modules-load.d/nf_conntrack.conf") $(has "$R/etc/modprobe.d/nf_conntrack.conf") $(has "$R/etc/modules-load.d/amneziawg.conf")"
check "live conntrack hash size" "16384" "$(cat "$R/sys/module/nf_conntrack/parameters/hashsize")"
check "awg0.conf created, root-only" "1 600" "$(grep -c '^Address = 10.8.0.1/22' "$AW/awg0.conf") $(mode "$AW/awg0.conf")"
check "awg-exit.conf replaced, root-only" "[Interface] NEW 600" "$(cat "$AW/awg-exit.conf") $(mode "$AW/awg-exit.conf")"
check "awg-exit stopped with the old conf, then started" "1 1" \
  "$(grep -c '^systemctl stop vpn-awg-exit.service conf=\[Interface\] OLD' "$TMP/calls") $(before '^systemctl stop vpn-awg-exit' '^systemctl start vpn-awg-exit')"
check "inactive awg0 started" "1" "$(grep -c '^systemctl start vpn-awg0' "$TMP/calls")"
check "inactive routes started, not reloaded" "1 0" "$(grep -c '^systemctl start vpn-routes.service' "$TMP/calls") $(grep -c '^systemctl reload vpn-routes' "$TMP/calls")"
check "units enabled" "1" "$(grep -c '^systemctl enable --quiet vpn-awg0.service vpn-awg-exit.service vpn-routes.service' "$TMP/calls")"
check "unbound-resolvconf off, unbound restarted" "1 1" "$(grep -c '^systemctl disable --quiet --now unbound-resolvconf.service' "$TMP/calls") $(grep -c '^systemctl restart unbound' "$TMP/calls")"
check "packages (curl for vpnctl status), after an index update" "1 1" "$(grep -c '^apt-get install.* unbound nftables curl$' "$TMP/calls") $(before '^apt-get update' '^apt-get install')"
check "module loaded" "1" "$(grep -c '^modprobe amneziawg' "$TMP/calls")"
check "ufw active: client port, route and DNS allowed" "1 1 1" "$(grep -c '^ufw allow 443/udp$' "$TMP/calls") $(grep -c '^ufw route allow in on awg0$' "$TMP/calls") $(grep -c '^ufw allow in on awg0 to 10.8.0.1 port 53$' "$TMP/calls")"
check "mss and check timer on" "1 1" "$(grep -c '^systemctl enable --quiet --now vpn-mss.service' "$TMP/calls") $(grep -c '^systemctl enable --quiet --now vpn-routes-check.timer' "$TMP/calls")"
# The order of the spec: tuning -> AmneziaWG -> routes -> awg-exit -> awg0 -> unbound -> timer.
check "order: tuning before the module" "1" "$(before '^sysctl -q -p' '^modprobe amneziawg')"
check "order: module before the routes" "1" "$(before '^modprobe amneziawg' '^systemctl start vpn-routes')"
check "order: routes before awg-exit" "1" "$(before '^systemctl start vpn-routes' '^systemctl start vpn-awg-exit')"
check "order: awg-exit before awg0" "1" "$(before '^systemctl start vpn-awg-exit' '^systemctl start vpn-awg0')"
check "order: awg0 before unbound" "1" "$(before '^systemctl start vpn-awg0' '^systemctl restart unbound')"
check "order: unbound before the check timer" "1" "$(before '^systemctl restart unbound' '^systemctl enable --quiet --now vpn-routes-check.timer')"

# Update: nothing changed -> nothing restarted, keys kept, ufw inactive adds no rules.
cp "$AW/awg0.conf" "$TMP/awg0.first"
cp "$AW/awg-exit.conf" "$TMP/exit.first"
run inactive DPKG_OK=1 ROUTES_ACTIVE=1 AWG0_ACTIVE=1
check "update exits 0" "0" "$?"
check "update: active routes reloaded, not started" "1 0" "$(grep -c '^systemctl reload vpn-routes' "$TMP/calls") $(grep -c '^systemctl start vpn-routes.service' "$TMP/calls")"
check "update: active awg0 left alone" "0" "$(grep -c '^systemctl start vpn-awg0' "$TMP/calls")"
check "update: same tunnel conf, not stopped, only made sure it runs" "0 1" \
  "$(grep -c '^systemctl stop vpn-awg-exit' "$TMP/calls") $(grep -c '^systemctl start vpn-awg-exit' "$TMP/calls")"
check "update: same unbound files, not restarted, only made sure it runs" "0 1" \
  "$(grep -c '^systemctl restart unbound' "$TMP/calls") $(grep -c '^systemctl start unbound' "$TMP/calls")"
check "update: networkd conf unchanged, not restarted" "0" "$(grep -c '^systemctl restart systemd-networkd' "$TMP/calls")"
check "update: awg0.conf and tunnel conf kept (same keys)" "1 1" "$(cmp -s "$AW/awg0.conf" "$TMP/awg0.first" && echo 1) $(cmp -s "$AW/awg-exit.conf" "$TMP/exit.first" && echo 1)"
check "update: ufw inactive, no rules; packages present, no apt-get" "0 0" "$(grep -c '^ufw .*allow' "$TMP/calls") $(grep -c '^apt-get' "$TMP/calls")"
check "update: no warning" "0" "$(grep -c 'warning' "$TMP/out")"

# A hook line in the live conf: vpn-peer would refuse every change; the deploy says so and goes on.
{ cat "$TMP/awg0.first"; echo "PostUp = id"; } >"$AW/awg0.conf"
run inactive DPKG_OK=1 ROUTES_ACTIVE=1 AWG0_ACTIVE=1
check "hook line in awg0.conf: warned, the deploy goes on" "0 1" "$? $(grep -c 'warning: remove that line' "$TMP/out")"
cp "$TMP/awg0.first" "$AW/awg0.conf"

# A changed unbound file does restart unbound.
echo "# old" >>"$R/etc/unbound/unbound.conf.d/vpn.conf"
run inactive DPKG_OK=1 ROUTES_ACTIVE=1 AWG0_ACTIVE=1
check "changed unbound conf: restarted" "1" "$(grep -c '^systemctl restart unbound' "$TMP/calls")"

# No systemd-networkd: the file is installed, nothing is restarted.
rm -f "$ND"
run inactive DPKG_OK=1 ROUTES_ACTIVE=1 AWG0_ACTIVE=1 NO_NETWORKD=1
check "no networkd: conf installed, no restart" "1 0" "$(has "$ND") $(grep -c '^systemctl restart systemd-networkd' "$TMP/calls")"

# No writable live hash size (module built in, a container): a warning, not a failure.
rm -rf "$R/sys/module/nf_conntrack"
run inactive DPKG_OK=1 ROUTES_ACTIVE=1 AWG0_ACTIVE=1
check "no live hash size file: warned, the deploy goes on" "0 1" "$? $(grep -c 'warning: conntrack hash size not applied' "$TMP/out")"
mkdir -p "$R/sys/module/nf_conntrack/parameters"
echo 7680 >"$R/sys/module/nf_conntrack/parameters/hashsize"

# The tunnel does not start: the deploy stops before awg0 and unbound.
echo "[Interface] OLD" >"$AW/awg-exit.conf"
run inactive DPKG_OK=1 ROUTES_ACTIVE=1 EXIT_FAIL=1
check "tunnel fails: deploy fails, awg0 not started" "1 0" "$([[ $? -ne 0 ]] && echo 1) $(grep -c '^systemctl start vpn-awg0' "$TMP/calls")"

check "never restarts routes or awg0, never deletes" "0 0" \
  "$(grep -c '^systemctl restart vpn-\(routes\|awg0\)' "$TMP/all-calls") $(grep -c '^systemctl stop vpn-awg0' "$TMP/all-calls")"

finish
