#!/usr/bin/env bash
# Tests deploy/vpn-routes.sh with ROOT=<tmp> and fake nft/ip on PATH, then the
# rules in deploy/vpn.nft itself.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../scripts/testlib.sh"

mkdir "$TMP/bin"
# nft: logs; fails on the table file when $BAD_TABLE is set; `list chain`
# prints the mark rule as real nft does when $HAS_TABLE is set, else fails
# (no table).
cat >"$TMP/bin/nft" <<'EOF2'
#!/usr/bin/env bash
echo "nft $*" >>"$CALLS"
if [[ "$1" == list ]]; then
  [[ -n "${HAS_TABLE:-}" ]] || { echo "Error: No such file or directory" >&2; exit 1; }
  printf 'table inet vpn {\n\tchain pre {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n'
  printf '\t\tiifname "awg0" ip daddr != 10.8.0.0/22 meta mark set 0x00000001\n\t}\n}\n'
  exit
fi
[[ -z "${BAD_TABLE:-}" ]]
EOF2
# ip: logs; `rule show` prints the rule when $HAS_RULE is set.
cat >"$TMP/bin/ip" <<'EOF2'
#!/usr/bin/env bash
echo "ip $*" >>"$CALLS"
if [[ "$1 $2" == "link show" ]]; then [[ -n "${HAS_EXIT:-}" ]]; exit; fi
# the tunnel link exists but is not up yet: the kernel refuses the route
if [[ "$*" == "route replace default dev awg-exit table 100" && -n "${EXIT_DOWN:-}" ]]; then echo "RTNETLINK answers: Network is down" >&2; exit 2; fi
[[ "$1 $2" != "rule show" || -z "${HAS_RULE:-}" ]] || echo "110:	from all fwmark 0x1 lookup 100"
EOF2
chmod +x "$TMP/bin"/*

R="$TMP/root"
mkdir -p "$R/etc/vpn"
touch "$R/etc/vpn/vpn.nft"
MODE=""
run() { : >"$TMP/calls"; env CALLS="$TMP/calls" ROOT="$R" PATH="$TMP/bin:$PATH" "$@" bash "$DIR/vpn-routes.sh" $MODE >/dev/null 2>"$TMP/err"; }
n() { grep -c "$1" "$TMP/calls"; }

run
check "exits 0" "0" "$?"
check "table loaded" "1" "$(n "^nft -f $R/etc/vpn/vpn.nft$")"
check "only the table file is loaded (no RU set)" "1" "$(n '^nft -f')"
check "unreachable route" "1" "$(n '^ip route replace unreachable default metric 4096 table 100$')"
check "rule added when missing" "1" "$(n '^ip rule add fwmark 0x1 lookup 100 prio 110$')"
check "rule never deleted" "0" "$(n '^ip rule del')"

# A second run with the rule in place: the rule is there once.
run HAS_RULE=1
check "rule present: exits 0" "0" "$?"
check "rule present: not added again" "0" "$(n '^ip rule add')"

# The table itself does not load: the unit must fail (awg0 Requires= it, so
# clients are not served without marking and filtering).
run BAD_TABLE=1
check "table not loaded: fails" "1" "$([[ $? -ne 0 ]] && echo 1)"

# The exit route: networkd or anything else may drop it while the tunnel is up.
run
check "no tunnel yet: exit route not set" "0" "$(n '^ip route replace default dev awg-exit table 100$')"
run HAS_EXIT=1
check "tunnel up: exit route ensured" "1" "$(n '^ip route replace default dev awg-exit table 100$')"

run HAS_EXIT=1 EXIT_DOWN=1
check "tunnel link not up yet: not fatal" "0" "$?"
check "tunnel link not up yet: rule and unreachable still set" "1 1" "$(n '^ip rule add') $(n '^ip route replace unreachable')"

# `rules` mode (the 15-second check): only ip rule/routes, no nft reload.
MODE=rules
run HAS_EXIT=1 HAS_TABLE=1
check "rules mode: exits 0" "0" "$?"
check "rules mode: nft only looked at, not loaded" "1 0" "$(n '^nft list chain inet vpn pre$') $(n '^nft -f')"
check "rules mode: a missing rule comes back, with unreachable and exit route" "1 1 1" \
  "$(n '^ip rule add fwmark 0x1 lookup 100 prio 110$') $(n '^ip route replace unreachable default metric 4096 table 100$') $(n '^ip route replace default dev awg-exit table 100$')"
check "rules mode: a missing rule is reported" "1" "$(grep -c 'warning: routing rule was missing' "$TMP/err")"
run HAS_EXIT=1 HAS_RULE=1 HAS_TABLE=1
check "rules mode: nothing deleted, rule not re-added" "0 0" "$(n '^ip rule del') $(n '^ip rule add')"
check "rules mode: quiet when all is in place" "0" "$(wc -c <"$TMP/err" | tr -d ' ')"
# The nft table is gone (`nft flush ruleset`): loaded again.
run HAS_EXIT=1 HAS_RULE=1
check "rules mode, no nft table: exits 0" "0" "$?"
check "rules mode, no nft table: table loaded" "nft -f $R/etc/vpn/vpn.nft" "$(grep '^nft -f' "$TMP/calls")"
check "rules mode, no nft table: reported" "1" "$(grep -c 'warning: nft table inet vpn was missing' "$TMP/err")"
MODE=""

# The check unit hides systemd's "Started/Finished" each run, not the script's errors.
CU="$DIR/vpn-routes-check.service"
check "check unit: quiet start/stop, script stderr still logged" "1 1" "$(grep -cx 'LogLevelMax=notice' "$CU") $(grep -cx 'SyslogLevel=warning' "$CU")"
check "check unit runs the rules mode" "ExecStart=/opt/vpn/vpn-routes.sh rules" "$(grep '^ExecStart' "$CU")"
check "check timer: every 15 s" "OnUnitActiveSec=15s" "$(grep '^OnUnitActiveSec' "$DIR/vpn-routes-check.timer")"

# The real nft file.
NFT="$DIR/vpn.nft"
check "no RU set, no direct way out" "0 0" "$(grep -c 'ru4' "$NFT") $(grep -c 'oifname != "awg-exit" oifname != "awg0"' "$NFT")"
check "every client packet out of the subnet is marked" "1" "$(grep -cx $'\t\tiifname "awg0" ip daddr != 10.8.0.0/22 meta mark set 0x1' "$NFT")"
check "unbound's own queries are marked too (DNS through the exit)" "1" \
  "$(grep -cx $'\t\tmeta skuid "unbound" ip daddr != { 127.0.0.0/8, 10.8.0.0/22 } meta mark set 0x1' "$NFT")"
check "output mark chain is a route hook (re-routes the marked packet)" "1" "$(grep -c 'type route hook output priority mangle;' "$NFT")"
check "masquerade only into the tunnel" $'\t\toifname "awg-exit" masquerade' "$(grep -v '^#' "$NFT" | grep 'masquerade')"
for c in pre out post vpn_forward vpn_input; do
  check "chain $c flushed on reload" "1" "$(grep -cx "flush chain inet vpn $c" "$NFT")"
done
check "client to client dropped" "1" "$(grep -cx $'\t\tiifname "awg0" oifname "awg0" drop' "$NFT")"
check "marked traffic not leaving through the tunnel is dropped" "1" "$(grep -cx $'\t\tiifname "awg0" meta mark 0x1 oifname != "awg-exit" drop' "$NFT")"
check "private ranges dropped" "1" "$(grep -cx $'\t\tiifname "awg0" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } drop' "$NFT")"
check "client IPv6 dropped in forward and input" "2" "$(grep -cx $'\t\tiifname "awg0" meta nfproto ipv6 drop' "$NFT")"
check "vpn_input: DNS on 10.8.0.1 allowed" "1" "$(grep -cx $'\t\tiifname "awg0" ip daddr 10.8.0.1 meta l4proto { tcp, udp } th dport 53 accept' "$NFT")"
check "vpn_input: replies and ping allowed, no ssh or site ports" "2 0" \
  "$(grep -cE $'^\t\tiifname "awg0" (ct state established,related|icmp type echo-request) accept$' "$NFT") $(grep -c 'dport { 22' "$NFT")"
check "vpn_input: everything else from clients dropped, as the last rule" $'\t\tiifname "awg0" drop' "$(awk '/chain vpn_input \{/{f=1; next} f && /^\t}$/{f=0; last=prev} f{prev=$0} END{print last}' "$NFT")"

finish
