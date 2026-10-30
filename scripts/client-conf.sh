#!/usr/bin/env bash
# client-conf.sh <client IP> <entry host> — prints a client's AmneziaWG conf.
# stdin: the output of `vpn-peer client-params` (the server public key and
# its obfuscation keys). The client's secrets come from the environment
# (CLIENT_PRIVATE_KEY, CLIENT_PSK), never argv. Only obfuscation keys are
# copied: nothing else of the server's conf can reach a client.
set -euo pipefail
addr="${1:-}"
host="${2:-}"
[[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && -n "$host" ]] || { echo "usage: $0 <client IP> <entry host>" >&2; exit 1; }
[[ -n "${CLIENT_PRIVATE_KEY:-}" && -n "${CLIENT_PSK:-}" ]] || { echo "error: CLIENT_PRIVATE_KEY and CLIENT_PSK must be set" >&2; exit 1; }

params="$(cat)"
server_pub="$(sed -n 's/^PublicKey = //p' <<<"$params" | head -1)"
[[ -n "$server_pub" ]] || { echo "error: no server PublicKey in the client params" >&2; exit 1; }

echo "[Interface]"
echo "PrivateKey = $CLIENT_PRIVATE_KEY"
echo "Address = $addr/32"
echo "DNS = 10.8.0.1"
echo "MTU = 1380"
grep -E '^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]) = ' <<<"$params" || true
echo
echo "[Peer]"
echo "PublicKey = $server_pub"
echo "PresharedKey = $CLIENT_PSK"
echo "Endpoint = $host:443"
# ::/0 keeps the client's IPv6 inside the VPN (the server drops it)
echo "AllowedIPs = 0.0.0.0/0, ::/0"
echo "PersistentKeepalive = 25"
