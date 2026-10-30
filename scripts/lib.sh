#!/usr/bin/env bash
# Shared helpers for scripts that talk to the two servers. Each one is
# described by its access file (host, port, user, optional password):
# secret/entry-access.yaml and secret/exit-access.yaml. ssh tries the key
# first (~/.ssh/id_*, the agent); a password in the file is only the fallback
# and goes to sshpass via the SSHPASS env var, never argv. No password in the
# file = key only. The files are read at call time, so sourcing this file
# needs none of them.

LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY_ACCESS="${ENTRY_ACCESS_FILE:-$LIB_ROOT/secret/entry-access.yaml}"
EXIT_ACCESS="${EXIT_ACCESS_FILE:-$LIB_ROOT/secret/exit-access.yaml}"

# need_access <file> — fails with a hint when the access file is missing.
need_access() {
  [[ -r "$1" ]] || { echo "error: $1 is missing (run: ./scripts/vpnctl.sh init)" >&2; return 1; }
}

# access_value <file> <key> — first value of <key> in an access file. A
# quoted value is taken as is up to its closing quote (a # in it stays);
# an unquoted one ends before a trailing ` # comment`.
access_value() {
  awk -v k="$2" '$1 == k":" {
    v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); q = substr(v, 1, 1)
    if (q == "\"" || q == "\047") { v = substr(v, 2); i = index(v, q); if (i) v = substr(v, 1, i - 1) }
    else { sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v) }
    print v; exit
  }' "$1"
}

# host_of <file> — the server's host.
host_of() {
  need_access "$1" || return 1
  access_value "$1" host
}

# new_keypair — prints "<private> <public>": a fresh X25519 pair in base64,
# made locally with openssl 3.
new_keypair() {
  local der priv pub
  der="$(openssl genpkey -algorithm X25519 -outform DER | base64)" || return 1
  priv="$(base64 -d <<<"$der" | tail -c 32 | base64)"
  pub="$(base64 -d <<<"$der" | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64)" || return 1
  echo "$priv $pub"
}

# copy_entry_package <dir> — the files scripts/deploy.sh uploads to the entry
# server (deploy/install_test.sh builds its package the same way).
copy_entry_package() {
  cp "$LIB_ROOT"/deploy/*.sh "$LIB_ROOT"/deploy/*.service "$LIB_ROOT"/deploy/*.timer "$LIB_ROOT"/deploy/*.conf \
    "$LIB_ROOT"/deploy/*.nft "$LIB_ROOT/deploy/exit/vpn-awg-exit.service" "$1/"
  rm "$1"/*_test.sh
}

# remote_to <file> <cmd...> — run a command on the server of that access file.
remote_to() {
  local file="$1"
  shift
  need_access "$file" || return 1
  local host port user password
  host="$(access_value "$file" host)"
  port="$(access_value "$file" port)"
  user="$(access_value "$file" user)"
  password="$(access_value "$file" password)" # not exported: only sshpass gets it
  [[ -n "$host" && -n "$user" ]] || { echo "error: no host or user in $file" >&2; return 1; }
  if [[ -n "$password" ]]; then
    local rc=0
    SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=15 -p "${port:-22}" "$user@$host" "$@" || rc=$?
    # sshpass can not answer ssh's questions; its own codes say what went wrong
    case "$rc" in
      5) echo "error: wrong password for $user@$host in $file" >&2 ;;
      6) echo "error: the host key of $host is not known yet. Connect once by hand and check the fingerprint: ssh -p ${port:-22} $user@$host" >&2 ;;
    esac
    return "$rc"
  else
    # BatchMode: fail at once instead of asking for a password nobody types
    ssh -o BatchMode=yes -o ConnectTimeout=15 -p "${port:-22}" "$user@$host" "$@"
  fi
}

remote_entry() { remote_to "$ENTRY_ACCESS" "$@"; }
remote_exit() { remote_to "$EXIT_ACCESS" "$@"; }
