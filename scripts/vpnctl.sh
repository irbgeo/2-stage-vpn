#!/usr/bin/env bash
# vpnctl.sh — VPN clients from this machine. Deploys are `make deploy-exit`
# and `make deploy`.
#
#   init            access file templates + secret/tunnel.yaml (keeps existing files)
#   add <name>      new client: secret/clients/<name>.conf + QR (Endpoint =
#                   `endpoint:` of the entry access file, else its `host:`)
#   show <name>     the conf and QR of a client again (local copy, no ssh)
#   remove <name>   delete the client on the server and its local conf
#   list            clients on the server: name, IP, last handshake
#   status          tunnel, routing rule, table 100, external IP via the exit
#
# The source of truth is awg0.conf on the entry server (vpn-peer); the local
# confs are only copies. Client keys are made here; only the public key and
# the PSK go to the server, through stdin. One ssh call per command.
set -euo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
CLIENTS="${CLIENTS_DIR:-$ROOT/secret/clients}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  echo "usage: $0 init | add <name> | show <name> | remove <name> | list | status" >&2
  exit 1
}

# check_name — the same rule as vpn-peer; also keeps the name safe in the ssh command.
check_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "bad client name '$1': 1-32 of A-Z a-z 0-9 - _"
}

# access_template <file> [extra lines...] — writes an access file to fill
# in, unless one exists.
access_template() {
  local file="$1"
  shift
  [[ -e "$file" ]] && return 0
  printf '%s\n' "host: 203.0.113.10" "port: 22" "user: deploy" \
    "# password: ...   # only without an ssh key; goes to sshpass through env" "$@" >"$file"
  chmod 600 "$file"
  echo "created $file: fill in host and user"
}

cmd_init() {
  umask 077
  mkdir -p "$(dirname "$ENTRY_ACCESS")" "$(dirname "$EXIT_ACCESS")" "$CLIENTS"
  chmod 700 "$CLIENTS"
  access_template "$ENTRY_ACCESS" \
    "# endpoint: vpn.example.com   # name clients connect to (an A record to the entry IP); default: host"
  access_template "$EXIT_ACCESS"
  "$ROOT/scripts/tunnel-keys.sh"
}

# show_conf <file> — the conf and its QR code.
show_conf() {
  cat "$1"
  echo
  qrencode -t ansiutf8 <"$1"
  echo "saved in $1"
}

cmd_add() {
  local name="$1" kp priv pub psk out addr params host endpoint conf
  check_name "$name"
  conf="$CLIENTS/$name.conf"
  [[ ! -e "$conf" ]] || die "$conf already exists (show it: $0 show $name)"
  # clients connect to `endpoint:` (a domain) when it is set, else to `host:`
  host="$(host_of "$ENTRY_ACCESS")"
  [[ -n "$host" ]] || die "no host in $ENTRY_ACCESS"
  endpoint="$(access_value "$ENTRY_ACCESS" endpoint)"
  host="${endpoint:-$host}"
  kp="$(new_keypair)" || die "openssl with X25519 is needed (brew install openssl)"
  read -r priv pub <<<"$kp"
  psk="$(openssl rand -base64 32)"

  out="$(printf '%s\n%s\n' "$pub" "$psk" | remote_entry "sudo sh -c 'vpn-peer add $name && vpn-peer client-params'")"
  addr="$(head -1 <<<"$out")"
  params="$(tail -n +2 <<<"$out")"

  mkdir -p "$CLIENTS"
  chmod 700 "$CLIENTS"
  if ! (umask 077 && CLIENT_PRIVATE_KEY="$priv" CLIENT_PSK="$psk" "$ROOT/scripts/client-conf.sh" "$addr" "$host" <<<"$params" >"$conf.tmp"); then
    rm -f "$conf.tmp"
    die "$name was added on the server, but its local conf was not built. Run: $0 remove $name, then add it again"
  fi
  mv "$conf.tmp" "$conf"
  show_conf "$conf"
}

cmd_show() {
  check_name "$1"
  [[ -r "$CLIENTS/$1.conf" ]] || die "no $CLIENTS/$1.conf"
  show_conf "$CLIENTS/$1.conf"
}

cmd_remove() {
  local err
  check_name "$1"
  if ! err="$(remote_entry "sudo vpn-peer remove $1" </dev/null 2>&1)"; then
    # gone on the server already: the local copy is the only thing left
    if [[ "$err" == *"error: no client $1"* && -e "$CLIENTS/$1.conf" ]]; then
      rm -f "$CLIENTS/$1.conf"
      echo "$1 was not on the server; local conf removed"
      return 0
    fi
    die "${err#error: }"
  fi
  rm -f "$CLIENTS/$1.conf"
  echo "removed $1"
}

# status_script — the check that runs as root on the entry server (stdin of
# `bash -s`). Exit 1 when anything is wrong.
status_script() {
  cat <<'EOF'
bad=0
hs=$(awg show awg-exit latest-handshakes 2>/dev/null | awk '{print $2; exit}')
if [ -z "$hs" ] || [ "$hs" = 0 ]; then
  echo "tunnel: DOWN (no handshake)"; bad=1
else
  age=$(( $(date +%s) - hs ))
  if [ "$age" -gt 180 ]; then echo "tunnel: STALE (last handshake ${age}s ago)"; bad=1; else echo "tunnel: handshake ${age}s ago"; fi
fi
if ip rule show prio 110 | grep 'fwmark 0x1 lookup 100' >/dev/null; then echo "ip rule: ok"; else echo "ip rule: MISSING"; bad=1; fi
t=$(ip route show table 100)
case "$t" in *"default dev awg-exit"*) echo "table 100: ok" ;; *) echo "table 100: no route to awg-exit"; bad=1 ;; esac
case "$t" in *unreachable*) echo "fail-closed route: ok" ;; *) echo "fail-closed route: MISSING"; bad=1 ;; esac
ip=$(curl -4 -s --max-time 10 --interface awg-exit https://ifconfig.me || true)
echo "external IP: ${ip:-none}"
[ -n "$ip" ] || bad=1
exit $bad
EOF
}

cmd_status() {
  local out rc=0 ext exit_host
  exit_host="$(host_of "$EXIT_ACCESS")"
  out="$(status_script | remote_entry "sudo bash -s")" || rc=$?
  echo "$out"
  ext="$(sed -n 's/^external IP: //p' <<<"$out")"
  if [[ "$ext" == "$exit_host" ]]; then
    echo "ok: traffic leaves from the exit server ($exit_host)"
  else
    echo "WARNING: external IP $ext is not the exit server ($exit_host)"
    rc=1
  fi
  return "$rc"
}

cmd="${1:-}"
case "$cmd" in
  init) [[ $# -eq 1 ]] || usage; cmd_init ;;
  add) [[ $# -eq 2 ]] || usage; cmd_add "$2" ;;
  show) [[ $# -eq 2 ]] || usage; cmd_show "$2" ;;
  remove) [[ $# -eq 2 ]] || usage; cmd_remove "$2" ;;
  list) [[ $# -eq 1 ]] || usage; remote_entry "sudo vpn-peer list" </dev/null ;;
  status) [[ $# -eq 1 ]] || usage; cmd_status ;;
  *) usage ;;
esac
