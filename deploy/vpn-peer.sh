#!/usr/bin/env bash
# vpn-peer — VPN clients in awg0.conf, the only record of them. Installed as
# /usr/local/sbin/vpn-peer by deploy/install.sh, runs as root.
#
#   vpn-peer add <name>      stdin: the client's public key, then its PSK
#                            (one per line); prints the client's IP
#   vpn-peer remove <name>
#   vpn-peer list            name, IP, last handshake
#   vpn-peer client-params   server public key + obfuscation for client confs
#
# A change runs under a lock: the new conf is checked (awg0-check.sh: no hook
# lines), the old one kept as .bak, the new one written as .tmp and moved in,
# then `awg syncconf` applies it live: other clients stay connected. A failed
# syncconf puts the old conf back. ROOT is a path prefix for tests, CHECK the
# path of awg0-check.sh.
set -euo pipefail
export LC_ALL=C # [A-Za-z] means ASCII letters only
CONF="${ROOT:-}/etc/amnezia/amneziawg/awg0.conf"
CHECK="${CHECK:-/opt/vpn/awg0-check.sh}"

# awk helper for both parsers below: k = the lower-case key of a
# `Key = Value` line, v = its value, all spaces removed.
AWK_KV='function kv(line) { k = line; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); k = tolower(k); v = line; sub(/^[^=]*=/, "", v); gsub(/[[:space:]]/, "", v) }'

die() { echo "error: $*" >&2; exit 1; }

usage() {
  echo "usage: vpn-peer add <name> | remove <name> | list | client-params" >&2
  exit 1
}

check_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "bad client name '$1': 1-32 of A-Z a-z 0-9 - _"
}

check_key() {
  [[ "$2" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "bad $1 on stdin (expected 32 bytes in base64)"
}

# lock — waits for any other change of the conf, holds the lock until exit.
lock() {
  exec 9>"$CONF.lock"
  flock -x 9
}

has_name() {
  grep -qxF "# name: $1" "$CONF"
}

# free_ip — the lowest client IP of the awg0 subnet no peer holds. A peer's
# wider prefix (a hand-made one) holds every address in it.
free_ip() {
  awk "$AWK_KV"'
    function n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
    function ip(x) { return int(x / 16777216) "." int(x / 65536) % 256 "." int(x / 256) % 256 "." x % 256 }
    # take <a.b.c.d[/len]> — marks its addresses inside the subnet.
    function take(p,  a, len, size, lo, i) {
      if (p !~ /^[0-9.]+(\/[0-9]+)?$/) return # IPv6 or junk
      split(p, a, "/"); len = (a[2] == "") ? 32 : a[2] + 0
      size = 2 ^ (32 - len); lo = n(a[1]); lo -= lo % size
      for (i = (lo > net ? lo : net); i < lo + size && i <= last; i++) used[i] = 1
    }
    /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[[:space:]]/, "", sec); next }
    { kv($0) }
    sec == "[interface]" && k == "address" && cidr == "" {
      split(v, list, ","); cidr = list[1]; split(cidr, a, "/")
      # without it the loop below would walk all 2^32 addresses
      if (a[2] == "") { print "error: Address " cidr " in [Interface] has no prefix length" > "/dev/stderr"; bad = 1; exit 2 }
      size = 2 ^ (32 - a[2]); server = n(a[1]); net = server - server % size; last = net + size - 1
    }
    sec == "[peer]" && k == "allowedips" { peers[++np] = v }
    END {
      if (bad) exit 2
      if (cidr == "") { print "error: no Address in [Interface]" > "/dev/stderr"; exit 2 }
      used[server] = 1
      for (j = 1; j <= np; j++) { c = split(peers[j], list, ","); for (m = 1; m <= c; m++) take(list[m]) }
      for (i = net + 1; i < last; i++) if (!(i in used)) { print ip(i); exit 0 }
      print "error: no free IP in " cidr > "/dev/stderr"; exit 1
    }
  ' "$CONF"
}

# apply <new conf> — checks it, makes it the conf, syncs the live interface.
apply() {
  bash "$CHECK" "$1" || exit 1
  cp -p "$CONF" "$CONF.bak"
  chmod 600 "$1"
  mv -f "$1" "$CONF"
  if ! awg syncconf awg0 <(awg-quick strip awg0); then
    cp -p "$CONF.bak" "$CONF"
    die "awg syncconf failed; awg0.conf put back as it was"
  fi
}

cmd_add() {
  local name="$1" pub psk addr
  check_name "$name"
  read -r pub || true
  read -r psk || true
  check_key "public key" "$pub"
  check_key "PSK" "$psk"
  lock
  ! has_name "$name" || die "client $name already exists"
  # exact compare: base64 has + and /, which a regex would misread
  ! awk -v k="$pub" '{ l = $0; gsub(/[[:space:]]/, "", l) } tolower(l) ~ /^publickey=/ && substr(l, 11) == k { f = 1 } END { exit !f }' "$CONF" ||
    die "this public key is already in use"
  addr="$(free_ip)" || exit 1
  umask 077
  {
    cat "$CONF"
    printf '\n[Peer]\n# name: %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$psk" "$addr"
  } >"$CONF.tmp"
  apply "$CONF.tmp"
  echo "$addr"
}

cmd_remove() {
  local name="$1"
  check_name "$name"
  lock
  has_name "$name" || die "no client $name"
  umask 077
  # A [Peer] block runs to the next section; the one with the name line goes.
  awk -v tag="# name: $name" '
    function flush() { if (!hit) printf "%s", buf; buf = ""; hit = 0 }
    /^[[:space:]]*\[/ { flush(); peer = (tolower($0) ~ /^[[:space:]]*\[peer\]/) }
    peer { buf = buf $0 "\n"; if ($0 == tag) hit = 1; next }
    { print }
    END { flush() }
  ' "$CONF" >"$CONF.tmp"
  apply "$CONF.tmp"
}

cmd_list() {
  local now hs
  now="$(date +%s)"
  # a stopped interface has no handshakes: every client shows "never"
  hs="$(awg show awg0 latest-handshakes 2>/dev/null || true)"
  HS="$hs" awk -v now="$now" "$AWK_KV"'
    function ago(t,  d) {
      if (t + 0 == 0) return "never"
      d = now - t
      if (d < 60) return d "s ago"
      if (d < 3600) return int(d / 60) "m ago"
      if (d < 86400) return int(d / 3600) "h ago"
      return int(d / 86400) "d ago"
    }
    function out() { if (pub != "") printf "%-32s %-15s %s\n", name, addr, ago(hs[pub]); name = "-"; pub = ""; addr = "" }
    BEGIN { c = split(ENVIRON["HS"], l, "\n"); for (i = 1; i <= c; i++) { split(l[i], f, "\t"); hs[f[1]] = f[2] } }
    FNR == 1 { printf "%-32s %-15s %s\n", "NAME", "IP", "LAST HANDSHAKE" }
    /^[[:space:]]*\[/ { out(); next }
    /^# name: / { name = substr($0, 9); next }
    { kv($0) }
    k == "publickey" { pub = v }
    k == "allowedips" && addr == "" { split(v, a, ","); addr = a[1]; sub(/\/32$/, "", addr) }
    END { out() }
  ' "$CONF"
}

cmd_client_params() {
  local priv pub
  priv="$(sed -n 's/^[[:space:]]*[Pp]rivate[Kk]ey[[:space:]]*=[[:space:]]*//p' "$CONF" | head -1)"
  [[ -n "$priv" ]] || die "no PrivateKey in $CONF"
  pub="$(awg pubkey <<<"$priv")" # stdin: the key never shows in ps
  echo "PublicKey = $pub"
  # Every [Interface] key but the server's own; I1-I5 are kept commented on
  # the server (it does not send them) and become active for clients.
  awk '
    BEGIN { split("privatekey listenport address dns mtu table fwmark preup predown postup postdown saveconfig", a, " "); for (i in a) server[a[i]] = 1 }
    /^[[:space:]]*\[/ { inif = (tolower($0) ~ /^[[:space:]]*\[interface\]/); next }
    !inif { next }
    { line = $0; sub(/^[[:space:]]*/, "", line) }
    line ~ /^#[[:space:]]*[Ii][1-5][[:space:]]*=/ { sub(/^#[[:space:]]*/, "", line); print line; next }
    line == "" || line ~ /^#/ { next }
    { k = line; sub(/[[:space:]]*=.*/, "", k); if (!(tolower(k) in server)) print line }
  ' "$CONF"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
[[ -r "$CONF" ]] || die "$CONF is missing (run make deploy first)"
case "$cmd" in
  add) [[ $# -eq 2 ]] || usage; cmd_add "$2" ;;
  remove) [[ $# -eq 2 ]] || usage; cmd_remove "$2" ;;
  list) cmd_list ;;
  client-params) cmd_client_params ;;
  *) usage ;;
esac
