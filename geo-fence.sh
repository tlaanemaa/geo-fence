#!/bin/bash

set -euo pipefail

# ---------------------
# CONFIGURATION
# ---------------------

# Name of the IP set to use (can be overridden via IPSET_NAME env var)
IPSET_NAME="${IPSET_NAME:-geo_fence_allowlist_ipv4_v1}"

# Comma-separated list of ISO 3166-1 alpha-2 country codes (e.g. "se,ee,de")
ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES:-se}"

# Timeouts and retries
CURL_TIMEOUT="${CURL_TIMEOUT:-30}"
CURL_RETRIES="${CURL_RETRIES:-3}"
CURL_RETRY_DELAY="${CURL_RETRY_DELAY:-5}"

# Health check file
HEALTH_FILE="/tmp/geo-fence-health"

# Temporary file for downloaded CIDR blocks
TMPFILE=$(mktemp)

# Cleanup function
cleanup() {
  local exit_code=$?
  echo "[INFO] Cleaning up temporary files..."
  rm -f "$TMPFILE"
  if [[ $exit_code -eq 0 ]]; then
    echo "$(date -Iseconds)" > "$HEALTH_FILE"
    echo "[INFO] Health check file updated"
  else
    rm -f "$HEALTH_FILE"
    echo "[ERROR] Removed health check file due to failure"
  fi
  exit $exit_code
}

# Set up signal handlers
trap cleanup EXIT
trap 'echo "[ERROR] Script interrupted"; exit 1' INT TERM

# Logging function
log() {
  local level="$1"
  shift
  echo "[$(date -Iseconds)] [$level] $*"
}

# Validation functions
validate_country_code() {
  local cc="$1"
  if [[ ! "$cc" =~ ^[a-z]{2}$ ]]; then
    log "ERROR" "Invalid country code: $cc (must be 2 lowercase letters)"
    return 1
  fi
}

validate_ipset_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]{1,31}$ ]]; then
    log "ERROR" "Invalid ipset name: $name (must be 1-31 chars, alphanumeric plus _ and -)"
    return 1
  fi
}

# Network function with retries
download_with_retry() {
  local url="$1"
  local output_file="$2"
  local attempt=1
  
  while [[ $attempt -le $CURL_RETRIES ]]; do
    log "INFO" "Downloading $url (attempt $attempt/$CURL_RETRIES)"
    
    if curl -sf --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" "$url" >> "$output_file"; then
      return 0
    fi
    
    if [[ $attempt -lt $CURL_RETRIES ]]; then
      log "WARN" "Download failed, retrying in ${CURL_RETRY_DELAY}s..."
      sleep "$CURL_RETRY_DELAY"
    fi
    
    ((attempt++))
  done
  
  log "ERROR" "Failed to download $url after $CURL_RETRIES attempts"
  return 1
}

# Check prerequisites
check_prerequisites {
  log "INFO" "Checking prerequisites..."
  
  local missing_tools=()
  for tool in ipset iptables curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools+=("$tool")
    fi
  done
  
  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log "ERROR" "Missing required tools: ${missing_tools[*]}"
    exit 1
  fi
  
  # Check if we can create ipsets (requires NET_ADMIN capability)
  if ! ipset list >/dev/null 2>&1; then
    log "ERROR" "Cannot access ipset. Ensure container runs with --cap-add=NET_ADMIN"
    exit 1
  fi
  
  # Check if we can modify iptables
  if ! iptables -L >/dev/null 2>&1; then
    log "ERROR" "Cannot access iptables. Ensure container runs with --cap-add=NET_ADMIN and --network=host"
    exit 1
  fi
  
  log "INFO" "Prerequisites check passed"
}

log "INFO" "Starting geo-fence update"
log "INFO" "Target IPv4 IP set: $IPSET_NAME"
log "INFO" "Allowed countries: $ALLOWED_COUNTRIES"

# Validate inputs
validate_ipset_name "$IPSET_NAME"

# Check prerequisites
check_prerequisites

# ---------------------
# DOWNLOAD IP RANGES
# ---------------------

IFS=',' read -ra CCLIST <<< "$ALLOWED_COUNTRIES"

# Validate all country codes first
for cc in "${CCLIST[@]}"; do
  # Trim whitespace and convert to lowercase
  cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]' | xargs)
  validate_country_code "$cc"
done

log "INFO" "Downloading country IP ranges"
total_downloaded=0

for cc in "${CCLIST[@]}"; do
  # Trim whitespace and convert to lowercase
  cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]' | xargs)
  
  url="https://www.ipdeny.com/ipblocks/data/countries/${cc}.zone"
  
  # Create temporary file for this country
  cc_tmpfile=$(mktemp)
  
  if download_with_retry "$url" "$cc_tmpfile"; then
    # Validate the downloaded content
    if [[ ! -s "$cc_tmpfile" ]]; then
      log "ERROR" "Downloaded file for $cc is empty"
      rm -f "$cc_tmpfile"
      exit 1
    fi
    
    # Basic validation: check if file contains valid CIDR blocks
    if ! grep -q '^[0-9]' "$cc_tmpfile"; then
      log "ERROR" "Downloaded file for $cc doesn't contain valid IP ranges"
      rm -f "$cc_tmpfile"
      exit 1
    fi
    
    # Count and append
    cc_count=$(wc -l < "$cc_tmpfile")
    cat "$cc_tmpfile" >> "$TMPFILE"
    total_downloaded=$((total_downloaded + cc_count))
    
    log "INFO" "Country $cc: $cc_count CIDRs downloaded"
    rm -f "$cc_tmpfile"
  else
    log "ERROR" "Failed to download IP ranges for country: $cc"
    exit 1
  fi
done

TOTAL_CIDRS=$(wc -l < "$TMPFILE")
log "INFO" "Download complete. Total IPv4 CIDRs: $TOTAL_CIDRS"

if [[ $TOTAL_CIDRS -eq 0 ]]; then
  log "ERROR" "No IP ranges downloaded. This would block all traffic!"
  exit 1
fi

# ---------------------
# ATOMICALLY REPLACE IPSET
# ---------------------

update_ipset() {
  local -r name="$1"
  local -r tmpfile="$2"
  local -r family="$3"
  local -r tmp_name="${name}_temp"

  log "INFO" "Creating temporary ipset: $tmp_name"
  
  # Ensure temporary set doesn't already exist
  ipset destroy "$tmp_name" 2>/dev/null || true
  
  # Create a temporary set with appropriate sizing
  # Estimate maxelem based on CIDR count (with some buffer)
  local maxelem=$((TOTAL_CIDRS + 1000))
  ipset create "$tmp_name" hash:net family "$family" maxelem "$maxelem"

  log "INFO" "Populating temporary IP set: $tmp_name"
  local failed_count=0
  local success_count=0
  
  while read -r ip; do
    # Skip empty lines and comments
    [[ -z "$ip" || "$ip" =~ ^[[:space:]]*# ]] && continue
    
    if ipset add "$tmp_name" "$ip" 2>/dev/null; then
      ((success_count++))
    else
      log "WARN" "Failed to add IP: $ip"
      ((failed_count++))
    fi
  done < "$tmpfile"
  
  log "INFO" "IP set population complete: $success_count added, $failed_count failed"
  
  if [[ $success_count -eq 0 ]]; then
    log "ERROR" "No IPs were successfully added to the set!"
    ipset destroy "$tmp_name"
    exit 1
  fi

  # If the real set doesn't exist, create it
  if ! ipset list -n | grep -q "^$name$"; then
    log "INFO" "Creating new IP set: $name"
    ipset create "$name" hash:net family "$family" maxelem "$maxelem"
  fi

  # Atomically swap the sets
  log "INFO" "Swapping IP set: $tmp_name -> $name"
  ipset swap "$tmp_name" "$name"
  ipset destroy "$tmp_name"
}

update_ipset "$IPSET_NAME" "$TMPFILE" "inet"

# ---------------------
# ADD IPTABLES RULES
# ---------------------

ensure_rule() {
  local -r table_cmd="$1"
  shift
  local -r rule=("$@")

  if ! "$table_cmd" -C "${rule[@]}" 2>/dev/null; then
    log "INFO" "Adding iptables rule: ${rule[*]}"
    "$table_cmd" -I "${rule[@]}"
  else
    log "INFO" "Rule already exists: ${rule[*]}"
  fi
}

# Always allow loopback traffic (critical for system operation)
ensure_rule iptables INPUT -i lo -j ACCEPT

# Allow established and related connections (prevents dropping active connections)
ensure_rule iptables INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Ensure SSH is allowed explicitly (prevent lockout)
ensure_rule iptables INPUT -p tcp --dport 22 -j ACCEPT

# Allow ICMP for network diagnostics
ensure_rule iptables INPUT -p icmp -j ACCEPT

# Drop anything not in the allowed IP set
ensure_rule iptables INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP

# ---------------------
# VERIFY RULES
# ---------------------

log "INFO" "Verifying iptables rules are in place..."
if ! iptables -C INPUT -m set ! --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; then
  log "ERROR" "Main geo-fence rule not found in iptables!"
  exit 1
fi

if ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
  log "ERROR" "SSH allow rule not found in iptables!"
  exit 1
fi

# ---------------------
# DONE
# ---------------------

log "INFO" "Geo-fence applied successfully"
log "INFO" "  IP set name: $IPSET_NAME"
log "INFO" "  Allowed countries: $ALLOWED_COUNTRIES"
log "INFO" "  IPv4 CIDRs loaded: $TOTAL_CIDRS"
log "INFO" "  Health check: $HEALTH_FILE"

# Success - cleanup function will update health file
