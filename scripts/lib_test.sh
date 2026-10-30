#!/usr/bin/env bash
# Tests scripts/lib.sh `remote_entry` / `remote_exit` with fake ssh/sshpass on
# PATH: the ssh key is tried first, a password in the access file is only the
# fallback, and a file without a password means key-only (no prompt, no
# sshpass). No real server.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/testlib.sh"

mkdir "$TMP/bin"
# Both fakes log their argv; sshpass also logs the password it got in the env.
printf '#!/usr/bin/env bash\necho "ssh $*" >>"$CALLS"\n' >"$TMP/bin/ssh"
printf '#!/usr/bin/env bash\necho "sshpass $* | SSHPASS=${SSHPASS-<unset>}" >>"$CALLS"\n' >"$TMP/bin/sshpass"
chmod +x "$TMP/bin"/*
printf 'host: 10.0.0.1\nport: 2222\nuser: root\npassword: s3cret\n' >"$TMP/pw.yaml"
printf 'host: 10.0.0.2\nuser: admin\n# password: old-one\n' >"$TMP/key.yaml"

# run <entry access> <exit access> <function> — sources lib.sh and runs one command.
run() {
  : >"$TMP/calls"
  env -u SSHPASS CALLS="$TMP/calls" PATH="$TMP/bin:$PATH" ENTRY_ACCESS_FILE="$1" EXIT_ACCESS_FILE="$2" \
    bash -c 'source "$0/lib.sh" && "$1" uptime -p && echo "leaked=${SSHPASS-<unset>}"' "$DIR" "$3" 2>&1
}

out="$(run "$TMP/pw.yaml" "$TMP/key.yaml" remote_entry)"
check "entry, password in the file: sshpass, the password only in its env" \
  "sshpass -e ssh -o ConnectTimeout=15 -p 2222 root@10.0.0.1 uptime -p | SSHPASS=s3cret" "$(cat "$TMP/calls")"
check "the key is tried first (pubkey auth is not switched off)" "0" "$(grep -c 'PubkeyAuthentication=no' "$TMP/calls")"
check "the password is not exported to other commands" "leaked=<unset>" "$out"

run "$TMP/pw.yaml" "$TMP/key.yaml" remote_exit >/dev/null
check "exit, no password in the file: key only, never a prompt, default port" \
  "ssh -o BatchMode=yes -o ConnectTimeout=15 -p 22 admin@10.0.0.2 uptime -p" "$(cat "$TMP/calls")"
check "a commented password is not used" "0" "$(grep -c 'old-one' "$TMP/calls")"

out="$(run "$TMP/none.yaml" "$TMP/key.yaml" remote_entry)"
check "missing access file: fails, says which, no ssh" "1 0" \
  "$(grep -c "error: $TMP/none.yaml is missing" <<<"$out") $(grep -c . "$TMP/calls")"
printf 'port: 22\n' >"$TMP/nohost.yaml"
out="$(run "$TMP/nohost.yaml" "$TMP/key.yaml" remote_entry)"
check "no host in the file: fails, no ssh" "1 0" "$(grep -c "error: no host or user in $TMP/nohost.yaml" <<<"$out") $(grep -c . "$TMP/calls")"

check "host_of reads the host" "10.0.0.2" "$(ENTRY_ACCESS_FILE="$TMP/key.yaml" bash -c 'source "$0/lib.sh" && host_of "$ENTRY_ACCESS"' "$DIR")"

# sshpass can not ask about an unknown host key (exit 6) or a wrong password
# (exit 5): the user gets the reason and what to do, the exit code stays.
for c in 6 5; do
  printf '#!/usr/bin/env bash\nexit %s\n' "$c" >"$TMP/bin/sshpass"
  out="$(run "$TMP/pw.yaml" "$TMP/key.yaml" remote_entry)"
  rc="$(env -u SSHPASS PATH="$TMP/bin:$PATH" ENTRY_ACCESS_FILE="$TMP/pw.yaml" bash -c 'source "$0/lib.sh" && remote_entry true' "$DIR" 2>/dev/null; echo $?)"
  case "$c" in
    6) want="error: the host key of 10.0.0.1 is not known yet. Connect once by hand and check the fingerprint: ssh -p 2222 root@10.0.0.1" ;;
    5) want="error: wrong password for root@10.0.0.1 in $TMP/pw.yaml" ;;
  esac
  check "sshpass exit $c: explained, code kept" "1 $c" "$(grep -cxF "$want" <<<"$out") $rc"
done
printf '#!/usr/bin/env bash\necho "sshpass $* | SSHPASS=${SSHPASS-<unset>}" >>"$CALLS"\n' >"$TMP/bin/sshpass"

# host_of on a missing file: one clear line, not an awk error.
err="$(ENTRY_ACCESS_FILE="$TMP/none.yaml" bash -c 'source "$0/lib.sh" && host_of "$ENTRY_ACCESS"' "$DIR" 2>&1)"
check "host_of, missing file: fails with the init hint only" "1|error: $TMP/none.yaml is missing (run: ./scripts/vpnctl.sh init)" "$?|$err"

# Valid YAML people write: quotes and trailing comments.
printf 'host: "10.0.0.3"   # entry\nport: 2200 # ssh\nuser: '"'"'deploy'"'"'\npassword: "p # not a comment"\n' >"$TMP/quoted.yaml"
run "$TMP/quoted.yaml" "$TMP/key.yaml" remote_entry >/dev/null
check "quotes and comments stripped; a # inside quotes is kept" \
  "sshpass -e ssh -o ConnectTimeout=15 -p 2200 deploy@10.0.0.3 uptime -p | SSHPASS=p # not a comment" "$(cat "$TMP/calls")"

# new_keypair: "<private> <public>", both 32 bytes, the public one derived from the private one.
read -r priv pub <<<"$(bash -c 'source "$0/lib.sh" && new_keypair' "$DIR")"
pub_of() { { printf '302e020100300506032b656e04220420' | xxd -r -p; printf '%s' "$1" | base64 -d; } | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64; }
check "new_keypair: 32-byte keys, public matches private" "32 32 1" \
  "$(printf '%s' "$priv" | base64 -d | wc -c | tr -d ' ') $(printf '%s' "$pub" | base64 -d | wc -c | tr -d ' ') $([[ "$(pub_of "$priv")" == "$pub" ]] && echo 1)"

# copy_entry_package: what scripts/deploy.sh uploads, without the tests.
mkdir "$TMP/pkg"
bash -c 'source "$0/lib.sh" && copy_entry_package "$1"' "$DIR" "$TMP/pkg"
in_pkg() { [[ -f "$TMP/pkg/$1" ]] && echo 1 || echo 0; }
check "entry package: install.sh, vpn-peer, the exit unit, nft, no tests" "1 1 1 1 0" \
  "$(in_pkg install.sh) $(in_pkg vpn-peer.sh) $(in_pkg vpn-awg-exit.service) $(in_pkg vpn.nft) $(find "$TMP/pkg" -name '*_test.sh' | grep -c .)"

finish
