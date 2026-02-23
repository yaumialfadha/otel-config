#!/bin/bash
set -e

#==============================================================================
# OpenTelemetry Collector Installation Script
# Usage: sudo ./install-otel.sh
#==============================================================================

echo "=========================================="
echo "Installing OpenTelemetry Collector"
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Error: Please run as root (use sudo)"
    exit 1
fi

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
OTEL_VERSION="0.143.1"
OTEL_CONFIG_URL="https://raw.githubusercontent.com/yaumialfadha/otel-config/main/config.yaml"
OTEL_BACKEND_ENDPOINT="CHANGEME"
SERVICE_NAME="CHANGEME"

#------------------------------------------------------------------------------
# Check dependencies
#------------------------------------------------------------------------------
echo "Checking dependencies..."
if ! command -v wget &> /dev/null; then
    echo "Installing wget..."
    yum install -y wget
fi
if ! command -v curl &> /dev/null; then
    echo "Installing curl..."
    yum install -y curl
fi
echo "✓ Dependencies OK"

#------------------------------------------------------------------------------
# Detect Architecture
#------------------------------------------------------------------------------
echo "[1/6] Detecting architecture..."
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    OTEL_ARCH="linux_arm64"
    echo "✓ Detected: ARM64"
elif [ "$ARCH" = "x86_64" ]; then
    OTEL_ARCH="linux_amd64"
    echo "✓ Detected: AMD64"
else
    echo "✗ Unsupported architecture: $ARCH"
    exit 1
fi

#------------------------------------------------------------------------------
# Download OTEL Collector
#------------------------------------------------------------------------------
echo "[2/6] Downloading OTEL Collector v${OTEL_VERSION}..."
cd /tmp

# Clean up any previous downloads
rm -f otelcol-contrib_${OTEL_VERSION}_${OTEL_ARCH}.tar.gz

DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_${OTEL_ARCH}.tar.gz"

echo "Downloading from: ${DOWNLOAD_URL}"
wget "${DOWNLOAD_URL}"

if [ ! -f "otelcol-contrib_${OTEL_VERSION}_${OTEL_ARCH}.tar.gz" ]; then
    echo "✗ Download failed - file not found"
    exit 1
fi

FILE_SIZE=$(du -h otelcol-contrib_${OTEL_VERSION}_${OTEL_ARCH}.tar.gz | cut -f1)
echo "✓ Download completed (${FILE_SIZE})"

#------------------------------------------------------------------------------
# Extract and Install
#------------------------------------------------------------------------------
echo "[3/6] Installing binary..."
tar -xzf otelcol-contrib_${OTEL_VERSION}_${OTEL_ARCH}.tar.gz

if [ ! -f "otelcol-contrib" ]; then
    echo "✗ Binary not found after extraction"
    exit 1
fi

mv otelcol-contrib /usr/local/bin/
chmod +x /usr/local/bin/otelcol-contrib
rm -f otelcol-contrib_${OTEL_VERSION}_${OTEL_ARCH}.tar.gz

# Update PATH for current session
export PATH=$PATH:/usr/local/bin

# Verify
INSTALLED_VERSION=$(/usr/local/bin/otelcol-contrib --version | head -n1)
echo "✓ Installed: ${INSTALLED_VERSION}"

#------------------------------------------------------------------------------
# Create Directories
#------------------------------------------------------------------------------
echo "[4/6] Creating directories..."
mkdir -p /etc/otelcol-contrib
mkdir -p /var/log/otel-install
echo "✓ Directories created"

#------------------------------------------------------------------------------
# Create Systemd Service
#------------------------------------------------------------------------------
echo "[5/6] Creating systemd service..."
cat > /etc/systemd/system/otelcol-contrib.service <<'EOF'
[Unit]
Description=OpenTelemetry Collector Contrib
Documentation=https://github.com/open-telemetry/opentelemetry-collector
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/otelcol-contrib --config=/etc/otelcol-contrib/config.yaml
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=otelcol

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "✓ Systemd service created"

#------------------------------------------------------------------------------
# Setup Configuration
#------------------------------------------------------------------------------
echo "[6/6] Setting up configuration..."

# Download config from GitHub
echo "Downloading config from GitHub..."
curl -fsSL "${OTEL_CONFIG_URL}" -o /etc/otelcol-contrib/config.yaml

if [ ! -f /etc/otelcol-contrib/config.yaml ]; then
    echo "✗ Failed to download config"
    exit 1
fi

# Get instance metadata (if on EC2)
if curl -s -m 2 http://169.254.169.254/latest/meta-data/ > /dev/null 2>&1; then
    echo "Detected EC2 instance, fetching metadata..."
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
    HOSTNAME="${SERVICE_NAME}-${INSTANCE_ID}"
else
    HOSTNAME="${SERVICE_NAME}-$(hostname)"
fi

# Replace placeholders
sed -i "s|PLACEHOLDER_ENDPOINT|${OTEL_BACKEND_ENDPOINT}|g" /etc/otelcol-contrib/config.yaml
sed -i "s|PLACEHOLDER_HOSTNAME|${HOSTNAME}|g" /etc/otelcol-contrib/config.yaml

echo "✓ Configuration setup complete"
echo "  Backend: ${OTEL_BACKEND_ENDPOINT}"
echo "  Hostname: ${HOSTNAME}"

#------------------------------------------------------------------------------
# Validate Configuration
#------------------------------------------------------------------------------
echo ""
echo "Validating configuration..."
if /usr/local/bin/otelcol-contrib --config=/etc/otelcol-contrib/config.yaml validate 2>&1; then
    echo "✓ Configuration is valid"
else
    echo "✗ Configuration validation failed"
    echo "Config file location: /etc/otelcol-contrib/config.yaml"
    exit 1
fi

#------------------------------------------------------------------------------
# Ask to Start Service
#------------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Installation Complete"
echo "=========================================="
echo ""
read -p "Do you want to start OTEL Collector now? [Y/n] " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo "Enabling and starting OTEL Collector..."
    systemctl enable otelcol-contrib
    systemctl start otelcol-contrib
    
    sleep 3
    
    if systemctl is-active --quiet otelcol-contrib; then
        echo "✓ OTEL Collector is running"
        echo ""
        systemctl status otelcol-contrib --no-pager -l
    else
        echo "✗ OTEL Collector failed to start"
        echo ""
        echo "Checking logs..."
        journalctl -u otelcol-contrib -n 30 --no-pager
        exit 1
    fi
else
    echo "Service not started"
    echo "To start manually: sudo systemctl start otelcol-contrib"
fi

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Installation Summary"
echo "=========================================="
echo "Binary      : /usr/local/bin/otelcol-contrib"
echo "Config      : /etc/otelcol-contrib/config.yaml"
echo "Service     : otelcol-contrib.service"
echo "Backend     : ${OTEL_BACKEND_ENDPOINT}"
echo "Service Name: ${HOSTNAME}"
echo ""
echo "Useful Commands:"
echo "  sudo systemctl status otelcol-contrib"
echo "  sudo systemctl restart otelcol-contrib"
echo "  sudo journalctl -u otelcol-contrib -f"
echo "  curl http://localhost:8888/metrics"
echo "  /usr/local/bin/otelcol-contrib --version"
echo "=========================================="
