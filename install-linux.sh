#!/bin/bash
# ============================================================================
# AxIS RMM Agent - Linux Installer
# Supports: Ubuntu 20.04+ / Debian 11+
# Usage:    curl -s http://192.168.239.50:8772/portal/install-linux.sh | sudo bash
# ============================================================================
set -e

AGENT_DIR="/opt/axis-rmm-agent"
CONFIG_DIR="/etc/axis-rmm"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="axis-rmm-agent"
AGENT_FILE="${AGENT_DIR}/agent_mod.py"
LOG_FILE="${CONFIG_DIR}/agent.log"

# Portal URLs to try (in order)
PORTAL_URLS=(
    "https://rmm.gillsitworld.com"
    "http://192.168.239.50:8772"
)

# Backend URLs to try (in order)
BACKEND_URLS=(
    "https://rmm.gillsitworld.com"
    "http://192.168.239.50:8772"
)

# Enrollment URLs to try
ENROLLMENT_URLS=(
    "https://api.gillsitworld.com"
    "http://192.168.239.95:8770"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[AxIS]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }

banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   AxIS RMM Agent - Linux Installer        ║${NC}"
    echo -e "${CYAN}║   Gill's IT World                         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [ ! -f /etc/os-release ]; then
        error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
    . /etc/os-release
    case "$ID" in
        ubuntu|debian)
            log "Detected OS: ${PRETTY_NAME}"
            ;;
        *)
            warn "Untested OS: ${PRETTY_NAME} - proceeding anyway"
            ;;
    esac
}

check_python() {
    if command -v python3 &>/dev/null; then
        PY3=$(command -v python3)
        PY_VER=$($PY3 --version 2>&1 | awk '{print $2}')
        log "Python3 found: ${PY3} (${PY_VER})"
    else
        log "Python3 not found, installing..."
        apt-get update -qq
        apt-get install -y -qq python3 python3-pip python3-venv >/dev/null 2>&1
        PY3=$(command -v python3)
        log "Python3 installed: ${PY3}"
    fi
}

install_psutil() {
    if $PY3 -c "import psutil" 2>/dev/null; then
        log "psutil already installed"
    else
        log "Installing psutil..."
        # Try pip3 first, then apt
        if command -v pip3 &>/dev/null; then
            pip3 install psutil -q 2>/dev/null || true
        fi
        # Verify, fall back to apt
        if ! $PY3 -c "import psutil" 2>/dev/null; then
            apt-get update -qq 2>/dev/null
            apt-get install -y -qq python3-psutil >/dev/null 2>&1 || true
        fi
        # Final check
        if $PY3 -c "import psutil" 2>/dev/null; then
            log "psutil installed successfully"
        else
            warn "psutil not available - agent will run with limited metrics"
        fi
    fi
}

# ── Auto-detect backend ────────────────────────────────────────────────────

detect_portal() {
    PORTAL_URL=""
    for url in "${PORTAL_URLS[@]}"; do
        info "Trying portal: ${url}..."
        if curl -s --connect-timeout 3 -o /dev/null -w "" "${url}/health" 2>/dev/null; then
            PORTAL_URL="${url}"
            log "Portal reachable: ${url}"
            return 0
        fi
    done
    # If health check fails, try just a TCP connect
    for url in "${PORTAL_URLS[@]}"; do
        host=$(echo "$url" | sed 's|http://||;s|:.*||')
        port=$(echo "$url" | sed 's|.*:||')
        if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
            PORTAL_URL="${url}"
            log "Portal reachable (TCP): ${url}"
            return 0
        fi
    done
    error "No reachable portal found. Tried: ${PORTAL_URLS[*]}"
    exit 1
}

detect_backend() {
    BACKEND_URL=""
    for url in "${BACKEND_URLS[@]}"; do
        host=$(echo "$url" | sed 's|http://||;s|:.*||')
        port=$(echo "$url" | sed 's|.*:||')
        if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
            BACKEND_URL="${url}"
            log "Backend reachable: ${url}"
            return 0
        fi
    done
    # Default to first option
    BACKEND_URL="${BACKEND_URLS[0]}"
    warn "No backend responded, defaulting to: ${BACKEND_URL}"
}

# ── Install agent ──────────────────────────────────────────────────────────

download_agent() {
    log "Downloading agent from ${PORTAL_URL}/portal/agent_mod.py ..."
    mkdir -p "${AGENT_DIR}"
    curl -sS -f "${PORTAL_URL}/portal/agent_mod.py" -o "${AGENT_FILE}"
    if [ ! -s "${AGENT_FILE}" ]; then
        error "Download failed or file is empty"
        exit 1
    fi
    chmod 755 "${AGENT_FILE}"
    AGENT_VER=$(grep 'AGENT_VERSION' "${AGENT_FILE}" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    log "Agent downloaded: v${AGENT_VER}"
}

generate_token() {
    # Generate a registration token from machine-id + timestamp
    if [ -f /etc/machine-id ]; then
        MACHINE_ID=$(cat /etc/machine-id)
    else
        MACHINE_ID=$(hostname | md5sum | awk '{print $1}')
    fi
    REG_TOKEN=$(echo -n "${MACHINE_ID}-$(date +%s)" | sha256sum | awk '{print $1}' | head -c 48)
    log "Registration token generated: ${REG_TOKEN:0:12}..."
}

create_config() {
    log "Creating config..."
    mkdir -p "${CONFIG_DIR}"

    CLIENT_ID=$(hostname -s)
    SITE_ID="linux-auto"
    
    generate_token

    cat > "${CONFIG_FILE}" <<CFGEOF
{
  "backend_url": "${BACKEND_URL}",
  "enrollment_url": "https://api.gillsitworld.com",
  "mtls_backend_url": "https://api.gillsitworld.com",
  "registration_token": "${REG_TOKEN}",
  "agent_id": "",
  "secret_key": "",
  "poll_interval": 60,
  "client_id": "${CLIENT_ID}",
  "site_id": "${SITE_ID}",
  "enrollment_agent_id": "",
  "enrollment_token": "",
  "cert_file": "",
  "key_file": "",
  "ca_chain_file": "",
  "backend_cert_file": "",
  "self_healing": false,
  "watchdog_services": []
}
CFGEOF

    chmod 600 "${CONFIG_FILE}"
    log "Config written to ${CONFIG_FILE}"
    info "  client_id: ${CLIENT_ID}"
    info "  backend:   ${BACKEND_URL}"
}

# ── Systemd service ────────────────────────────────────────────────────────

create_service() {
    log "Creating systemd service..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=AxIS RMM Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PY3} ${AGENT_FILE}
WorkingDirectory=${AGENT_DIR}
Environment=AXIS_CONFIG=${CONFIG_FILE}
Restart=always
RestartSec=30
StartLimitIntervalSec=300
StartLimitBurst=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=axis-rmm-agent

# Security hardening
ProtectSystem=false
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SVCEOF

    chmod 644 "/etc/systemd/system/${SERVICE_NAME}.service"
    log "Service file created"
}

start_service() {
    log "Enabling and starting service..."
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" --now 2>/dev/null
    
    # Give it a moment to start
    sleep 2
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log "Service started successfully"
    else
        warn "Service may not have started cleanly. Checking status..."
        systemctl status "${SERVICE_NAME}" --no-pager -l 2>&1 | tail -10
    fi
}

# ── Cleanup old installs ──────────────────────────────────────────────────

cleanup_old() {
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        warn "Existing service found, stopping..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        warn "Removing old service file..."
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    fi
}

# ── Summary ────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   AxIS RMM Agent - Install Complete!      ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    info "Agent:   ${AGENT_FILE}"
    info "Config:  ${CONFIG_FILE}"
    info "Service: ${SERVICE_NAME}"
    info "Logs:    journalctl -u ${SERVICE_NAME} -f"
    echo ""
    STATUS=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "active" ]; then
        log "Status: RUNNING"
    else
        warn "Status: ${STATUS}"
    fi
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
    banner
    check_root
    check_os
    check_python
    install_psutil
    detect_portal
    detect_backend
    cleanup_old
    download_agent
    create_config
    create_service
    start_service
    print_summary
}

main "$@"
