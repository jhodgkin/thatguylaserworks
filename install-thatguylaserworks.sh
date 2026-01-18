#!/usr/bin/env bash

# That Guy Laser Works - Proxmox LXC Helper Script
# Creates a lightweight Alpine LXC container with nginx to serve the static website

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
CTID="${CTID:-}"
HOSTNAME="${HOSTNAME:-thatguylaserworks}"
MEMORY="${MEMORY:-256}"
DISK="${DISK:-1}"
CORES="${CORES:-1}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"
GATEWAY="${GATEWAY:-}"

# GitHub repository
REPO_URL="https://github.com/jhodgkin/thatlaserworksguy.git"

function header() {
    clear
    echo -e "${BLUE}"
    cat << "EOF"
  _____ _           _      ____
 |_   _| |__   __ _| |_   / ___|_   _ _   _
   | | | '_ \ / _` | __| | |  _| | | | | | |
   | | | | | | (_| | |_  | |_| | |_| | |_| |
   |_| |_| |_|\__,_|\__|  \____|\__,_|\__, |
                                      |___/
  _                        __        __         _
 | |    __ _ ___  ___ _ __ \ \      / /__  _ __| | _____
 | |   / _` / __|/ _ \ '__| \ \ /\ / / _ \| '__| |/ / __|
 | |__| (_| \__ \  __/ |     \ V  V / (_) | |  |   <\__ \
 |_____\__,_|___/\___|_|      \_/\_/ \___/|_|  |_|\_\___/

EOF
    echo -e "${NC}"
    echo -e "${GREEN}Proxmox LXC Container Setup Script${NC}"
    echo ""
}

function msg() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root on your Proxmox host"
    fi
}

function check_proxmox() {
    if ! command -v pct &> /dev/null; then
        error "This script must be run on a Proxmox VE host"
    fi
}

function get_next_ctid() {
    local id=100
    while pct status $id &> /dev/null; do
        ((id++))
    done
    echo $id
}

function select_template() {
    echo ""
    msg "Scanning for available templates..."

    # Get all templates from all storages
    local templates=()
    local i=1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        templates+=("$line")
        echo "  $i) $line"
        ((i++))
    done < <(pvesm status --content vztmpl | tail -n +2 | awk '{print $1}' | while read storage; do
        pveam list "$storage" 2>/dev/null | tail -n +2 | awk '{print $1}'
    done)

    if [[ ${#templates[@]} -eq 0 ]]; then
        warn "No templates found locally."
        echo ""
        echo "Would you like to download one? Here are available templates:"
        pveam update >/dev/null 2>&1

        local available=()
        i=1
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            available+=("$line")
            echo "  $i) $line"
            ((i++))
        done < <(pveam available | awk '{print $2}' | head -20)

        echo ""
        read -p "Enter number to download (or 'q' to quit): " choice
        [[ "$choice" == "q" ]] && exit 0

        local selected="${available[$((choice-1))]}"
        if [[ -z "$selected" ]]; then
            error "Invalid selection"
        fi

        msg "Downloading $selected..."
        pveam download "$TEMPLATE_STORAGE" "$selected" || error "Failed to download"
        echo "${TEMPLATE_STORAGE}:vztmpl/${selected}"
        return
    fi

    echo ""
    read -p "Select template [1]: " choice
    choice="${choice:-1}"

    local selected="${templates[$((choice-1))]}"
    if [[ -z "$selected" ]]; then
        error "Invalid selection"
    fi

    echo "$selected"
}

function create_container() {
    local template=$1

    msg "Creating LXC container (CTID: $CTID)..."

    local net_config="name=eth0,bridge=${BRIDGE}"
    if [[ "$IP" != "dhcp" ]]; then
        net_config+=",ip=${IP}"
        [[ -n "$GATEWAY" ]] && net_config+=",gw=${GATEWAY}"
    else
        net_config+=",ip=dhcp"
    fi

    pct create "$CTID" "$template" \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --rootfs "${STORAGE}:${DISK}" \
        --net0 "$net_config" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 0 \
        || error "Failed to create container"

    msg "Container created successfully"
}

function setup_container() {
    msg "Starting container..."
    pct start "$CTID"
    sleep 5

    msg "Waiting for network..."
    local max_attempts=30
    local attempt=0
    while ! pct exec "$CTID" -- ping -c 1 google.com &> /dev/null; do
        ((attempt++))
        if [[ $attempt -ge $max_attempts ]]; then
            error "Network not available after $max_attempts attempts"
        fi
        sleep 2
    done

    msg "Installing packages..."
    pct exec "$CTID" -- apk update
    pct exec "$CTID" -- apk add --no-cache nginx git

    msg "Cloning website from GitHub..."
    pct exec "$CTID" -- rm -rf /var/www/html
    pct exec "$CTID" -- git clone "$REPO_URL" /var/www/html

    msg "Configuring nginx..."
    pct exec "$CTID" -- sh -c 'cat > /etc/nginx/http.d/default.conf << "NGINX"
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html;

    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }

    # Cache static assets
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|webp)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/javascript text/html;
    gzip_min_length 1000;
}
NGINX'

    msg "Enabling and starting nginx..."
    pct exec "$CTID" -- rc-update add nginx default
    pct exec "$CTID" -- rc-service nginx start

    msg "Creating update script..."
    pct exec "$CTID" -- sh -c 'cat > /usr/local/bin/update-site << "UPDATE"
#!/bin/sh
cd /var/www/html
git pull origin main
rc-service nginx reload
echo "Site updated successfully"
UPDATE'
    pct exec "$CTID" -- chmod +x /usr/local/bin/update-site
}

function show_summary() {
    local ip_addr
    if [[ "$IP" == "dhcp" ]]; then
        ip_addr=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    else
        ip_addr="${IP%/*}"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  Container ID:  ${BLUE}$CTID${NC}"
    echo -e "  Hostname:      ${BLUE}$HOSTNAME${NC}"
    echo -e "  IP Address:    ${BLUE}${ip_addr:-unknown}${NC}"
    echo ""
    echo -e "  Website URL:   ${BLUE}http://${ip_addr:-<ip-address>}/${NC}"
    echo ""
    echo -e "  ${YELLOW}To update the site:${NC}"
    echo -e "  pct exec $CTID -- update-site"
    echo ""
    echo -e "  ${YELLOW}To enter the container:${NC}"
    echo -e "  pct enter $CTID"
    echo ""
}

function interactive_setup() {
    header

    echo "This script will create an LXC container to host That Guy Laser Works website."
    echo ""

    # Get CTID
    local default_ctid=$(get_next_ctid)
    read -p "Container ID [$default_ctid]: " input_ctid
    CTID="${input_ctid:-$default_ctid}"

    # Get hostname
    read -p "Hostname [$HOSTNAME]: " input_hostname
    HOSTNAME="${input_hostname:-$HOSTNAME}"

    # Get IP configuration
    echo ""
    echo "Network Configuration:"
    echo "  1) DHCP (automatic)"
    echo "  2) Static IP"
    read -p "Select option [1]: " net_option

    if [[ "$net_option" == "2" ]]; then
        read -p "Static IP (CIDR format, e.g., 192.168.1.100/24): " IP
        read -p "Gateway: " GATEWAY
    fi

    # Get storage
    echo ""
    echo "Available storage:"
    pvesm status | grep -E "^[a-zA-Z]" | awk '{print "  - " $1}'
    read -p "Storage [$STORAGE]: " input_storage
    STORAGE="${input_storage:-$STORAGE}"

    echo ""
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo "  CTID:     $CTID"
    echo "  Hostname: $HOSTNAME"
    echo "  Memory:   ${MEMORY}MB"
    echo "  Disk:     ${DISK}GB"
    echo "  Cores:    $CORES"
    echo "  Storage:  $STORAGE"
    echo "  Network:  $IP"
    echo ""

    read -p "Proceed with installation? [Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

function main() {
    check_root
    check_proxmox

    # Interactive mode if no CTID provided
    if [[ -z "$CTID" ]]; then
        interactive_setup
    fi

    local template=$(select_template)
    create_container "$template"
    setup_container
    show_summary
}

main "$@"
