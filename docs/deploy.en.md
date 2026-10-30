# How to deploy the VPN

Two servers: the **entry** server (clients connect to it) and the **exit** server (traffic leaves to the internet from it). Everything is installed from your computer over ssh. You do nothing by hand on the servers.

How the network works: [network.en.md](network.en.md).

## 1. Requirements

### Servers

| | Entry | Exit |
| --- | --- | --- |
| OS | clean Ubuntu 24.04 LTS | clean Ubuntu 24.04 LTS |
| Resources | 1 vCPU, 1 GB RAM or more | 1 vCPU, 1 GB RAM or more |
| Access | ssh user with password-less `sudo` | the same |
| Open in the cloud firewall | UDP 443 (clients), TCP 22 (ssh) | the tunnel UDP port (best: only from the entry IP), TCP 22 |

The tunnel port is random (20000–60000). It appears in `secret/tunnel.yaml` (line `port:`) after step 3.

If `ufw` is on, the deploy opens the needed ports in it (UDP 443 on the entry, the tunnel port on the exit). The cloud firewall is yours to open.

The deploy installs everything else (AmneziaWG kernel module, `awg`/`awg-quick`, `nftables`, `unbound`).

### Your computer

macOS or Linux with `bash`, `ssh`, `openssl` 3 (with X25519), `qrencode`, `shellcheck`, `make`. `sshpass` only if you log in with a password instead of a key.

On macOS:

```bash
brew install openssl qrencode shellcheck   # sshpass only for password login
```

## 2. Check the project

```bash
make test    # all script tests, no servers needed
make lint    # shellcheck
```

## 3. Keys and access

```bash
./scripts/vpnctl.sh init
```

It creates in `secret/` (not in git):

- `entry-access.yaml` and `exit-access.yaml` — access templates for the servers;
- `tunnel.yaml` — the keys of the tunnel between the servers, PSK, port, obfuscation;
- `clients/` — client configs go here.

Existing files are never touched.

Fill in both access files:

```yaml
host: 203.0.113.10
port: 22
user: deploy
# password: ...   # only without an ssh key
```

### Clients connect by a domain name

To let clients connect by a name (e.g. `vpn.example.com`) instead of an IP:

1. At your DNS provider, add an A record `vpn.example.com` → the entry server's IP.
2. Add to `secret/entry-access.yaml`:

   ```yaml
   endpoint: vpn.example.com
   ```

From then on `vpnctl.sh add` writes `Endpoint = vpn.example.com:443` into client configs. ssh and deploys still go to `host:`. Without `endpoint:`, clients get `host:`.

This lets you move the entry server without issuing new keys: move `awg0.conf` and change the A record. Configs already issued with an IP do not change by themselves: issue them again (`remove` + `add`).

The exit server can be a name too (`host:` in `exit-access.yaml`): the entry server then reaches the tunnel by that name.

The scripts try the ssh key first. A password is only the fallback: it goes to `sshpass` through an environment variable, never through arguments.

> **Keep a copy of `secret/`** in a safe place (password manager, encrypted archive). Without `tunnel.yaml` you can not rebuild the tunnel; without `clients/` you can not show old configs again.

## 4. Deploy the exit server

```bash
make deploy-exit
```

Installs the AmneziaWG module, builds `awg`/`awg-quick`, puts the tunnel config and the firewall (NAT, private networks blocked) in place and enables `vpn-awg-exit.service`. Prints the status at the end. Creates `tunnel.yaml` if it is missing.

Then open the tunnel UDP port (`port:` in `secret/tunnel.yaml`) in the cloud firewall, best only for the entry server's IP.

## 5. Deploy the entry server

```bash
make deploy
```

Order on the server: kernel tuning → AmneziaWG → nft and routes → `awg-exit` tunnel → `awg0` for clients (the server key is created on the first install only) → DNS (unbound) → `vpn-peer` → self-check timer.

At the end it prints the state of four services: `vpn-awg0`, `vpn-awg-exit`, `vpn-routes`, `unbound`. All must be `active`.

`make deploy` stops when `secret/tunnel.yaml` is missing: otherwise the entry server would get keys the exit server does not know.

## 6. Check

```bash
./scripts/vpnctl.sh status
```

Expected:

```
tunnel: handshake 12s ago
ip rule: ok
table 100: ok
fail-closed route: ok
external IP: 198.51.100.7
ok: traffic leaves from the exit server (198.51.100.7)
```

`external IP` must be the exit server's IP. If `exit-access.yaml` holds a host name instead of an IP, the command prints a WARNING — compare the addresses yourself.

## 7. Clients

| Task | Command |
| --- | --- |
| Issue a key | `./scripts/vpnctl.sh add anna` |
| Show the config and QR again | `./scripts/vpnctl.sh show anna` |
| Revoke a key | `./scripts/vpnctl.sh remove anna` |
| List (name, IP, last handshake) | `./scripts/vpnctl.sh list` |

Name: Latin letters, digits, `-` and `_`, up to 32 characters.

`add` makes the keys on your computer, sends only the public key and the PSK to the server, writes `secret/clients/anna.conf` and prints a QR code. The client installs **AmneziaVPN** and imports the file or scans the QR.

Adding and removing clients does not cut other clients.

## 8. Deploying again

You can run `make deploy` and `make deploy-exit` any number of times. They:

- never change keys (neither the tunnel's nor `awg0`'s);
- never touch the client list;
- never restart `awg0`;
- restart the tunnel and unbound only when their configs changed.

If `tunnel.yaml` changed: `make deploy-exit` first, then `make deploy`.

## 9. Troubleshooting

| Symptom | What to check |
| --- | --- |
| `make deploy-exit` fails at ssh | `exit-access.yaml`, the ssh key, password-less `sudo` |
| `status`: `tunnel: DOWN` | tunnel UDP port open on the exit; `make deploy-exit` passed; the same `tunnel.yaml` used for both deploys |
| `status`: `ip rule: MISSING` | the timer restores it within 15 s; if not — `systemctl status vpn-routes-check.timer` on the entry |
| Client connects, no internet | `status`; the client shows a handshake in AmneziaVPN; UDP 443 open on the entry |
| Client does not connect | UDP 443 open; the config was not cut when copied |

Useful commands on the entry server:

```bash
sudo awg show                      # both interfaces, handshakes
sudo vpn-peer list                 # clients
ip rule show; ip route show table 100
sudo nft list table inet vpn
journalctl -u vpn-routes-check -n 50
```
