# 🛡️ Pterodactyl DDoS Mitigation

Unofficial per-port DDoS/flood mitigation scripts for **Pterodactyl Wings** nodes. Built for game-hosting environments where many customer servers share one public IP while using different allocation ports.

This project is not affiliated with or endorsed by the official Pterodactyl Project.

## Installation

To install, simply run the following command as **root**:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/SukaSingkong/pterodactyl-ddos-mitigation/main/install.sh)
```

The installer is interactive and will guide you through:

- WAN interface detection
- Public IPv4 detection
- Discord webhook configuration and live test
- Detection of existing UFW port ranges
- Selection of the port range(s) you want to protect
- Protection profile selection
- nftables validation
- systemd service installation

> **Note:** Run the command from a root shell. On some systems, placing `sudo` directly in front of a process-substitution command may not work as expected.

## Features

- Automatic installation of required dependencies.
- Automatic detection of the primary WAN interface.
- Automatic detection of the node's IPv4 address.
- Automatic discovery of Pterodactyl/game allocation ranges from UFW.
- Interactive selection of one or multiple UFW port ranges.
- Separate TCP and UDP protection based on the existing UFW rules.
- Per-destination-port TCP SYN flood mitigation.
- Per-destination-port generic TCP packet flood mitigation.
- Per-destination-port UDP flood mitigation.
- Protection applied at nftables `netdev ingress`, before Docker DNAT.
- Discord webhook notifications for attack detection.
- Discord webhook notifications when traffic returns to normal.
- Live Discord webhook validation during installation.
- Recommended, Relaxed, Strict, and Custom protection profiles.
- Automatic startup through systemd.
- Automatic restoration of the mitigation table if it disappears.
- Firewall backup before installation.
- Uninstallation support.
- Does not intentionally flush the complete nftables ruleset.
- Does not intentionally remove Docker or UFW firewall rules.

## Supported installations

This project is intended for Pterodactyl Wings nodes using Docker and nftables-compatible networking.

### Supported operating systems

| Operating System | Version | Supported |
| --- | ---: | :---: |
| Ubuntu | 14.04 | 🔴 |
| | 16.04 | 🔴 * |
| | 18.04 | 🔴 * |
| | 20.04 | 🔴 * |
| | 22.04 | ✅ |
| | 24.04 | ✅ |
| | 26.04 | ✅ |
| Debian | 8 | 🔴 * |
| | 9 | 🔴 * |
| | 10 | ✅ |
| | 11 | ✅ |
| | 12 | ✅ |
| | 13 | ✅ |
| CentOS | 6 | 🔴 |
| | 7 | 🔴 * |
| | 8 | 🔴 * |
| Rocky Linux | 8 | ✅ |
| | 9 | ✅ |
| AlmaLinux | 8 | ✅ |
| | 9 | ✅ |

`✅` = supported environment  
`🔴` = unsupported environment  
`*` = system is past End of Life (EOL)

The primary target is **Debian 13 (Trixie)**.

## How the protection works

Pterodactyl Wings publishes game-server allocation ports through Docker.

For example:

```text
Public IP: 203.0.113.10

Client A → TCP/25565
Client B → UDP/19132
Client C → TCP/25653
```

If Client A receives a flood on `TCP/25565`, the limiter for `25565` is evaluated independently:

```text
TCP/25565 → attack → excess traffic dropped
UDP/19132 → normal → unaffected
TCP/25653 → normal → unaffected
```

The limiter key is the **destination port**, not the entire public IP.

This is useful for hosting nodes where many customer servers share one IPv4 address.

## UFW integration

The installer reads existing UFW rules and searches for numeric port ranges.

Example UFW configuration:

```text
20000:60000/tcp   ALLOW IN   Anywhere
20000:60000/udp   ALLOW IN   Anywhere
```

The installer will present detected ranges interactively:

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

If no suitable UFW range is found, the installer offers manual configuration.

## Protection profiles

The installer provides several starting profiles.

### Recommended

Suitable as an initial profile for general Minecraft hosting:

```text
TCP SYN:      1,500 packets/s per destination port
TCP packets: 50,000 packets/s per destination port
UDP packets: 20,000 packets/s per destination port
```

Burst values are automatically configured at approximately twice the selected threshold.

### Relaxed

Higher thresholds for busy nodes or workloads with large legitimate traffic bursts.

### Strict

Lower thresholds for environments where normal traffic patterns are already well understood.

### Custom

Allows the administrator to define the thresholds manually.

> Thresholds should be tuned using actual production traffic. A safe threshold for one workload may be too aggressive or too permissive for another.

## Discord notifications

Discord integration is optional.

During installation, the wizard asks whether Discord notifications should be enabled.

The webhook URL is entered interactively and hidden from the terminal display.

The installer immediately sends a test embed. If the webhook fails, you can retry with another webhook or continue without Discord.

Example attack notification:

```text
🚨 Flood Attack Detected

Node:        node-01
Public IP:   203.0.113.10
Target:      TCP/25565
Attack Type: TCP SYN Flood
Threshold:   > 1,500 SYN/s
Action:      Excess traffic is being dropped for this destination port.
```

When the attack ends:

```text
✅ Attack Mitigated

Target: TCP/25565
Status: Normal
```

The webhook is stored locally in:

```text
/etc/ptero-guard.conf
```

Do not commit a real Discord webhook URL to this repository.

## Firewall behavior

The mitigation table is attached to the detected WAN interface using nftables `netdev ingress`.

This allows the original public destination port to be evaluated before Docker translates the traffic to a Pterodactyl container address.

The project manages its own nftables table:

```text
netdev ptero_detect
```

It does **not** intentionally execute:

```bash
nft flush ruleset
```

because doing so could remove rules managed by UFW, Docker, or other services.

## Commands

Show the current mitigation status:

```bash
ptero-guard status
```

Test Discord:

```bash
ptero-guard test
```

Re-apply the mitigation rules:

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

Follow attack/recovery event logs:

```bash
journalctl -t ptero-guard -f
```

## Installed files

The installer creates the following main files:

```text
/usr/local/sbin/ptero-guard
/etc/ptero-guard.conf
/etc/systemd/system/ptero-guard.service
/run/ptero-guard/
```

Firewall backups are stored under:

```text
/root/ptero-guard-backup/
```

## Uninstallation

Run the installer again:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/SukaSingkong/pterodactyl-ddos-mitigation/main/install.sh)
```

Then select:

```text
Uninstall
```

The uninstaller removes the Syncara Cloud mitigation service and its own nftables table.

It does not intentionally remove Docker or UFW rules.

## Important limitation

This is a **local mitigation layer**, not a replacement for upstream DDoS protection.

If a server has a `1 Gbps` uplink and receives a `5 Gbps` attack, the physical/network uplink can be saturated before local nftables rules have any opportunity to help other traffic.

Recommended production architecture:

```text
Upstream / Provider DDoS Filtering
              +
Pterodactyl DDoS Mitigation by Syncara Cloud
```

Use this project as an additional host-level protection layer behind your provider's filtering.

## Development & testing

Before deploying changes to a production hosting node:

1. Test the installer on a staging or low-risk node.
2. Confirm that UFW ranges are detected correctly.
3. Validate Discord notifications.
4. Observe legitimate game traffic.
5. Watch nftables drop counters for false positives.
6. Adjust protection thresholds as necessary.

Useful checks:

```bash
bash -n install.sh
```

and after installation:

```bash
nft list table netdev ptero_detect
```

## Security

Never commit:

- Discord webhook URLs
- database passwords
- API tokens
- private keys
- production copies of `/etc/ptero-guard.conf`
- other server credentials

If a webhook or credential is accidentally exposed, rotate it immediately.

## Contributors ✨

Created and maintained by **Syncara Cloud**.

Contributions, testing reports, bug reports, and improvements are welcome through GitHub Issues and Pull Requests.

## License

Licensed under the **BSD 3-Clause License**.

See [`LICENSE`](LICENSE) for the full license text.
