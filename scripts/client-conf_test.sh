#!/usr/bin/env bash
# Tests scripts/client-conf.sh: the client conf from `vpn-peer client-params`
# output and the client's own keys.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/testlib.sh"

PARAMS='PublicKey = SERVERPUB
Jc = 5
Jmin = 40
Jmax = 70
S1 = 20
S2 = 30
S3 = 10
S4 = 12
H1 = 100-200
H2 = 300-400
H3 = 500-600
H4 = 700-800
I1 = <b 0xc1000000010811>'
run() { CLIENT_PRIVATE_KEY=CPRIV CLIENT_PSK=CPSK bash "$DIR/client-conf.sh" "$@"; }

out="$(run 10.8.0.7 203.0.113.10 <<<"$PARAMS")"
check "exits 0" "0" "$?"
check "the whole conf" "[Interface]
PrivateKey = CPRIV
Address = 10.8.0.7/32
DNS = 10.8.0.1
MTU = 1380
Jc = 5
Jmin = 40
Jmax = 70
S1 = 20
S2 = 30
S3 = 10
S4 = 12
H1 = 100-200
H2 = 300-400
H3 = 500-600
H4 = 700-800
I1 = <b 0xc1000000010811>

[Peer]
PublicKey = SERVERPUB
PresharedKey = CPSK
Endpoint = 203.0.113.10:443
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25" "$out"

# Only obfuscation keys pass: a server key that slipped into the params never reaches a client.
out="$(run 10.8.0.7 h <<<"$PARAMS
PrivateKey = SERVERPRIV
ListenPort = 443
PostUp = id
Address = 10.8.0.1/22")"
check "server-only keys dropped" "0" "$(grep -c 'SERVERPRIV\|ListenPort\|PostUp\|10.8.0.1/22' <<<"$out")"

run 10.8.0.7 h <<<"Jc = 5" >/dev/null 2>&1
check "no server public key: fails" "1" "$?"
CLIENT_PSK=x bash "$DIR/client-conf.sh" 10.8.0.7 h <<<"$PARAMS" >/dev/null 2>&1
check "no client private key: fails" "1" "$?"
run 10.8.0.7 <<<"$PARAMS" >/dev/null 2>&1
check "no endpoint: fails" "1" "$?"
run not-an-ip h <<<"$PARAMS" >/dev/null 2>&1
check "bad IP: fails" "1" "$?"

finish
