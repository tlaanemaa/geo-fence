#!/bin/bash

# Exit immediately if any command fails, treat unset variables as errors, and fail on pipe errors
set -euo pipefail

# Configuration - these can be overridden by environment variables
IPSET_NAME="${IPSET_NAME:-geo_fence_allowlist_ipv4_v1}"  # Name for our IP set
ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES:-se}"             # Countries to allow (comma-separated)

echo "[$(date)] Starting geo-fence update for countries: $ALLOWED_COUNTRIES"

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
  
  echo "[$(date)] Downloading $country"
  
  # Download IP ranges from ipdeny.com and append to our temp file
  # The || { ... } part runs if curl fails
  curl -sf "https://www.ipdeny.com/ipblocks/data/countries/${country}.zone" >> "$TMPFILE" || {
    echo "ERROR: Failed to download IP ranges for $country"
    exit 1
  }
done

# Count how many IP ranges we downloaded
total=$(wc -l < "$TMPFILE")
echo "[$(date)] Downloaded $total IP ranges"

# Special message for empty allowlist
if [[ $total -eq 0 ]]; then
  echo "[$(date)] ⚠️  No IP ranges loaded - ALL countries will be blocked (except SSH)"
fi

# Atomically update the ipset (this prevents blocking everyone during the update)
temp_set="${IPSET_NAME}_temp"

# Remove any leftover temporary set from previous runs
ipset destroy "$temp_set" 2>/dev/null || true

echo "[$(date)] Creating temporary ipset"
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
echo "[$(date)] Swapping ipsets"
ipset swap "$temp_set" "$IPSET_NAME"
# Clean up the temporary set
ipset destroy "$temp_set"

# Ensure essential firewall rules exist (only add if not already present)

# Allow loopback traffic (localhost talking to itself - essential for many services)
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT -i lo -j ACCEPT

# Allow SSH connections from anywhere (prevents lockout - cloud firewall handles restriction)
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j ACCEPT

# Apply the main geo-fence rule: DROP any traffic NOT from our allowed IP set
# The "!" means "not" - so this drops traffic from IPs not in our set
# This takes effect IMMEDIATELY - existing connections from blocked countries are dropped
iptables -C INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP 2>/dev/null || iptables -I INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP

echo "[$(date)] ✅ Geo-fence active with $total IP ranges"
