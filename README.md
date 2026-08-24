# Pterodactyl DDoS Mitigation by Syncara Cloud

Lightweight **per-port DDoS/flood mitigation** for Pterodactyl Wings nodes.

This project adds a local mitigation layer using **nftables** at network ingress. Traffic is evaluated **per destination port**, so an attack against one game-server allocation can be limited without applying the same limiter to every other customer port on the node.

> This project is intended as an additional local protection layer. It does **not** replace upstream DDoS filtering from your datacenter, transit provider, or hosting network.

## Features

- Per-destination-port mitigation
- TCP SYN flood protection
- Generic TCP packet flood protection
- UDP packet flood protection
- Uses nftables `netdev ingress` before Docker DNAT
- Reads existing **UFW port ranges** during installation
- Lets you select which UFW ranges should be protected
- Keeps TCP and UDP protection independent
- Automatic WAN interface detection
- Automatic IPv4 detection
- Interactive two-way setup wizard
- Discord webhook setup and live webhook test
- Discord attack and recovery embeds
- Recommended, Relaxed, Strict, and Custom protection profiles
- Automatic systemd startup
- Automatic restoration of the mitigation table if it disappears
- Firewall backup before installation
- Does not flush the entire nftables ruleset
- Does not remove Docker or UFW rules

## How it works

Example node:

```text
Public IP: 203.0.113.10

Client A -> TCP/25565
Client B -> UDP/19132
Client C -> TCP/25653
```

If only `TCP/25565` exceeds the configured threshold:

```text
TCP/25565 -> excess traffic dropped
UDP/19132 -> unaffected
TCP/25653 -> unaffected
```

The limiter key is the **destination port**, not the entire public IP.

For TCP SYN floods, established TCP sessions are not matched by the SYN-only limiter. A separate high-rate generic TCP ceiling is also available for packet floods.

## Requirements

Recommended environment:

- Debian 13
- Pterodactyl Wings
- Docker
- UFW
- nftables
- Root access

The installer automatically installs these runtime dependencies when needed:

- `nftables`
- `curl`
- `jq`
- `ca-certificates`
- `iproute2`

## Installation

Make the repository public if you want to use the raw GitHub installer without authentication.

Run:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/SukaSingkong/SyncGuard/main/install.sh)
```

Or download and execute it manually:

```bash
curl -sSL https://raw.githubusercontent.com/SukaSingkong/SyncGuard/main/install.sh -o install.sh
chmod +x install.sh
bash install.sh
```

## Interactive installer

The installer works as a two-way setup wizard.

Example:

```text
========================================
       PTERODACTYL DDoS MITIGATION
========================================

Server detected:
Hostname : node-01
WAN      : enp5s0
IPv4     : 203.0.113.10

Use interface enp5s0? [Y/n]:
Use IPv4 203.0.113.10? [Y/n]:

Enable Discord notifications? [Y/n]:
Discord Webhook:
```

The Discord webhook input is hidden from the terminal. The installer sends a test embed immediately and lets you retry if the webhook fails.

## UFW range selection

Pterodactyl installations commonly already have game allocation ranges allowed in UFW.

For example:

```text
20000:60000/tcp   ALLOW IN   Anywhere
20000:60000/udp   ALLOW IN   Anywhere
```

The installer detects those ranges and presents them as selectable protection targets:

```text
Port ranges found in UFW:

1) 20000-60000   [TCP + UDP]
2) 30000-40000   [TCP]
3) 50000-55000   [UDP]

M) Manual range

Select range to protect [1]:
```

Multiple ranges can be selected:

```text
1,2
```

TCP and UDP rules are generated separately according to the protocols actually allowed by UFW.

If no usable UFW range is found, the installer offers manual input.

## Protection profiles

The installer includes four profiles.

### Recommended

Designed as a reasonable starting point for general Minecraft hosting:

```text
TCP SYN:     1,500 packets/s per destination port
TCP packet: 50,000 packets/s per destination port
UDP packet: 20,000 packets/s per destination port
```

Burst values are automatically set to 2x the selected threshold.

### Relaxed

Higher thresholds for busier nodes.

### Strict

Lower thresholds for environments where traffic patterns are well understood.

### Custom

Lets the administrator enter all thresholds manually.

> Always tune thresholds using real production traffic. A value that is safe for one game or customer workload may be inappropriate for another.

## Discord notifications

Discord notifications are optional.

When an attack is detected, Syncara Cloud DDoS Mitigation sends an embed similar to:

```text
🚨 Flood Attack Detected

Node:        node-01
Public IP:   203.0.113.10
Target:      TCP/25565
Attack Type: TCP SYN Flood
Threshold:   > 1,500 SYN/s
Action:      Excess traffic dropped for this destination port
```

When the destination port returns below the configured threshold:

```text
✅ Attack Mitigated

Target: TCP/25565
Status: Normal
```

The webhook is stored locally in:

```text
/etc/ptero-guard.conf
```

with restrictive file permissions.

Never commit a real Discord webhook URL to GitHub.

## Commands

Show mitigation status:

```bash
ptero-guard status
```

Test the configured Discord webhook:

```bash
ptero-guard test
```

Reload nftables protection:

```bash
ptero-guard apply
```

Restart the service:

```bash
systemctl restart ptero-guard
```

Check service status:

```bash
systemctl status ptero-guard --no-pager
```

Follow service logs:

```bash
journalctl -u ptero-guard -f
```

Follow mitigation event logs:

```bash
journalctl -t ptero-guard -f
```

## Installed files

```text
/usr/local/sbin/ptero-guard
/etc/ptero-guard.conf
/etc/systemd/system/ptero-guard.service
/run/ptero-guard/
```

Firewall backups are stored in:

```text
/root/ptero-guard-backup/
```

## Default mitigation logic

The generated nftables table is named:

```text
netdev ptero_detect
```

It is attached to the detected WAN interface using `netdev ingress`.

The protection logic includes:

```text
TCP SYN flood
  -> rate calculated separately per TCP destination port
  -> excess SYN packets dropped

Generic TCP flood
  -> packet rate calculated separately per TCP destination port
  -> excess packets dropped

UDP flood
  -> packet rate calculated separately per UDP destination port
  -> excess packets dropped
```

The project does **not** intentionally run:

```bash
nft flush ruleset
```

because that could remove UFW and Docker-managed firewall rules.

## Docker / Pterodactyl note

Pterodactyl Wings uses Docker, and Docker normally DNATs public allocation ports to container addresses.

Syncara Cloud DDoS Mitigation attaches at network ingress so it can inspect the original public destination port **before Docker DNAT**.

This is useful for a hosting node where many game servers share one public IPv4 address but use different ports.

## Important limitations

This project protects the local server and individual destination ports. It cannot prevent an attack from saturating the physical network link before packets reach the server.

Example:

```text
Server uplink: 1 Gbps
Incoming attack: 5 Gbps
```

Even if nftables drops every malicious packet locally, the 1 Gbps uplink can already be saturated.

For production hosting, use:

```text
Upstream/provider DDoS filtering
            +
Pterodactyl DDoS Mitigation by Syncara Cloud
```

## Security notes

Do not commit any of the following:

- Discord webhook URLs
- database passwords
- private keys
- API tokens
- production `/etc/ptero-guard.conf`
- other server credentials

If a Discord webhook is accidentally exposed, regenerate it from Discord immediately.

## Uninstall

Run the installer again:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/SukaSingkong/SyncGuard/main/install.sh)
```

Then choose:

```text
Uninstall
```

The uninstaller removes only the Syncara Cloud mitigation service and its own nftables table. It does not intentionally remove UFW or Docker firewall rules.

## Project status

This project should be treated as a host-level mitigation layer that still requires real-world threshold tuning and testing for each production environment.

Before deploying broadly:

1. Test on a staging node or low-risk node.
2. Observe legitimate traffic.
3. Confirm there are no false positives.
4. Adjust thresholds as necessary.
5. Keep upstream DDoS mitigation enabled.

## License

Licensed under the **BSD 3-Clause License**.

See [`LICENSE`](LICENSE) for details.

---

**Pterodactyl DDoS Mitigation by Syncara Cloud**  
Per-port local mitigation for Pterodactyl hosting nodes.
