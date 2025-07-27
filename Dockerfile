# Start with a minimal Debian base image
FROM debian:stable-slim

# Install the tools we need:
# - curl: for downloading IP range files
# - ipset: for managing IP sets (collections of IP addresses)
# - iptables: for firewall rules
# - ca-certificates: for HTTPS connections
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ipset iptables ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy our scripts into the container
COPY geo-fence.sh /app/geo-fence.sh
COPY entrypoint.sh /app/entrypoint.sh

# Make the scripts executable
RUN chmod +x /app/*.sh

# Set the working directory
WORKDIR /app

# When the container starts, run our entrypoint script
ENTRYPOINT ["/app/entrypoint.sh"]
