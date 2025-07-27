# 🛡️ Geo-fence

Production-ready geo-fencing firewall that blocks all IPv4 traffic _except_ from specific countries using ipset + iptables. It does **not** handle IPv6 traffic.

Runs inside a Docker container with automatic updates, health monitoring, graceful shutdowns, and comprehensive error handling.

---

## 🔧 Setup

1. **Clone the repo or copy these files:**

   - `geo-fence.sh`
   - `entrypoint.sh`
   - `Dockerfile`

2. **Build the image:**

```bash
docker build -t geo-fence .
```

3. **Run it:**

```bash
docker run -d \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart unless-stopped \
  -e ALLOWED_COUNTRIES="se,ee,fi,de,nl" \
  -e IPSET_NAME="geo_fence_allowlist_ipv4_v1" \
  --name geo-fence \
  geo-fence
```

---

## ⚙️ Environment variables

| Variable | Description | Default |
| --- | --- | --- |
| `ALLOWED_COUNTRIES` | Comma-separated list of ISO 3166-1 alpha-2 country codes | `se` |
| `IPSET_NAME` | Name of the ipset used (should be unique) | `geo_fence_allowlist_ipv4_v1` |
| `UPDATE_INTERVAL` | Update interval in seconds | `604800` (7 days) |
| `CURL_TIMEOUT` | Timeout for HTTP requests in seconds | `30` |
| `CURL_RETRIES` | Number of retry attempts for failed downloads | `3` |
| `CURL_RETRY_DELAY` | Delay between retries in seconds | `5` |
| `MAX_CONSECUTIVE_FAILURES` | Max failures before container exits | `3` |

Example with custom configuration:

```bash
docker run -d \
  --cap-add=NET_ADMIN \
  --network=host \
  --restart unless-stopped \
  -e ALLOWED_COUNTRIES="us,gb,ca,au" \
  -e UPDATE_INTERVAL="86400" \
  -e CURL_TIMEOUT="60" \
  --name geo-fence \
  geo-fence
```

---

## 🚀 What it does

- **On container start:**
  - Waits for network connectivity
  - Validates all configuration and prerequisites
  - Downloads IPv4 CIDRs for allowed countries with retry logic
  - Creates and populates ipset lists
  - Atomically swaps new rules to prevent race conditions
  - Applies iptables rules: **DROP everything not in the allowlist**
  - Allows SSH (port 22), established connections, loopback, and ICMP traffic
  - Updates health check file on success

- **Then runs continuously:**
  - Sleeps for configured interval (default: 7 days)
  - Responds to shutdown signals gracefully
  - Tracks consecutive failures and exits if threshold exceeded
  - Updates health status for monitoring

---

## 🔒 Security & Production Notes

### IPv6 Handling
- This script **only handles IPv4** traffic
- You should block all incoming IPv6 traffic separately:
  ```bash
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ```

### Required Permissions
- Container needs `--cap-add=NET_ADMIN` and `--network=host`
- Kernel must support `ipset` and `iptables` (standard on Ubuntu/Debian)

### Firewall Architecture
- Use **cloud firewall** as primary protection layer
- Geo-fence acts as secondary layer for additional protection
- Always restrict SSH to known IPs at cloud level first

### Production Checklist
- [ ] Test in staging environment first
- [ ] Ensure SSH access from allowed countries
- [ ] Configure monitoring (see Health Monitoring section)
- [ ] Set up log aggregation
- [ ] Plan rollback procedure
- [ ] Document emergency access procedures

---

## 📊 Health Monitoring

The container provides built-in health monitoring:

### Docker Health Check
```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' geo-fence

# View health check logs
docker inspect --format='{{range .State.Health.Log}}{{.Output}}{{end}}' geo-fence
```

### Manual Health Check
```bash
# Check if last update was successful
docker exec geo-fence test -f /tmp/geo-fence-health && echo "Healthy" || echo "Unhealthy"

# View last successful update time
docker exec geo-fence cat /tmp/geo-fence-health 2>/dev/null || echo "No successful runs yet"
```

### Monitoring Integration
Health check file: `/tmp/geo-fence-health` contains ISO 8601 timestamp of last successful run.

Example monitoring script:
```bash
#!/bin/bash
health_file="/tmp/geo-fence-health"
max_age=86400  # 24 hours

if [[ -f "$health_file" ]]; then
  last_success=$(cat "$health_file")
  last_timestamp=$(date -d "$last_success" +%s 2>/dev/null || echo 0)
  current_timestamp=$(date +%s)
  age=$((current_timestamp - last_timestamp))
  
  if [[ $age -lt $max_age ]]; then
    echo "HEALTHY: Last update $((age/3600)) hours ago"
    exit 0
  else
    echo "UNHEALTHY: Last update $((age/3600)) hours ago"
    exit 1
  fi
else
  echo "UNHEALTHY: No health file found"
  exit 1
fi
```

---

## 🔧 Troubleshooting

### Container won't start
```bash
# Check container logs
docker logs geo-fence

# Common issues:
# - Missing --cap-add=NET_ADMIN
# - Missing --network=host
# - Network connectivity problems
```

### Updates failing
```bash
# Check recent logs
docker logs --tail 100 geo-fence

# Test network connectivity
docker exec geo-fence curl -sf https://www.ipdeny.com

# Validate country codes
docker exec geo-fence echo $ALLOWED_COUNTRIES
```

### Blocked from own server
If you get locked out:

1. **Physical/Console access:**
   ```bash
   # Remove the blocking rule
   iptables -D INPUT -m set ! --match-set geo_fence_allowlist_ipv4_v1 src -j DROP
   
   # Or flush all rules (emergency)
   iptables -F INPUT
   ```

2. **Cloud firewall:**
   - Use cloud provider's firewall console to allow your IP
   - Then fix the geo-fence configuration

3. **Prevention:**
   - Always test with a country you're connecting from
   - Use cloud firewall as primary protection
   - Have out-of-band access (console, recovery mode)

### Performance tuning
```bash
# For high-traffic servers, consider:
# - Smaller update intervals
# - Custom ipset sizing
# - Multiple geo-fence instances for redundancy

# Monitor ipset memory usage
docker exec geo-fence ipset list geo_fence_allowlist_ipv4_v1 | head -5
```

---

## 📝 Logs

All logs go to container stdout with structured timestamps:

```bash
# View live logs
docker logs -f geo-fence

# Search for errors
docker logs geo-fence 2>&1 | grep ERROR

# View specific time range
docker logs geo-fence --since="2024-01-01T10:00:00"
```

Log levels:
- `INFO`: Normal operations
- `WARN`: Recoverable issues (retries, duplicate rules)
- `ERROR`: Failed operations requiring attention

---

## 🚨 Emergency Procedures

### Quick disable
```bash
# Stop geo-fencing immediately
docker stop geo-fence

# Remove firewall rules (if needed)
docker exec geo-fence iptables -D INPUT -m set ! --match-set geo_fence_allowlist_ipv4_v1 src -j DROP
```

### Recovery
```bash
# Restart with emergency countries
docker run --rm \
  --cap-add=NET_ADMIN \
  --network=host \
  -e ALLOWED_COUNTRIES="us,gb,de,fr,ca,au,jp,sg" \
  geo-fence
```

### Backup current rules
```bash
# Save current iptables rules
docker exec geo-fence iptables-save > iptables-backup.rules

# Save current ipset
docker exec geo-fence ipset save > ipset-backup.rules
```
