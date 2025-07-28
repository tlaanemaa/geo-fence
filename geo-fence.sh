#!/bin/bash

# Exit immediately if any command fails, treat unset variables as errors, and fail on pipe errors
set -euo pipefail

# Configuration - these can be overridden by environment variables
IPSET_NAME="${IPSET_NAME:-geo_fence_allow_v1}"  # Name for our IP set
ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES:-se}"    # Countries to allow (comma-separated)

# Logging function
log() {
  echo "[$(date)] $1"
}

log "Starting geo-fence update for countries: $ALLOWED_COUNTRIES"

# Create a temporary file to store downloaded IP ranges
TMPFILE=$(mktemp)
# Ensure the temp file gets deleted when script exits (success or failure)
trap "rm -f $TMPFILE" EXIT

# Split the comma-separated country list into an array
IFS=',' read -ra COUNTRIES <<< "$ALLOWED_COUNTRIES"

# Download IP ranges for each country
for country in "${COUNTRIES[@]}"; do
  # Clean up the country code (remove spaces, convert to lowercase)
  country=$(echo "$country" | xargs | tr '[:upper:]' '[:lower:]')
  
  # Skip empty entries (happens when ALLOWED_COUNTRIES is empty or has trailing commas)
  [[ -z "$country" ]] && continue
  
  # Validate country code format (2 letters, alphabetic only)
  if [[ ! "$country" =~ ^[a-z]{2}$ ]]; then
    log "⚠️ Skipping invalid country code '$country' (must be 2 letters)"
    continue
  fi
  
  log "Downloading $country"
  
  # Download to a temp file first for validation
  country_file=$(mktemp)
  
  # Download IP ranges from ipdeny.com
  # Security hardening: timeout, size limit, no redirects, HTTPS-only
  curl -sf --max-time 30 --max-filesize 10485760 --max-redirs 0 --proto =https \
    --retry 10 --retry-max-time 600 \
    "https://www.ipdeny.com/ipblocks/data/countries/${country}.zone" -o "$country_file" || {
    log "❌ Failed to download IP ranges for $country after 10 retries"
    rm -f "$country_file"  # Clean up on failure
    exit 1
  }
  
  # Validate entire file contains only CIDR blocks (skip empty lines)
  if invalid_line=$(grep -v '^$' "$country_file" | grep -v '^[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/[0-9]\{1,2\}$' | head -1); then
    log "❌ Invalid IP range format for $country, found: $invalid_line"
    rm -f "$country_file"  # Clean up on failure
    exit 1
  fi
  
  # Validation passed, append to main file and clean up
  cat "$country_file" >> "$TMPFILE"
  rm -f "$country_file"
done

# Count how many IP ranges we downloaded
total=$(wc -l < "$TMPFILE")
log "Downloaded $total IP ranges"

# Special message for empty allowlist
if [[ $total -eq 0 ]]; then
  log "⚠️ No IP ranges loaded - ALL countries will be blocked (except SSH)"
fi

# Atomically update the ipset (this prevents blocking everyone during the update)
temp_set="${IPSET_NAME}_temp"

# Remove any leftover temporary set from previous runs
ipset destroy "$temp_set" 2>/dev/null || true

log "Creating temporary ipset"
# Create a new temporary ipset to hold our IP ranges
ipset create "$temp_set" hash:net

# Add each IP range to the temporary set
while read -r ip; do
  # Only add non-empty lines
  [[ -n "$ip" ]] && ipset add "$temp_set" "$ip"
done < "$TMPFILE"

# Create the main set if it doesn't exist yet (first run)
ipset list "$IPSET_NAME" >/dev/null 2>&1 || ipset create "$IPSET_NAME" hash:net

# Atomically swap the temporary set with the main set
# This ensures there's never a moment where the set is empty
log "Swapping ipsets"
ipset swap "$temp_set" "$IPSET_NAME"
# Clean up the temporary set
ipset destroy "$temp_set"

# Ensure our ACCEPT rules come before our DROP rule (respects user's existing rules)
log "Updating firewall rules"

# Allow established and related connections (return traffic from server-initiated connections)
# This ensures DNS responses, apt updates, ping replies, API responses, etc. work normally
if ! iptables -C INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    log "Adding RELATED,ESTABLISHED rule"
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# Allow loopback traffic (localhost talking to itself - essential for many services)
if ! iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
    log "Adding loopback rule"
    iptables -A INPUT -i lo -j ACCEPT
fi

# Allow SSH connections from anywhere (prevents lockout - cloud firewall handles restriction)
if ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
    log "Adding SSH rule"
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
fi

# Apply the main geo-fence rule: DROP any NEW traffic NOT from our allowed IP set
# The "!" means "not" - so this drops NEW connections from IPs not in our set
log "Updating geo-fence DROP rule"
iptables -D INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP 2>/dev/null || true
iptables -A INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP

log "✅ Geo-fence active with $total IP ranges"
