#!/bin/bash

# Geo-fence: Country-based traffic filtering for host and Docker services
# Downloads IP ranges for allowed countries and blocks all other traffic
# Includes essential protections to prevent lockout

# Exit immediately if any command fails, treat unset variables as errors, and fail on pipe errors
set -euo pipefail

# Configuration - these can be overridden by environment variables
IPSET_NAME="${IPSET_NAME:-geo_fence_allow_v1}"  # Name for our IP set
ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES:-se}"    # Countries to allow (comma-separated)

# Logging helper
log() {
  echo "[$(date)] $1"
}

# === DOWNLOAD IP RANGES ===

# Create temporary file for aggregated IP ranges
# This gets automatically deleted when the script exits (success or failure)
ip_ranges_file=$(mktemp)
trap "rm -f $ip_ranges_file" EXIT

# Split the comma-separated country list into an array
IFS=',' read -ra countries <<< "$ALLOWED_COUNTRIES"
total_ranges=0

# Download IP ranges for each allowed country
for country in "${countries[@]}"; do
  # Clean up the country code (remove spaces, convert to lowercase)
  country=$(echo "$country" | xargs | tr '[:upper:]' '[:lower:]')
  
  # Skip empty entries (happens when ALLOWED_COUNTRIES has trailing commas)
  [[ -z "$country" ]] && continue
  
  # Validate country code format (exactly 2 letters, alphabetic only)
  if [[ ! "$country" =~ ^[a-z]{2}$ ]]; then
    log "⚠️  Skipping invalid country code: '$country' (must be 2 letters like 'se' or 'us')"
    continue
  fi
  
  log "📥 Downloading IP ranges for $country"
  
  # Download to a temp file first for validation
  country_temp=$(mktemp)
  
  # Download IP ranges from ipdeny.com with security hardening:
  # - Timeout limits prevent hanging
  # - File size limits prevent disk filling
  # - HTTPS-only prevents man-in-the-middle attacks
  # - Retry logic handles temporary network issues
  if curl -sf --max-time 30 --max-filesize 10485760 --max-redirs 0 --proto =https \
          --retry 10 --retry-max-time 600 \
          "https://www.ipdeny.com/ipblocks/data/countries/${country}.zone" -o "$country_temp"; then
    
    # Validate that the file contains only valid IP ranges (CIDR format)
    # This prevents malicious data from breaking our firewall
    if invalid_line=$(grep -v '^$' "$country_temp" | grep -v '^[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/[0-9]\{1,2\}$' | head -1); then
      log "❌ Invalid data in $country ranges: $invalid_line"
      rm -f "$country_temp"
      exit 1
    fi
    
    # Count how many IP ranges we got and add them to our main list
    country_count=$(grep -c '^[0-9]' "$country_temp" || echo "0")
    cat "$country_temp" >> "$ip_ranges_file"
    total_ranges=$((total_ranges + country_count))
    log "✅ Added $country_count ranges from $country"
  else
    log "❌ Failed to download $country ranges"
    rm -f "$country_temp"
    exit 1
  fi
  
  rm -f "$country_temp"
done

log "📊 Total IP ranges collected: $total_ranges"

# Special warning if no ranges were loaded
if [[ $total_ranges -eq 0 ]]; then
  log "⚠️  WARNING: No IP ranges loaded - will block ALL traffic except SSH"
fi

# === UPDATE IPSET ===

log "🔄 Updating IP set: $IPSET_NAME"

# Create temporary set for atomic update
# This prevents blocking everyone during the update process
temp_set="${IPSET_NAME}_temp"

# Remove any leftover temporary set from previous runs
ipset destroy "$temp_set" 2>/dev/null || true

# Create a new temporary ipset to hold our IP ranges
ipset create "$temp_set" hash:net

# Add each IP range to the temporary set
while read -r ip_range; do
  # Only add non-empty lines
  [[ -n "$ip_range" ]] && ipset add "$temp_set" "$ip_range"
done < "$ip_ranges_file"

# Create the main set if it doesn't exist yet (first run)
ipset list "$IPSET_NAME" >/dev/null 2>&1 || ipset create "$IPSET_NAME" hash:net

# Atomically swap the temporary set with the main set
# This ensures there's never a moment where the set is empty
ipset swap "$temp_set" "$IPSET_NAME"
ipset destroy "$temp_set"

log "✅ IP set updated successfully"

# === CONFIGURE FIREWALL ===

log "🔧 Configuring firewall rules"

# Essential ACCEPT rules that must come before our DROP rules
# These prevent you from getting locked out of your server

# Allow established and related connections (return traffic from server-initiated connections)
# This ensures DNS responses, apt updates, ping replies, API responses, etc. work normally
if ! iptables -C INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    log "   Added: Allow return traffic (keeps internet working)"
fi

# Allow loopback traffic (localhost talking to itself - essential for many services)
if ! iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -i lo -j ACCEPT
    log "   Added: Allow loopback traffic (localhost communication)"
fi

# Allow SSH connections from anywhere (prevents lockout - cloud firewall should restrict this)
if ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    log "   Added: Allow SSH (prevents lockout - secure this via your cloud firewall)"
fi

# Remove any existing geo-fence rules to start clean
# Loop to remove ALL instances of the rule (not just the first one)
while iptables -D INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; do
    :  # Keep removing until no more instances exist
done
while iptables -D DOCKER-USER -m set ! --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; do
    :  # Keep removing until no more instances exist
done

# Apply geo-fence blocking to traffic paths:
# INPUT chain = traffic to host services (SSH, web servers running on host)
iptables -A INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP

# DOCKER-USER chain = traffic to Docker containers (only if Docker is installed)
if iptables -L DOCKER-USER >/dev/null 2>&1; then
    iptables -I DOCKER-USER 1 -m set ! --match-set "$IPSET_NAME" src -j DROP
    log "   Added: Geo-fence blocking (protects host + Docker containers)"
    log "🎯 Geo-fence active: $total_ranges IP ranges protecting host + containers"
else
    log "   Added: Geo-fence blocking (protects host services - Docker not detected)"
    log "🎯 Geo-fence active: $total_ranges IP ranges protecting host"
fi
