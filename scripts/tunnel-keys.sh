#!/usr/bin/env bash
# Creates secret/tunnel.yaml (keys, PSK, port, obfuscation) for the entry <-> exit
# tunnel. An existing file is never touched. TUNNEL_FILE overrides the path.
# Called by scripts/deploy-exit.sh and `vpnctl.sh init` only: `make deploy`
# refuses to run without the file instead of making keys the exit server does not know.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${TUNNEL_FILE:-$ROOT/secret/tunnel.yaml}"
[[ -e "$FILE" ]] && exit 0

# openssl 3 is needed for X25519 (macOS LibreSSL may lack it).
if ! openssl genpkey -algorithm X25519 >/dev/null 2>&1; then
  echo "openssl with X25519 support is required (try: brew install openssl)" >&2
  exit 1
fi

source "$ROOT/scripts/lib.sh"

rand() { echo $(( $(od -An -N4 -tu4 /dev/urandom) % ($2 - $1 + 1) + $1 )); } # modulo bias is irrelevant here

# keypair <prefix> — prints "<prefix>_private: ..." and "<prefix>_public: ...".
keypair() {
  local kp priv pub
  kp="$(new_keypair)" # an assignment, so set -e stops on failure
  read -r priv pub <<<"$kp"
  echo "$1_private: $priv"
  echo "$1_public: $pub"
}

# AmneziaWG wants S1 + 56 != S2; with both in 15..60 that always holds.
s1="$(rand 15 60)"
s2="$(rand 15 60)"
hs=()
while [[ ${#hs[@]} -lt 4 ]]; do
  h="$(rand 5 4294967295)"
  [[ " ${hs[*]:-} " == *" $h "* ]] || hs+=("$h")
done

psk="$(openssl rand -base64 32)" # an assignment, so set -e stops on failure

mkdir -p "$(dirname "$FILE")"
umask 077
trap 'rm -f "$FILE.tmp"' EXIT
{
  keypair ru
  keypair exit
  echo "psk: $psk"
  echo "port: $(rand 20000 60000)"
  echo "jc: $(rand 4 8)"
  echo "jmin: 40"
  echo "jmax: 70"
  echo "s1: $s1"
  echo "s2: $s2"
  for i in 0 1 2 3; do echo "h$((i + 1)): ${hs[$i]}"; done
} >"$FILE.tmp"
chmod 600 "$FILE.tmp"
mv "$FILE.tmp" "$FILE" # a failure above never leaves a partial tunnel.yaml
echo "created $FILE: NEW tunnel keys. Keep a copy; both servers must be deployed with this file."
