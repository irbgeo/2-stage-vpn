#!/usr/bin/env bash
# Tests deploy/vpn-peer.sh with ROOT=<tmp> and fake awg/awg-quick/flock on PATH.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../scripts/testlib.sh"

mkdir "$TMP/bin"
# awg: logs its args; `syncconf` also logs the conf it got (and waits
# $SYNC_DELAY, so two parallel runs overlap) and fails when $SYNC_FAIL is set;
# `pubkey` derives a fake key from stdin; `show` prints $HANDSHAKES.
cat >"$TMP/bin/awg" <<'X'
#!/usr/bin/env bash
echo "awg $*" >>"$CALLS"
case "$1" in
  syncconf) sleep "${SYNC_DELAY:-0}"; echo "--- synced:" >>"$CALLS"; cat "$3" >>"$CALLS"; [[ -z "${SYNC_FAIL:-}" ]] ;;
  pubkey) echo "PUB-OF-$(cat)" ;;
  show) printf '%b' "${HANDSHAKES:-}" ;;
esac
X
# awg-quick strip: prints the conf as it is on disk now.
printf '#!/usr/bin/env bash\necho "awg-quick $*" >>"$CALLS"\ncat "$ROOT/etc/amnezia/amneziawg/$2.conf"\n' >"$TMP/bin/awg-quick"
# flock -x <fd>: the same flock(2) as util-linux flock, through perl (macOS has no flock).
cat >"$TMP/bin/flock" <<'X'
#!/usr/bin/perl
use Fcntl qw(:flock);
open(my $fh, ">&=", $ARGV[-1]) or die "flock: fd $ARGV[-1]: $!";
flock($fh, LOCK_EX) or die "flock: $!";
X
chmod +x "$TMP/bin"/*

R="$TMP/root"
CONF="$R/etc/amnezia/amneziawg/awg0.conf"
mkdir -p "$(dirname "$CONF")"
SERVER='[Interface]
Address = 10.8.0.1/22
ListenPort = 443
MTU = 1380
PrivateKey = SERVERPRIVATE
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
# I1 = <b 0xc1000000010811>'
fresh() { printf '%s\n' "$SERVER" >"$CONF"; chmod 600 "$CONF"; }

KEY_A="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
KEY_B="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
PSK="PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP="
# vp <args...> — runs vpn-peer; stdin passes through. Output in $TMP/out, errors in $TMP/err.
vp() {
  env CALLS="$TMP/calls" ROOT="$R" CHECK="$DIR/awg0-check.sh" PATH="$TMP/bin:$PATH" \
    bash "$DIR/vpn-peer.sh" "$@" >"$TMP/out" 2>"$TMP/err"
}
# add <name> <pub> — adds a peer with the test PSK, prints vpn-peer's exit code.
add() { : >"$TMP/calls"; printf '%s\n%s\n' "$2" "$PSK" | vp add "$1"; echo $?; }
peers() { grep -c '^\[Peer\]' "$CONF"; }

# --- add
fresh
check "add to an empty conf: exits 0" "0" "$(add anna "$KEY_A")"
check "add: the first free IP is printed" "10.8.0.2" "$(cat "$TMP/out")"
check "add: the peer block" "[Peer]
# name: anna
PublicKey = $KEY_A
PresharedKey = $PSK
AllowedIPs = 10.8.0.2/32" "$(sed -n '/^\[Peer\]/,$p' "$CONF")"
check "add: the server part is kept" "$SERVER" "$(sed -n '1,/^# I1/p' "$CONF")"
check "add: conf stays root-only, the .bak is the old conf" "600 0" "$(mode "$CONF") $(grep -c '^\[Peer\]' "$CONF.bak")"
check "add: no .tmp left" "0" "$([[ -e "$CONF.tmp" ]] && echo 1 || echo 0)"
check "add: the live interface gets the new conf by syncconf (no restart)" "1 1 0" \
  "$(grep -c '^awg syncconf awg0 /dev/fd/' "$TMP/calls") $(grep -c "^PublicKey = $KEY_A" "$TMP/calls") $(grep -c 'awg-quick \(up\|down\)' "$TMP/calls")"
check "add: no secret in argv" "0" "$(grep -c "^awg.*\($KEY_A\|$PSK\)" "$TMP/calls")"

check "add a second: exits 0, next IP" "0 10.8.0.3" "$(add bob "$KEY_B") $(cat "$TMP/out")"
check "add the same name again: refused, nothing written" "1 2" "$(add anna "$KEY_A" | grep -c 1) $(peers)"
check "add the same name: says why" "1" "$(grep -c 'error: client anna already exists' "$TMP/err")"
check "add a used public key under another name: refused" "1 2" \
  "$(add carl "$KEY_A" | grep -c 1) $(peers)"

KEY_PLUS="A+/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
check "a key with + and /: added once" "0" "$(add dora "$KEY_PLUS")"
check "the same key with + and / again: refused (exact compare, no regex)" "1" "$(add eve "$KEY_PLUS")"

# A hole: the lowest free IP is taken again.
printf '%s\n\n[Peer]\n# name: x\nPublicKey = K1\nAllowedIPs = 10.8.0.2/32\n\n[Peer]\n# name: y\nPublicKey = K2\nAllowedIPs = 10.8.0.4/32\n' "$SERVER" >"$CONF"
add z "$KEY_A" >/dev/null
check "a hole: filled first" "10.8.0.3" "$(cat "$TMP/out")"
# A hand-made peer with a wider prefix holds all its addresses.
printf '%s\n\n[Peer]\nPublicKey = K1\nAllowedIPs = 10.8.0.0/29, fd00::1/128\n' "$SERVER" >"$CONF"
add z "$KEY_A" >/dev/null
check "a /29 peer: its addresses are taken" "10.8.0.8" "$(cat "$TMP/out")"
# A full network: every client IP 10.8.0.2 .. 10.8.3.254 is taken.
{
  printf '%s\n' "$SERVER"
  for a in 0 1 2 3; do for b in $(seq 0 255); do
    ip="10.8.$a.$b"
    [[ "$ip" == 10.8.0.0 || "$ip" == 10.8.0.1 || "$ip" == 10.8.3.255 ]] && continue
    printf '\n[Peer]\nPublicKey = K%s\nAllowedIPs = %s/32\n' "$ip" "$ip"
  done; done
} >"$CONF"
cp "$CONF" "$TMP/full"
check "full network: refused" "1" "$(add last "$KEY_A")"
check "full network: says why, conf untouched" "1 1" \
  "$(grep -c 'error: no free IP in 10.8.0.1/22' "$TMP/err") $(cmp -s "$CONF" "$TMP/full" && echo 1)"

# An Address without a prefix length (a hand edit): refused at once, not a 2^32 loop under the lock.
fresh
grep -v '^Address' "$CONF" >"$TMP/noaddr"
{ echo "[Interface]"; echo "Address = 10.8.0.1"; tail -n +2 "$TMP/noaddr"; } >"$CONF"
check "Address without /len: refused" "1" "$(add anna "$KEY_A")"
check "Address without /len: says why" "1" "$(grep -c 'error: Address 10.8.0.1 in \[Interface\] has no prefix length' "$TMP/err")"

# Names and keys.
fresh
for bad in "" "a b" "anna;id" "../x" "имя" "$(printf 'a%.0s' $(seq 33))"; do
  check "bad name '$bad': refused" "1" "$(add "$bad" "$KEY_A")"
done
check "bad name: nothing written" "0" "$(peers)"
check "name of 32 characters, - and _: accepted" "0" "$(add "$(printf 'a%.0s' $(seq 30))-_" "$KEY_A")"
fresh
: >"$TMP/calls"
printf 'not-a-key\n%s\n' "$PSK" | vp add anna
check "bad public key: refused" "1 0" "$? $(peers)"
printf '%s\n\n' "$KEY_A" | vp add anna
check "missing PSK: refused" "1 0" "$? $(peers)"

# syncconf fails: the conf goes back to what it was.
fresh
check "syncconf fails: add fails" "1" "$(SYNC_FAIL=1 add anna "$KEY_A")"
check "syncconf fails: conf restored" "0" "$(peers)"

# A hook line already in the conf: vpn-peer writes nothing.
fresh
echo "PostUp = id" >>"$CONF"
check "hook line in the conf: add refused" "1" "$(add anna "$KEY_A")"
check "hook line: nothing written, said why" "0 1" "$(peers) $(grep -c 'awg-quick would run it as root' "$TMP/err")"

# Two parallel adds: the lock gives them two different IPs.
fresh
SYNC_DELAY=0.3 add p1 "$KEY_A" >"$TMP/rc1" &
sleep 0.05
SYNC_DELAY=0.3 add p2 "$KEY_B" >"$TMP/rc2" &
wait
check "parallel adds: both succeed" "0 0" "$(cat "$TMP/rc1") $(cat "$TMP/rc2")"
check "parallel adds: two peers, two different IPs" "2 2" \
  "$(peers) $(grep '^AllowedIPs' "$CONF" | sort -u | wc -l | tr -d ' ')"

# --- remove
fresh
add anna "$KEY_A" >/dev/null
add bob "$KEY_B" >/dev/null
: >"$TMP/calls"
vp remove anna
check "remove: exits 0" "0" "$?"
check "remove: only that peer goes" "1 0 1" "$(peers) $(grep -c 'name: anna' "$CONF") $(grep -c 'name: bob' "$CONF")"
check "remove: the server part is kept" "$SERVER" "$(sed -n '1,/^# I1/p' "$CONF")"
check "remove: synced live" "1" "$(grep -c '^awg syncconf awg0' "$TMP/calls")"
check "remove: the freed IP is given out again" "10.8.0.2" "$(add carl "$KEY_A" >/dev/null; cat "$TMP/out")"
cp "$CONF" "$TMP/before"
vp remove nobody
check "remove a missing client: fails, says why, conf untouched" "1 1 1" \
  "$? $(grep -c 'error: no client nobody' "$TMP/err") $(cmp -s "$CONF" "$TMP/before" && echo 1)"
vp remove "a;b"
check "remove with a bad name: fails" "1" "$?"

# --- list
fresh
add anna "$KEY_A" >/dev/null
add bob "$KEY_B" >/dev/null
printf '\n[Peer]\nPublicKey = HAND\nAllowedIPs = 10.8.1.9/32\n' >>"$CONF"
now="$(date +%s)"
HANDSHAKES="$KEY_A\t$((now - 125))\n$KEY_B\t0\n" vp list
check "list: exits 0" "0" "$?"
check "list: name, IP, last handshake; a peer without a name shows -" "NAME                             IP              LAST HANDSHAKE
anna                             10.8.0.2        2m ago
bob                              10.8.0.3        never
-                                10.8.1.9        never" "$(cat "$TMP/out")"
# A hand-made peer with two AllowedIPs lines: the first one is shown.
fresh
printf '\n[Peer]\n# name: two\nPublicKey = TWO\nAllowedIPs = 10.8.2.1/32\nAllowedIPs = 10.8.2.2/32\n' >>"$CONF"
HANDSHAKES="" vp list
check "list: two AllowedIPs lines, the first is shown" "two                              10.8.2.1        never" "$(tail -1 "$TMP/out")"
fresh
add anna "$KEY_A" >/dev/null
add bob "$KEY_B" >/dev/null
printf '\n[Peer]\nPublicKey = HAND\nAllowedIPs = 10.8.1.9/32\n' >>"$CONF"
HANDSHAKES="" vp list
check "list: interface down (no handshakes): still lists" "0 3" "$? $(tail -n +2 "$TMP/out" | grep -c never)"

# --- client-params
fresh
: >"$TMP/calls"
vp client-params
check "client-params: exits 0" "0" "$?"
check "client-params: server public key, obfuscation, I1 un-commented, no server-only keys" "PublicKey = PUB-OF-SERVERPRIVATE
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
I1 = <b 0xc1000000010811>" "$(cat "$TMP/out")"
check "client-params: the server key is read from stdin, not argv" "0" "$(grep -c SERVERPRIVATE "$TMP/calls")"

# --- usage
vp
check "no command: fails" "1" "$?"
vp bogus
check "unknown command: fails" "1" "$?"
rm "$CONF"
vp list
check "no awg0.conf: fails, says why" "1 1" "$? $(grep -c 'error: .*awg0.conf is missing' "$TMP/err")"

finish
