# How the network works

What happens to a client's packet on its way from the phone to a website and back, and which rules guard it. How to install: [deploy.en.md](deploy.en.md).

## 1. Overview

Interactive diagram: [diagrams/vpn-network.html](diagrams/vpn-network.html) (open in a browser).

```
 Client (AmneziaVPN), 10.8.0.X
     │  AmneziaWG 2.0, UDP 443, obfuscated
     ▼
 ┌──────────────────────────────────────────────┐
 │ Entry server                                 │
 │  awg0      10.8.0.1/22   ← clients           │
 │  unbound   10.8.0.1:53   ← clients' DNS      │
 │  nft inet vpn: mark 0x1, NAT, guards         │
 │  ip rule fwmark 0x1 → table 100              │
 │  awg-exit  10.255.255.1/30                   │
 └──────────────────────────────────────────────┘
     │  AmneziaWG 2.0, UDP <tunnel port>
     ▼
 ┌──────────────────────────────────────────────┐
 │ Exit server                                  │
 │  awg-exit  10.255.255.2/30                   │
 │  MASQUERADE for 10.255.255.1 only            │
 └──────────────────────────────────────────────┘
     │
     ▼
 Internet (sites see the exit server's IP)
```

The main idea: **clients have no direct way to the internet from the entry server**. Every client packet to the outside either goes into the `awg-exit` tunnel or is dropped.

## 2. Addresses and ports

| What | Value | Set in |
| --- | --- | --- |
| Client network | `10.8.0.0/22` (10.8.0.2 … 10.8.3.254, ~1020 clients) | `awg0.conf`, `vpn.nft`, `unbound-vpn.conf` |
| Entry server's VPN address | `10.8.0.1` | `awg0.conf` |
| Client port | UDP 443 | `awg0.conf` |
| Tunnel, entry side | `10.255.255.1/30` | `deploy/awg-exit.conf.tmpl` |
| Tunnel, exit side | `10.255.255.2/30` | `deploy/exit/awg-exit.conf.tmpl` |
| Tunnel port | random 20000–60000 | `secret/tunnel.yaml` |
| MTU of both interfaces | 1380 | the confs |
| Client packet mark | `0x1` | `vpn.nft` |
| Routing table | `100` | `vpn-routes.sh`, `awg-exit.conf` |
| `ip rule` priority | `110` | `vpn-routes.sh` |

## 3. A client packet's way to the internet

Example: client `10.8.0.5` opens `https://example.com` (`93.184.215.14`).

1. **Client.** AmneziaVPN encrypts the packet `10.8.0.5 → 93.184.215.14` and sends it over UDP to `<entry IP>:443`. Before the handshake the client sends junk packets (`Jc`, `Jmin`, `Jmax`, `I1`) and it disguises the headers (`S1`–`S4`, `H1`–`H4`), so DPI does not recognise WireGuard.
2. **Into `awg0`.** The kernel (module `amneziawg`) decrypts the packet. It appears on `awg0` with source `10.8.0.5`. The module checks that `10.8.0.5` is allowed for this peer (`AllowedIPs = 10.8.0.5/32`): a client can not fake another client's address.
3. **Mark (nft chain `pre`, prerouting).** The rule `iifname "awg0" ip daddr != 10.8.0.0/22 meta mark set 0x1` sets mark `0x1`. Packets inside the VPN network (to `10.8.0.1`) get no mark.
4. **Route lookup.** The rule `ip rule ... fwmark 0x1 lookup 100 prio 110` sends the marked packet to table 100. It holds two routes:
   - `default dev awg-exit` — the main one, added by the tunnel's `PostUp`;
   - `unreachable default metric 4096` — the fallback dead end, always there.

   While the tunnel is up, the first one wins (lower metric). When the tunnel goes down, its route goes away with the interface and only `unreachable` is left: the packet has nowhere to go.
5. **Checks (nft chain `vpn_forward`).** A packet from `awg0` is dropped when:
   - it is IPv6;
   - it has mark `0x1` but does not leave through `awg-exit` (so the `ip rule` is gone and the main table took the packet);
   - it goes to another client (`awg0 → awg0`);
   - it goes to a private network: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` (cloud metadata), `100.64.0.0/10`.
6. **NAT (nft chain `post`).** `oifname "awg-exit" masquerade` changes the source to `10.255.255.1`. The exit server knows only this address and nothing about clients.
7. **Tunnel.** `awg-exit` encrypts the packet `10.255.255.1 → 93.184.215.14` and sends it over UDP to `<exit IP>:<port>`. That UDP packet is made by the server itself: it has no mark and leaves through the main table and the normal interface (eth0).
8. **Exit server.** `awg-exit` decrypts the packet. The peer is allowed only with `10.255.255.1/32`. The rules of `exit-fw.sh` (iptables):
   - `FORWARD -i awg-exit -d <private networks> -j DROP` — the second lock against reaching the cloud's network;
   - `FORWARD -i awg-exit -j ACCEPT` and `RELATED,ESTABLISHED` replies back;
   - `POSTROUTING -s 10.255.255.1 -o <outer interface> -j MASQUERADE` — NAT for the entry server only; no other traffic can leave through this server;
   - TCP MSS clamp.
9. **Internet.** The site sees the exit server's IP.

### The way back

The site's reply comes to the exit server. Conntrack puts `10.255.255.1` back and sends the packet into `awg-exit`. On the entry server conntrack changes `10.255.255.1` back to `10.8.0.5`, and the packet goes into `awg0` to the client. `rp_filter = 2` (loose mode) keeps the kernel from dropping replies that come in through `awg-exit`.

## 4. DNS

1. The client conf has `DNS = 10.8.0.1`. `AllowedIPs = 0.0.0.0/0, ::/0` sends all client traffic into the VPN, IPv6 too (the server drops it, so IPv6 does not leak around the VPN).
2. A client query to `10.8.0.1:53` is for the entry server itself, so it passes chain `vpn_input`, which allows exactly DNS.
3. **unbound** listens only on `10.8.0.1` and answers only `10.8.0.0/22`. Upstream it asks Cloudflare (`1.1.1.1`, `1.0.0.1`) over DNS-over-TLS (port 853).
4. So that sites and dnsleaktest do not see the entry server's IP, **unbound's own queries also leave through the exit server**: chain `out` (type `route`, hook `output`) marks packets of user `unbound` with `0x1` (except `127.0.0.0/8` and `10.8.0.0/22`). A `route` chain makes the kernel look up the route again after the mark changed, so the packet goes to table 100 → `awg-exit`. Masquerade sets the source to `10.255.255.1`.
5. `do-ip6: no` — unbound does not use IPv6 (the tunnel is IPv4 only; an IPv6 query would leave from the entry IP).

Result: the resolver dnsleaktest sees is Cloudflare, reached from the exit server's IP. If the tunnel is down, DNS stops too (it does not leak).

## 5. Fail-closed: what happens when something breaks

| What broke | What happens |
| --- | --- |
| Tunnel `awg-exit` down | Route `default dev awg-exit` is gone, `unreachable` stays → clients have no internet, nothing leaves from the entry IP. The tunnel unit restarts itself (`Restart=on-failure`). |
| `ip rule` gone (e.g. `netplan apply`) | A marked packet falls to the main table and would leave via eth0, but `vpn_forward` drops it (mark `0x1`, exit not `awg-exit`). The timer puts the rule back within 15 s. |
| nft table gone (`nft flush ruleset`) | No table means no mark and no NAT. Unmarked client packets go to the main table, but without masquerade, with source `10.8.0.X`, they do not get through to the internet (the provider drops them, no reply comes back). The timer (`vpn-routes.sh rules`) loads the table again within 15 s. During those seconds the `vpn_forward`/`vpn_input` guards are off too. |
| systemd-networkd reconfigured a link | `networkd-vpn.conf` (`ManageForeignRoutingPolicyRules=no`, `ManageForeignRoutes=no`) stops it from deleting foreign rules and routes. |
| `nftables.service` started and flushed everything | `vpn-routes.service` has `After=nftables.service`; the timer restores the table anyway. |

**Self-check.** Every 15 s `vpn-routes-check.timer` runs `vpn-routes.sh rules`: it restores the `ip rule`, the `unreachable` route, the `awg-exit` route and the nft table when they are missing. Whenever it had to restore something it logs a warning: `journalctl -u vpn-routes-check`.

## 6. Guards of the entry server and the clients

Chain `vpn_input` (packets from clients to the server itself):

| What | Verdict |
| --- | --- |
| IPv6 | drop |
| replies to open connections | accept |
| DNS on `10.8.0.1:53` (TCP and UDP) | accept |
| ping | accept |
| everything else (ssh, any service, even on `0.0.0.0`) | drop |

A client that goes to the entry server's public IP also arrives from `awg0` and is closed by the same chain.

Chain `vpn_forward` (packets through the server) — see step 5 above: clients do not see each other, private networks and cloud metadata are closed.

## 7. Obfuscation (AmneziaWG 2.0)

| Parameter | Clients (`awg0`) | Tunnel (`awg-exit`) |
| --- | --- | --- |
| `Jc` (number of junk packets) | 4–8 | 4–8 |
| `Jmin`, `Jmax` (their size) | 40, 70 | 40, 70 |
| `S1`, `S2` (junk before the handshake) | 15–60 | 15–60 |
| `S3`, `S4` | 8–32 | 0 |
| `H1`–`H4` (packet type replacement) | non-overlapping ranges | four distinct numbers |
| `I1` (first packet, looks like a QUIC Initial) | commented on the server, active for clients | none |

The `awg0` parameters are made once (`awg0-init.sh`). Clients get them from `vpn-peer client-params`: only the obfuscation keys and the server's public key, never `PrivateKey`, `ListenPort`, `Address` or hooks. `I1` is 64–128 bytes so the conf fits a QR code.

The tunnel's parameters are in `secret/tunnel.yaml`, the same on both sides.

## 8. MTU and MSS

Both interfaces have MTU 1380: a packet plus the AmneziaWG headers fits the usual 1500 (or 1460 in a cloud) without fragments. TCP gets an MSS clamp: on the entry `vpn-mss.service` (for `awg0` and `awg-exit`), on the exit a rule in `exit-fw.sh`. UDP relies on the MTU in the client conf.

## 9. Clients and `awg0.conf`

- The only list of clients is `/etc/amnezia/amneziawg/awg0.conf` (root, 0600). Each client is a `[Peer]` block with a `# name: <name>` comment.
- Only `vpn-peer` (as root) changes it:
  1. takes a lock (`flock`), so two parallel `add` never get the same IP;
  2. checks the name and that it is free;
  3. takes the lowest free IP (holes after removals are reused);
  4. builds the new file and checks it with `awg0-check.sh` (no `PreUp`/`PostUp`/`PreDown`/`PostDown`/`SaveConfig` — awg-quick would run them as root);
  5. old file → `.bak`, new file → `.tmp` → `mv`;
  6. `awg syncconf awg0 <(awg-quick strip awg0)` applies the change to the live interface without a restart: other clients notice nothing. If `syncconf` fails, the file comes back from `.bak`.
- A client's private key is made on your computer and never reaches the server. The public key and the PSK go over ssh through stdin (not visible in `ps`).

## 10. Files on the servers

**Entry:**

| Path | What |
| --- | --- |
| `/etc/amnezia/amneziawg/awg0.conf` | client-facing server + all clients (made once) |
| `/etc/amnezia/amneziawg/awg-exit.conf` | the tunnel to the exit |
| `/etc/vpn/vpn.nft` | nft table `inet vpn` |
| `/opt/vpn/vpn-routes.sh`, `/opt/vpn/awg0-check.sh` | routes, conf check |
| `/usr/local/sbin/vpn-peer` | client changes |
| `/etc/unbound/unbound.conf.d/vpn.conf` | DNS |
| `/etc/sysctl.d/99-vpn.conf` | forwarding, rp_filter, conntrack size |
| `/etc/systemd/networkd.conf.d/vpn.conf` | networkd keeps foreign rules |
| units | `vpn-awg0`, `vpn-awg-exit`, `vpn-routes`, `vpn-routes-check.timer`, `vpn-mss` |

**Exit:**

| Path | What |
| --- | --- |
| `/etc/amnezia/amneziawg/awg-exit.conf` | the tunnel |
| `/usr/local/sbin/vpn-exit-fw.sh` | firewall and NAT (from `PostUp`/`PostDown`) |
| `/etc/sysctl.d/99-vpn.conf` | forwarding, conntrack |
| unit | `vpn-awg-exit` |

## 11. Diagnostics

On the entry server:

```bash
sudo awg show awg-exit latest-handshakes   # is the tunnel alive?
ip rule show prio 110                       # fwmark 0x1 lookup 100
ip route show table 100                     # default dev awg-exit + unreachable
sudo nft list table inet vpn                # marks, NAT, guards
curl --interface awg-exit ifconfig.me       # the IP traffic leaves from
sudo vpn-peer list                          # clients
```

On the exit server:

```bash
sudo awg show awg-exit
sudo iptables -t nat -S POSTROUTING
sudo iptables -S FORWARD
```
