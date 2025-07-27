FROM debian:slim

# Create non-root user for security
RUN groupadd -r geofence && useradd -r -g geofence geofence

# Install only what we need
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ipset iptables ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create app directory
RUN mkdir -p /app && chown geofence:geofence /app

# Copy scripts
COPY geo-fence.sh /app/geo-fence.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/*.sh && chown geofence:geofence /app/*.sh

WORKDIR /app

# Add health check
HEALTHCHECK --interval=1h --timeout=30s --start-period=30s --retries=3 \
  CMD test -f /tmp/geo-fence-health && \
      test $(($(date +%s) - $(date -d "$(cat /tmp/geo-fence-health)" +%s 2>/dev/null || echo 0))) -lt 86400 || exit 1

# Add labels for better container management
LABEL maintainer="geo-fence" \
      description="Geo-fencing firewall using ipset and iptables" \
      version="1.0"

# Note: Container must run as root for iptables/ipset access
# In production, consider using privileged init system or security contexts
USER root

ENTRYPOINT ["/app/entrypoint.sh"]
