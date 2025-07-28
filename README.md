# 🛡️ Geo-fence

_Add country-based traffic filtering to your existing cloud firewall. Reduces noise and blocks unwanted regions._

## 🎯 What This Does

Adds geo-blocking as a **secondary security layer** on top of your cloud firewall. Downloads IP ranges for allowed countries and blocks NEW connections from everywhere else.

**Use case**: You already have a secure cloud firewall, now you want to add country-level filtering to reduce scanner traffic and geographic restrictions.

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
| `UPDATE_INTERVAL`   | How often to update (seconds)              | `604800` (7 days)    |

## 🔒 Security Notes

**Architecture**: Cloud Firewall (primary security) → Geo-fence (country filtering) → Your Services

**Important limitations:**
- IPv4 only (block IPv6 via cloud firewall)
- SSH stays globally accessible (secure via cloud firewall)
- VPNs/proxies in allowed countries bypass geo-blocking
- Requires `--cap-add=NET_ADMIN` and `--network=host`

**Best practice**: Use as additional layer alongside proper cloud firewall configuration.

## 🆘 Help

**View logs**: `docker logs geo-fence`

**Locked out?** (console access needed):
```bash
iptables -D INPUT -m set ! --match-set geo_fence_allow_v1 src -j DROP
```

## 🔧 Troubleshooting

**Traffic not being blocked?**

1. **Check ipset installed**: `ipset --version`
2. **Verify ipset has data**: `ipset list geo_fence_allow_v1 | head -10`
3. **Check iptables rules**: `iptables -L INPUT -n --line-numbers | head -5`

Should show: loopback ACCEPT, SSH ACCEPT, ESTABLISHED ACCEPT, geo-fence DROP
