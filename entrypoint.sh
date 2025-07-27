#!/bin/bash

# Exit immediately if any command fails, treat unset variables as errors, and fail on pipe errors
set -euo pipefail

# How long to wait between updates (default: 7 days = 604800 seconds)
UPDATE_INTERVAL="${UPDATE_INTERVAL:-604800}"  # 7 days

echo "[$(date)] Geo-fence container starting"
echo "[$(date)] Update interval: $UPDATE_INTERVAL seconds"

# Set up signal handling for graceful shutdown
shutdown=false
# When Docker sends TERM or INT signal, set shutdown flag instead of exiting immediately
trap 'shutdown=true' TERM INT

# Main loop - keep running until shutdown is requested
while [[ "$shutdown" != "true" ]]; do
  echo "[$(date)] 🛡️ Running geo-fence update"
  
  # Run the main geo-fence script
  if /app/geo-fence.sh; then
    echo "[$(date)] ✅ Update completed successfully"
  else
    # If the update fails, exit the container (Docker will restart it)
    echo "[$(date)] ❌ Update failed"
    exit 1
  fi
  
  echo "[$(date)] 💤 Sleeping for $UPDATE_INTERVAL seconds"
  
  # Sleep in small chunks so we can respond quickly to shutdown signals
  remaining=$UPDATE_INTERVAL
  while [[ $remaining -gt 0 && "$shutdown" != "true" ]]; do
    # Sleep for max 5 seconds at a time, or whatever time is remaining
    sleep_time=$((remaining > 5 ? 5 : remaining))
    sleep $sleep_time
    remaining=$((remaining - sleep_time))
  done
done

echo "[$(date)] Shutting down gracefully"
