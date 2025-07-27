#!/bin/bash

set -euo pipefail

# Configuration
UPDATE_INTERVAL="${UPDATE_INTERVAL:-604800}"  # 7 days in seconds
HEALTH_CHECK_FILE="/tmp/geo-fence-health"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"

# Logging function
log() {
  local level="$1"
  shift
  echo "[$(date -Iseconds)] [ENTRYPOINT] [$level] $*"
}

# Signal handlers
shutdown_requested=false

handle_shutdown() {
  log "INFO" "Shutdown signal received, will exit after current operation completes"
  shutdown_requested=true
}

handle_immediate_shutdown() {
  log "WARN" "Immediate shutdown signal received, exiting now"
  exit 0
}

# Set up signal handlers
trap handle_shutdown TERM
trap handle_immediate_shutdown INT

# Health check function
is_healthy() {
  if [[ -f "$HEALTH_CHECK_FILE" ]]; then
    local last_success
    last_success=$(cat "$HEALTH_CHECK_FILE" 2>/dev/null || echo "")
    
    if [[ -n "$last_success" ]]; then
      # Check if last success was within reasonable time (2x update interval)
      local max_age=$((UPDATE_INTERVAL * 2))
      local last_timestamp
      last_timestamp=$(date -d "$last_success" +%s 2>/dev/null || echo "0")
      local current_timestamp
      current_timestamp=$(date +%s)
      
      if [[ $((current_timestamp - last_timestamp)) -lt $max_age ]]; then
        return 0
      fi
    fi
  fi
  return 1
}

# Wait for network connectivity
wait_for_network() {
  local retries=30
  local delay=10
  
  log "INFO" "Waiting for network connectivity..."
  
  for ((i=1; i<=retries; i++)); do
    if curl -sf --connect-timeout 5 --max-time 10 "https://www.ipdeny.com" >/dev/null 2>&1; then
      log "INFO" "Network connectivity confirmed"
      return 0
    fi
    
    if [[ $i -lt $retries ]]; then
      log "WARN" "Network not ready, retrying in ${delay}s (attempt $i/$retries)"
      sleep "$delay"
    fi
  done
  
  log "ERROR" "Network connectivity check failed after $retries attempts"
  return 1
}

# Main execution function
run_geo_fence() {
  log "INFO" "🛡️ Starting geo-fence update at $(date)"
  
  if /app/geo-fence.sh; then
    log "INFO" "✅ Geo-fence update completed successfully"
    return 0
  else
    log "ERROR" "❌ Geo-fence update failed"
    return 1
  fi
}

# Initial setup
log "INFO" "Geo-fence container starting up"
log "INFO" "Update interval: ${UPDATE_INTERVAL}s ($(($UPDATE_INTERVAL / 3600)) hours)"
log "INFO" "Health check file: $HEALTH_CHECK_FILE"

# Wait for network on startup
if ! wait_for_network; then
  log "ERROR" "Cannot proceed without network connectivity"
  exit 1
fi

# Main loop
consecutive_failures=0

while true; do
  # Check if shutdown was requested
  if [[ "$shutdown_requested" == "true" ]]; then
    log "INFO" "Shutdown requested, exiting gracefully"
    exit 0
  fi
  
  # Run the geo-fence update
  if run_geo_fence; then
    consecutive_failures=0
  else
    ((consecutive_failures++))
    log "ERROR" "Consecutive failures: $consecutive_failures/$MAX_CONSECUTIVE_FAILURES"
    
    if [[ $consecutive_failures -ge $MAX_CONSECUTIVE_FAILURES ]]; then
      log "ERROR" "Maximum consecutive failures reached, exiting"
      exit 1
    fi
  fi
  
  # Sleep with interruptible mechanism
  log "INFO" "💤 Sleeping for $UPDATE_INTERVAL seconds until next update"
  
  # Break sleep into smaller chunks to allow for responsive shutdown
  local sleep_remaining=$UPDATE_INTERVAL
  local sleep_chunk=60  # Check for shutdown every minute
  
  while [[ $sleep_remaining -gt 0 && "$shutdown_requested" != "true" ]]; do
    local this_sleep=$((sleep_remaining < sleep_chunk ? sleep_remaining : sleep_chunk))
    sleep "$this_sleep"
    sleep_remaining=$((sleep_remaining - this_sleep))
  done
  
  if [[ "$shutdown_requested" == "true" ]]; then
    log "INFO" "Shutdown requested during sleep, exiting gracefully"
    exit 0
  fi
done
