# 🛡️ Geo-fence

**The simple, containerized firewall that blocks traffic from unwanted countries.**

Geo-fence automatically blocks all incoming IPv4 traffic except from countries you explicitly allow. It runs in a lightweight Docker container, protecting both the host system and other Docker containers with zero configuration.

It's the perfect tool to:

- **Reduce attack surface:** Block scanners and bots from entire regions.
- **Enforce compliance:** Restrict access based on geographic requirements.
- **Clean up logs:** Eliminate noise from unauthorized sources.

⚠️ **Before You Start**

- **Secure Your SSH Port:** Geo-fence intentionally leaves port 22 open to prevent lockouts. You **must** secure SSH yourself using a firewall and strong (key-based) authentication.
- **IPv4 Only:** This tool does not block IPv6 traffic. If your server has an IPv6 address, you must secure it separately at your cloud provider's firewall.
- **This Is One Layer:** Geo-fence reduces your attack surface but is not a complete security solution. Use it as part of a layered defense strategy.

## Key Features

- **Automatic Country Blocking:** Creates a firewall that only allows traffic from the countries you specify in `ALLOWED_COUNTRIES`.
- **Host & Container Protection:** The firewall applies to the host's network and all Docker containers, providing universal protection.
- **Zero-Downtime Updates:** IP lists are updated atomically in the background, ensuring your services are never interrupted.
- **Lockout Prevention:** SSH (port 22) is always permitted, so you never lose access to your server.

## Quick Start

**1. Prerequisite:**
`ipset` must be installed on the host.

```bash
# Ubuntu/Debian
apt-get update && apt-get install -y ipset

# CentOS/RHEL
yum install -y ipset
```

**2. Deploy:**
Update `ALLOWED_COUNTRIES` with the 2-letter codes of countries you want to allow.

```bash
docker run -d \
  --name geo-fence \
  --restart unless-stopped \
  --network=host \
  --cap-add=NET_ADMIN \
  -e ALLOWED_COUNTRIES="us,ca,gb" \
  ghcr.io/tlaanemaa/geo-fence:latest
```

**3. Verify:**
You can check the logs to see the firewall being built.

```bash
docker logs geo-fence
```

## How It Works

Geo-fence uses `ipset` and `iptables` to create an efficient, high-performance firewall.

1.  **Fetch:** It downloads the latest IP address ranges for your allowed countries from `ipdeny.com`.
2.  **Build:** It creates a temporary `ipset` with the new IP ranges.
3.  **Swap:** It atomically swaps the old IP set with the new one, ensuring zero downtime.
4.  **Enforce:** An `iptables` rule directs all incoming and forwarded traffic through the filter, dropping any packets from sources not in the `ipset`.

This process repeats automatically every 7 days to keep the IP lists current.

## Configuration

| Environment Variable | Description                                     | Default           |
| -------------------- | ----------------------------------------------- | ----------------- |
| `ALLOWED_COUNTRIES`  | Comma-separated list of 2-letter country codes. | `se`              |
| `UPDATE_INTERVAL`    | How often to update IP lists, in seconds.       | `604800` (7 days) |

## Troubleshooting

#### Emergency Unlock

If you are locked out, connect to your server via a recovery console (e.g., VNC or a cloud provider console) and run these commands to disable the firewall rules:

```bash
iptables -D INPUT -j GEO-FENCE-CHECK 2>/dev/null || true
iptables -D FORWARD -j GEO-FENCE-CHECK 2>/dev/null || true
```

#### Common Issues

- **Traffic not being blocked?** Check the logs (`docker logs geo-fence`) to ensure the correct IP ranges were loaded. Use `ipset list geo_fence` to inspect the active list.
- **`ipset` not found?** Ensure `ipset` is installed on the host machine.
- **Cloud firewall conflicts:** Remember that this firewall runs _on your server_. If a cloud firewall is blocking traffic before it reaches your server, Geo-fence won't see it.
