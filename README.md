# 🛡️ Geo-fence

_Simple firewall that only allows traffic from specific countries. Blocks everything else!_

## 🚀 Quick Start

**Step 1: Secure SSH first**

- Configure your cloud firewall to restrict SSH (port 22) to your IP only
- Test that SSH still works
- **Why?** This geo-fence doesn't protect SSH (it's your safety net if the script breaks)

**Step 2: Deploy geo-fence**

```bash
docker run -d \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart unless-stopped \
  -e ALLOWED_COUNTRIES="se,ee,fi,de,nl" \
  --name geo-fence \
  ghcr.io/tlaanemaa/geo-fence:latest
```

Done! Your server now only accepts traffic from those countries.

_You can also just run the `geo-fence.sh` script directly on your system if you prefer._

## ⚙️ Settings

| Variable            | What it does                               | Default                       |
| ------------------- | ------------------------------------------ | ----------------------------- |
| `ALLOWED_COUNTRIES` | Countries that can access your server      | `se`                          |
| `IPSET_NAME`        | Internal name (change if running multiple) | `geo_fence_allowlist_ipv4_v1` |
| `UPDATE_INTERVAL`   | How often to update (seconds)              | `604800` (7 days)             |

## 🎯 How it works

1. Downloads IP ranges for your allowed countries
2. Blocks ALL traffic from everywhere else
3. **Exception**: SSH stays open globally (you secure it via cloud firewall)
4. Updates automatically every 7 days

**Result**: Only people from allowed countries can access your Minecraft server, web apps, APIs, etc.

## 🔒 Security Notes

**SSH Strategy**: We intentionally don't geo-fence SSH - it's your emergency access if things break. You handle SSH security via your cloud firewall.

**Other important stuff**:

- Only handles IPv4 (block IPv6 separately: `ip6tables -P INPUT DROP`)
- Needs `--cap-add=NET_ADMIN` and `--network=host`
- Immediate effect - existing connections from blocked countries get dropped
- Always have console access as backup!

## 🆘 Help

**View logs**: `docker logs geo-fence`

**Locked out?** (need console access):

```bash
iptables -D INPUT -m set ! --match-set geo_fence_allowlist_ipv4_v1 src -j DROP
```
