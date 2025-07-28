# 🛡️ Geo-fence

_Add country-based traffic filtering to your existing cloud firewall. Reduces noise and blocks unwanted regions._

## 🎯 What This Does

Adds geo-blocking as a **secondary security layer** on top of your cloud firewall. Downloads IP ranges for allowed countries and blocks NEW connections from everywhere else.

**Universal Protection**: Automatically protects both host services AND all Docker containers with a single deployment.

**Use case**: You already have a secure cloud firewall, now you want to add country-level filtering to reduce scanner traffic and apply geographic restrictions across your entire server infrastructure.

## 🚀 Quick Start

**Prerequisites:**

- Secure cloud firewall configured (IPv6 blocked, SSH restricted to your IP)
- Install ipset: `apt install ipset` (Ubuntu/Debian) or `yum install ipset` (CentOS/RHEL)

**Deploy:**

```bash
docker run -d \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart unless-stopped \
  -e ALLOWED_COUNTRIES="se,ee,fi,de,nl" \
  --name geo-fence \
  ghcr.io/tlaanemaa/geo-fence:latest
```

Done! Your open ports now only accept traffic from those countries.

## ⚙️ Settings

| Variable            | What it does                               | Default              |
| ------------------- | ------------------------------------------ | -------------------- |
| `ALLOWED_COUNTRIES` | Countries that can access your server      | `se`                 |
| `IPSET_NAME`        | Internal name (change if running multiple) | `geo_fence_allow_v1` |
| `UPDATE_INTERVAL`   | How often to update IP ranges (seconds)    | `604800` (7 days)    |

## 🔒 Security Notes

**Architecture**: Cloud Firewall (primary security) → Geo-fence (country filtering) → Your Services (host + Docker)

**Important limitations:**

- IPv4 only (block IPv6 via cloud firewall)
- SSH stays globally accessible (secure via cloud firewall)
- VPNs/proxies in allowed countries bypass geo-blocking
- Requires `--cap-add=NET_ADMIN` and `--network=host`

**Docker Integration**: Automatically detects Docker and protects containers via DOCKER-USER chain when present. Works on systems with or without Docker. No container configuration changes needed.

**Best practice**: Use as an additional layer alongside proper cloud firewall configuration.

## 🆘 Help

**View logs**: `docker logs geo-fence`

**Locked out?** (console access needed):

```bash
# Remove host geo-fence rule
iptables -D INPUT -m set ! --match-set geo_fence_allow_v1 src -j DROP

# Remove Docker geo-fence rule (only if Docker is installed)
iptables -D DOCKER-USER -m set ! --match-set geo_fence_allow_v1 src -j DROP 2>/dev/null || true
```

## 🔧 Troubleshooting

**Traffic not being blocked?**

1. **Check ipset installed**: `ipset --version`
2. **Verify ipset has data**: `ipset list geo_fence_allow_v1 | head -10`
3. **Check host protection**: `iptables -L INPUT -n --line-numbers | head -5`
4. **Check Docker protection (if installed)**: `iptables -L DOCKER-USER -n --line-numbers 2>/dev/null || echo "Docker not detected"`
5. **Test your IP**: `ipset test geo_fence_allow_v1 $(curl -s ipinfo.io/ip)`

Should show: loopback ACCEPT, SSH ACCEPT, ESTABLISHED ACCEPT, geo-fence DROP

**For Docker containers**: Geo-fence rule should appear in the DOCKER-USER chain (only if Docker is installed).

**Multiple instances running?**

- Only run one geo-fence container per server
- If manually running the script, ensure no other instances are active
- The script is not designed for concurrent execution
