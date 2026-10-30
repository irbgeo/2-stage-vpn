#!/usr/bin/env bash
# Tests scripts/vpnctl.sh with a fake ssh (logs argv and stdin, answers like
# the entry server) and a fake qrencode. No real server.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/testlib.sh"

mkdir "$TMP/bin"
cat >"$TMP/bin/ssh" <<'X'
#!/usr/bin/env bash
echo "ssh $*" >>"$CALLS"
cat >>"$STDIN_LOG"
[[ -z "${SSH_FAIL:-}" ]] || { echo "${SSH_ERR:-error: something broke}" >&2; exit 1; }
case "$*" in
  *"vpn-peer add"*) printf '10.8.0.5\nPublicKey = SERVERPUB\nJc = 5\nH1 = 1-2\nI1 = <b 0xc1>\n' ;;
  *"vpn-peer list"*) echo "NAME IP LAST HANDSHAKE" ;;
  *"vpn-peer remove"*) ;;
  *"bash -s"*) printf 'tunnel: handshake 5s ago\nexternal IP: %s\n' "${EXT_IP:-198.51.100.7}"; exit "${STATUS_RC:-0}" ;;
esac
X
printf '#!/usr/bin/env bash\necho "qrencode $*" >>"$CALLS"\ncat >/dev/null\necho QR\n' >"$TMP/bin/qrencode"
chmod +x "$TMP/bin"/*

S="$TMP/secret"
W="$TMP/work"
mkdir "$W"
# vc <args...> — runs vpnctl.sh in $W against the temp secret dir; output in
# $TMP/out. $ANSWER is typed at the "save a copy?" question (none: no input).
vc() {
  : >"$TMP/calls"
  : >"$TMP/stdin"
  printf '%s' "${ANSWER:-}" | (cd "$W" && env CALLS="$TMP/calls" STDIN_LOG="$TMP/stdin" PATH="$TMP/bin:$PATH" \
    ENTRY_ACCESS_FILE="$S/entry-access.yaml" EXIT_ACCESS_FILE="$S/exit-access.yaml" \
    TUNNEL_FILE="$S/tunnel.yaml" CLIENTS_DIR="$S/clients" \
    bash "$DIR/vpnctl.sh" "$@") >"$TMP/out" 2>&1
}

# --- init
vc init
check "init: exits 0" "0" "$?"
check "init: both access templates, the tunnel file, the clients dir" "600 600 600 700" \
  "$(mode "$S/entry-access.yaml") $(mode "$S/exit-access.yaml") $(mode "$S/tunnel.yaml") $(mode "$S/clients")"
check "init: template has host, port, user" "3" "$(grep -cE '^(host|port|user):' "$S/entry-access.yaml")"
check "init: entry template shows the endpoint option" "1" "$(grep -c '^# endpoint: ' "$S/entry-access.yaml")"
printf 'host: 203.0.113.10\nuser: deploy\n' >"$S/entry-access.yaml"
printf 'host: 198.51.100.7\nuser: deploy\n' >"$S/exit-access.yaml"
cp "$S/tunnel.yaml" "$TMP/tunnel.first"
vc init
check "init again: nothing replaced" "1 1" \
  "$(grep -c '^host: 203.0.113.10' "$S/entry-access.yaml") $(cmp -s "$S/tunnel.yaml" "$TMP/tunnel.first" && echo 1)"

# --- add
vc add anna
check "add: exits 0" "0" "$?"
C="$S/clients/anna.conf"
check "add: conf written, 600" "600" "$(mode "$C")"
check "add: one ssh call, vpn-peer add + client-params" "1 1" \
  "$(grep -c '^ssh' "$TMP/calls") $(grep -c 'vpn-peer add anna && vpn-peer client-params' "$TMP/calls")"
check "add: the conf has the IP, endpoint, server key, params" "1 1 1 1 1" \
  "$(grep -cx 'Address = 10.8.0.5/32' "$C") $(grep -cx 'Endpoint = 203.0.113.10:443' "$C") $(grep -cx 'PublicKey = SERVERPUB' "$C") $(grep -cx 'H1 = 1-2' "$C") $(grep -cx 'I1 = <b 0xc1>' "$C")"
priv="$(sed -n 's/^PrivateKey = //p' "$C")"
psk="$(sed -n 's/^PresharedKey = //p' "$C")"
pub_sent="$(sed -n 1p "$TMP/stdin")"
check "add: keys are 32 bytes" "32 32" "$(printf '%s' "$priv" | base64 -d | wc -c | tr -d ' ') $(printf '%s' "$psk" | base64 -d | wc -c | tr -d ' ')"
pub_of() { { printf '302e020100300506032b656e04220420' | xxd -r -p; printf '%s' "$1" | base64 -d; } | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64; }
check "add: the public key of the private one goes to the server, then the PSK" "$(pub_of "$priv")|$psk" "$pub_sent|$(sed -n 2p "$TMP/stdin")"
check "add: the private key never leaves this machine" "0" "$(grep -c "$priv" "$TMP/stdin")"
check "add: no secret in ssh argv" "0 0 0" "$(grep -cF "$priv" "$TMP/calls") $(grep -cF "$psk" "$TMP/calls") $(grep -cF "$pub_sent" "$TMP/calls")"
check "add: QR printed, the conf text is not" "1 1 0" \
  "$(grep -c '^qrencode -t ansiutf8' "$TMP/calls") $(grep -c '^QR$' "$TMP/out") $(grep -cF "$priv" "$TMP/out")"
check "add: asks to save, no answer: no copy here" "1 0" \
  "$(grep -c 'Save a copy to .*/anna.conf? \[y/N\]' "$TMP/out") $([[ -e "$W/anna.conf" ]] && echo 1 || echo 0)"

vc add anna
check "add an existing local name: refused, no ssh" "1 1 0" "$([[ $? -ne 0 ]] && echo 1) $(grep -c 'error: .*anna.conf already exists' "$TMP/out") $(grep -c '^ssh' "$TMP/calls")"
for bad in "a b" 'x;id' "" "$(printf 'a%.0s' $(seq 33))"; do
  vc add "$bad"
  check "add bad name '$bad': refused, no ssh" "1 0" "$([[ $? -ne 0 ]] && echo 1) $(grep -c '^ssh' "$TMP/calls")"
done
SSH_FAIL=1 vc add bob
check "add: server refuses: fails, no local conf" "1 0" "$([[ $? -ne 0 ]] && echo 1) $([[ -e "$S/clients/bob.conf" ]] && echo 1 || echo 0)"

# The server answers without client params: the client is on the server, no conf here; the user is told how to recover.
printf '#!/usr/bin/env bash\necho "ssh $*" >>"$CALLS"\ncat >/dev/null\necho 10.8.0.9\n' >"$TMP/bin/ssh-broken"
mv "$TMP/bin/ssh" "$TMP/bin/ssh-good"; mv "$TMP/bin/ssh-broken" "$TMP/bin/ssh"; chmod +x "$TMP/bin/ssh"
vc add carl
check "add: local conf fails: fails, no files, says how to recover" "1 0 1" \
  "$([[ $? -ne 0 ]] && echo 1) $(find "$S/clients" -name "carl*" | grep -c .) $(grep -c 'remove carl, then add it again' "$TMP/out")"
mv "$TMP/bin/ssh-good" "$TMP/bin/ssh"

# endpoint: in the entry access file: clients connect by that name, ssh still uses host.
mv "$TMP/bin/ssh-good" "$TMP/bin/ssh" 2>/dev/null || true
printf 'host: 203.0.113.10\nuser: deploy\nendpoint: vpn.example.com  # for clients\n' >"$S/entry-access.yaml"
vc add dan
check "endpoint set: clients get the domain, ssh goes to host" "0 1 1" \
  "$? $(grep -cx 'Endpoint = vpn.example.com:443' "$S/clients/dan.conf") $(grep -c 'deploy@203.0.113.10' "$TMP/calls")"
printf 'host: 203.0.113.10\nuser: deploy\n' >"$S/entry-access.yaml"

# --- show
vc show anna
check "show: QR, no ssh, no copy without yes" "0 1 0 0" "$? $(grep -c '^QR$' "$TMP/out") $(grep -c '^ssh' "$TMP/calls") $([[ -e "$W/anna.conf" ]] && echo 1 || echo 0)"
ANSWER=n vc show anna
check "show: answer n: no copy" "0 0" "$? $([[ -e "$W/anna.conf" ]] && echo 1 || echo 0)"
ANSWER=y vc show anna
check "show: answer y: the same conf saved here, 600" "0 1 600" "$? $(cmp -s "$C" "$W/anna.conf" && echo 1) $(mode "$W/anna.conf")"
echo old >"$W/anna.conf"
ANSWER=y vc show anna
check "show: a file is already here: not replaced, says so" "0 old 1" "$? $(cat "$W/anna.conf") $(grep -c 'already exists, not saved' "$TMP/out")"
rm "$W/anna.conf"
vc show nobody
check "show a missing client: fails" "1" "$([[ $? -ne 0 ]] && echo 1)"

# --- list
vc list
check "list: one ssh, vpn-peer list, its output shown" "0 1 1" "$? $(grep -c 'sudo vpn-peer list' "$TMP/calls") $(grep -c '^NAME' "$TMP/out")"

# --- remove
SSH_FAIL=1 vc remove anna
check "remove: server fails: fails, local conf kept" "1 1" "$([[ $? -ne 0 ]] && echo 1) $([[ -e "$C" ]] && echo 1)"
cp "$C" "$TMP/anna.copy"
vc remove anna
check "remove: exits 0, vpn-peer remove, local conf gone" "0 1 0" "$? $(grep -c 'sudo vpn-peer remove anna' "$TMP/calls") $([[ -e "$C" ]] && echo 1 || echo 0)"
# Already gone on the server: the local copy is cleaned up too.
cp "$TMP/anna.copy" "$C"
SSH_FAIL=1 SSH_ERR="error: no client anna" vc remove anna
check "remove: not on the server: exits 0, local conf gone, says so" "0 0 1" \
  "$? $([[ -e "$C" ]] && echo 1 || echo 0) $(grep -c 'anna was not on the server; local conf removed' "$TMP/out")"
vc remove 'x;id'
check "remove bad name: refused, no ssh" "1 0" "$([[ $? -ne 0 ]] && echo 1) $(grep -c '^ssh' "$TMP/calls")"

# --- status
vc status
check "status: exits 0, the check runs as root from stdin" "0 1" "$? $(grep -c 'sudo bash -s' "$TMP/calls")"
check "status: the check looks at the tunnel, the rule, table 100 and the exit IP" "1 1 1 1" \
  "$(grep -c 'latest-handshakes' "$TMP/stdin") $(grep -c 'ip rule show prio 110' "$TMP/stdin") $(grep -c 'ip route show table 100' "$TMP/stdin") $(grep -c 'curl.*--interface awg-exit' "$TMP/stdin")"
check "status: traffic leaves from the exit server" "1" "$(grep -c 'ok: traffic leaves from the exit server (198.51.100.7)' "$TMP/out")"
EXT_IP=203.0.113.10 vc status
check "status: another external IP: fails, says so" "1 1" "$([[ $? -ne 0 ]] && echo 1) $(grep -c 'WARNING: external IP 203.0.113.10 is not the exit server' "$TMP/out")"
STATUS_RC=1 vc status
check "status: a failed check fails" "1" "$([[ $? -ne 0 ]] && echo 1)"

# --- usage
vc
check "no command: usage, fails" "1 1" "$([[ $? -ne 0 ]] && echo 1) $(grep -c '^usage' "$TMP/out")"
vc bogus
check "unknown command: fails" "1" "$([[ $? -ne 0 ]] && echo 1)"

finish
