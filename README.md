# 2-stage-vpn

A two-server VPN on AmneziaWG 2.0. Clients connect to the **entry** server; all their traffic goes through a tunnel to the **exit** server and from there to the internet. Sites see the exit server's IP. If the tunnel is down, clients have no internet (traffic never leaves straight from the entry server).

There is no bot and no database: servers and clients are managed by scripts from your computer.

- How to deploy: [docs/deploy.en.md](docs/deploy.en.md) · [Русский](docs/deploy.ru.md)
- How the network works: [docs/network.en.md](docs/network.en.md) · [Русский](docs/network.ru.md)
- Diagram (open in a browser): [docs/diagrams/vpn-network.html](docs/diagrams/vpn-network.html)

## Set up from scratch

```bash
./scripts/vpnctl.sh init      # access templates + secret/tunnel.yaml
$EDITOR secret/entry-access.yaml secret/exit-access.yaml
make deploy-exit              # the exit server first
make deploy                   # then the entry server
./scripts/vpnctl.sh status    # tunnel is up, external IP = exit server's IP
```

In the cloud firewall open: on the entry server UDP 443 and TCP 22; on the exit server the tunnel UDP port (`port:` in `secret/tunnel.yaml`, best only from the entry server's IP) and TCP 22.

To let clients connect by a domain name instead of the IP, point an A record at the entry server and add `endpoint: vpn.example.com` to `secret/entry-access.yaml` (details: [docs/deploy.en.md](docs/deploy.en.md)).

## Issue a key

```bash
./scripts/vpnctl.sh add anna  # secret/clients/anna.conf and a QR code in the terminal
```

The client installs **AmneziaVPN** and imports the `.conf` file or scans the QR code.

## Other commands

```bash
./scripts/vpnctl.sh show anna     # QR code of an existing client again (+ the same question)
./scripts/vpnctl.sh remove anna   # revoke the key
./scripts/vpnctl.sh list          # name, IP, last handshake
make test                         # tests
make lint                         # shellcheck
```

## Important

- The `secret/` folder exists only on your computer (it is not in git). **Keep a copy**: without `tunnel.yaml` you can not rebuild the tunnel.
- Running `make deploy` / `make deploy-exit` again is safe: keys and clients do not change, `awg0` is not restarted.
- Adding or removing a client does not cut other clients.
