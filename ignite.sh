#!/bin/bash
set -e

VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Utilities
log()   { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
info()  { echo -e "${CYAN}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
error() { echo -e "${RED}✗${NC}  $1" >&2; exit 1; }

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -ne "${BOLD}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} $1..."
}

step_done() { echo -e " ${GREEN}✓${NC}"; }

# Header
header() {
    echo ""
    echo -e "${BOLD}🔥 Ignite v${VERSION}${NC} - Deploy Enferno Apps"
    echo "────────────────────────────────────────"
    echo ""
}

# Interactive setup
interactive_setup() {
    header

    read -p "? Domain name: " DOMAIN
    [ -z "$DOMAIN" ] && error "Domain is required"

    read -p "? Git repository [level09/enferno]: " input
    REPO="${input:-level09/enferno}"

    read -p "? Branch [master]: " input
    BRANCH="${input:-master}"

    read -p "? Database (sqlite/postgres) [sqlite]: " input
    DB="${input:-sqlite}"

    echo ""
    echo "────────────────────────────────────────"
    echo ""
}

# Validation
validate() {
    [ "$EUID" -eq 0 ] || error "Must run as root (use sudo)"
    [ -z "$DOMAIN" ] && error "DOMAIN is required"

    # Derive defaults
    APP_USER="${APP_USER:-${DOMAIN%%.*}}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 16)}"
    PYTHON_PORT="${PYTHON_PORT:-5000}"
    BRANCH="${BRANCH:-master}"
    REPO="${REPO:-level09/enferno}"
    DB="${DB:-sqlite}"
    SKIP_SSL="${SKIP_SSL:-false}"

    APP_DIR="/home/${APP_USER}/${DOMAIN}"
    GIT_URL="https://github.com/${REPO}.git"
}

# Install system packages
install_packages() {
    step "Installing system packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq \
        build-essential git curl wget \
        python3-dev libjpeg8-dev libzip-dev libffi-dev \
        libxslt1-dev libpq-dev libssl-dev \
        redis-server >/dev/null 2>&1
    step_done
}

# Install Caddy
install_caddy() {
    step "Installing Caddy"
    if ! command -v caddy &>/dev/null; then
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1
        curl -sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        chmod o+r /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq >/dev/null && apt-get install -y -qq caddy >/dev/null 2>&1
    fi
    step_done
}

# Setup Redis
setup_redis() {
    step "Setting up Redis"
    systemctl enable --now redis-server >/dev/null 2>&1
    step_done
}

# Install PostgreSQL (if needed)
install_postgres() {
    if [ "$DB" = "postgres" ]; then
        step "Installing PostgreSQL"
        apt-get install -y -qq postgresql postgresql-contrib >/dev/null 2>&1
        systemctl enable --now postgresql >/dev/null 2>&1

        # Create database and user
        sudo -u postgres createuser "$APP_USER" 2>/dev/null || true
        sudo -u postgres createdb "$APP_USER" -O "$APP_USER" 2>/dev/null || true
        step_done
    fi
}

# Create application user
create_user() {
    step "Creating user '${APP_USER}'"
    if ! id "$APP_USER" &>/dev/null; then
        getent group "$APP_USER" >/dev/null || groupadd "$APP_USER"
        useradd -m -s /bin/bash -g "$APP_USER" "$APP_USER"
    fi
    # Add caddy to app user's group so it can serve static files
    usermod -aG "$APP_USER" caddy 2>/dev/null || true
    step_done
}

# Setup SSH access for app user
setup_ssh() {
    step "Setting up SSH access"
    local user_ssh="/home/${APP_USER}/.ssh"
    mkdir -p "$user_ssh"

    # Copy root's authorized keys if they exist
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys "$user_ssh/"
    fi

    chown -R "${APP_USER}:${APP_USER}" "$user_ssh"
    chmod 700 "$user_ssh"
    chmod 600 "$user_ssh/authorized_keys" 2>/dev/null || true

    # Sudoers: only allow managing app services
    echo "${APP_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start ${DOMAIN}.service, /bin/systemctl stop ${DOMAIN}.service, /bin/systemctl restart ${DOMAIN}.service, /bin/systemctl status ${DOMAIN}.service, /bin/systemctl start ${DOMAIN}-celery.service, /bin/systemctl stop ${DOMAIN}-celery.service, /bin/systemctl restart ${DOMAIN}-celery.service, /bin/systemctl status ${DOMAIN}-celery.service" > "/etc/sudoers.d/${APP_USER}"
    chmod 440 "/etc/sudoers.d/${APP_USER}"

    # Allow app user to read logs without sudo
    usermod -aG systemd-journal "$APP_USER" 2>/dev/null || true
    step_done
}

# Clone repository
clone_repo() {
    step "Cloning repository"
    if [ -d "$APP_DIR" ]; then
        rm -rf "$APP_DIR"
    fi
    sudo -u "$APP_USER" git clone -q --branch "$BRANCH" "$GIT_URL" "$APP_DIR"
    step_done
}

# Install Python and uv
setup_python() {
    step "Setting up Python 3.13 + uv"

    # Add deadsnakes PPA for Python 3.13
    if ! command -v python3.13 &>/dev/null; then
        apt-get install -y -qq software-properties-common >/dev/null 2>&1
        add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1
        apt-get update -qq >/dev/null
        apt-get install -y -qq python3.13 python3.13-dev python3.13-venv >/dev/null 2>&1
    fi

    # Install uv
    if [ ! -f /usr/local/bin/uv ]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
        cp ~/.local/bin/uv /usr/local/bin/ 2>/dev/null || cp ~/.cargo/bin/uv /usr/local/bin/ 2>/dev/null || true
        chmod 755 /usr/local/bin/uv
    fi

    # Setup venv and install deps with Python 3.13
    sudo -u "$APP_USER" bash -c "cd $APP_DIR && /usr/local/bin/uv sync --python 3.13 --no-dev --extra wsgi" >/dev/null 2>&1
    step_done
}

# Generate .env file
generate_env() {
    step "Generating .env file"

    local db_uri
    if [ "$DB" = "postgres" ]; then
        db_uri="postgresql:///${APP_USER}"
    else
        db_uri="sqlite:///enferno.sqlite3"
    fi

    cat > "${APP_DIR}/.env" << EOF
FLASK_APP=run.py
FLASK_ENV=production
SECRET_KEY=$(openssl rand -hex 32)
SECURITY_TOTP_SECRETS=$(openssl rand -hex 32),$(openssl rand -hex 32)
SECURITY_PASSWORD_SALT=$(openssl rand -hex 32)
SQLALCHEMY_DATABASE_URI=${db_uri}
REDIS_URL=redis://localhost:6379/0
SERVER_NAME=${DOMAIN}
SESSION_TYPE=redis
SESSION_REDIS=redis://localhost:6379/1
CELERY_BROKER_URL=redis://localhost:6379/2
CELERY_RESULT_BACKEND=redis://localhost:6379/3
EOF

    chown "$APP_USER:$APP_USER" "${APP_DIR}/.env"
    chmod 600 "${APP_DIR}/.env"
    step_done
}

# Initialize database
init_database() {
    step "Initializing database"
    sudo -u "$APP_USER" bash -c "cd $APP_DIR && export FLASK_APP=run.py && /usr/local/bin/uv run flask create-db" >/dev/null 2>&1
    step_done
}

# Create admin user
create_admin() {
    step "Creating admin user"
    sudo -u "$APP_USER" bash -c "cd $APP_DIR && export FLASK_APP=run.py && /usr/local/bin/uv run flask install -e '${ADMIN_EMAIL}' -p '${ADMIN_PASSWORD}'" >/dev/null 2>&1

    # Save credentials
    cat > "/home/${APP_USER}/.credentials" << EOF
Ignite Deployment Credentials
─────────────────────────────
Domain: ${DOMAIN}
Admin Email: ${ADMIN_EMAIL}
Admin Password: ${ADMIN_PASSWORD}
─────────────────────────────
EOF
    chown "$APP_USER:$APP_USER" "/home/${APP_USER}/.credentials"
    chmod 600 "/home/${APP_USER}/.credentials"
    step_done
}

# Create uwsgi.ini
create_uwsgi_config() {
    step "Creating uwsgi config"
    cat > "${APP_DIR}/uwsgi.ini" << EOF
[uwsgi]
module = run:app
processes = 4
http = 127.0.0.1:${PYTHON_PORT}
die-on-term = true
EOF
    chown "$APP_USER:$APP_USER" "${APP_DIR}/uwsgi.ini"
    step_done
}

# Create systemd service
create_systemd_service() {
    step "Creating systemd service"

    # Main app service
    cat > "/etc/systemd/system/${DOMAIN}.service" << EOF
[Unit]
Description=Enferno App - ${DOMAIN}
After=network.target redis-server.service

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/.venv/bin/uwsgi --ini uwsgi.ini
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # Celery service
    cat > "/etc/systemd/system/${DOMAIN}-celery.service" << EOF
[Unit]
Description=Celery Worker - ${DOMAIN}
After=network.target redis-server.service

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/.venv/bin/celery -A enferno.tasks worker -B --autoscale=2,4
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    step_done
}

# Configure Caddy
configure_caddy() {
    step "Configuring Caddy"

    if [ "$SKIP_SSL" = "true" ] || [ "$DOMAIN" = "localhost" ]; then
        # HTTP only (for localhost/IP testing)
        cat > /etc/caddy/Caddyfile << EOF
:80 {
    # Compression
    encode zstd gzip

    # Security headers
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
        -Server
    }

    # Static files with caching
    handle_path /static/* {
        root * ${APP_DIR}/enferno/static
        file_server
        header Cache-Control "public, max-age=31536000, immutable"
    }

    # Health check (no logging)
    handle /health {
        reverse_proxy 127.0.0.1:${PYTHON_PORT}
    }

    # App
    reverse_proxy 127.0.0.1:${PYTHON_PORT} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    # Logging
    log {
        output file /var/log/caddy/${DOMAIN}.log {
            roll_size 10mb
            roll_keep 5
        }
        format json
    }
}
EOF
    else
        # HTTPS with automatic SSL
        cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    # Compression
    encode zstd gzip

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
        -Server
    }

    # Static files with caching
    handle_path /static/* {
        root * ${APP_DIR}/enferno/static
        file_server
        header Cache-Control "public, max-age=31536000, immutable"
    }

    # Health check (no logging)
    handle /health {
        reverse_proxy 127.0.0.1:${PYTHON_PORT}
    }

    # App
    reverse_proxy 127.0.0.1:${PYTHON_PORT} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    # Logging
    log {
        output file /var/log/caddy/${DOMAIN}.log {
            roll_size 10mb
            roll_keep 5
        }
        format json
    }
}
EOF
    fi

    # Create log directory
    mkdir -p /var/log/caddy
    chown caddy:caddy /var/log/caddy

    step_done
}

# Harden SSH
harden_ssh() {
    step "Hardening SSH"

    # Key-only authentication
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    systemctl restart ssh >/dev/null 2>&1

    # Brute-force protection
    apt-get install -y -qq fail2ban >/dev/null 2>&1
    systemctl enable --now fail2ban >/dev/null 2>&1
    step_done
}

# Setup firewall
setup_firewall() {
    step "Configuring firewall"
    if command -v ufw &>/dev/null; then
        ufw --force enable >/dev/null 2>&1
        ufw allow 22/tcp >/dev/null 2>&1
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
    fi
    step_done
}

# Start all services
start_services() {
    step "Starting services"
    systemctl enable --now "${DOMAIN}.service" >/dev/null 2>&1
    systemctl enable --now "${DOMAIN}-celery.service" >/dev/null 2>&1
    systemctl enable --now caddy >/dev/null 2>&1
    systemctl restart caddy >/dev/null 2>&1
    step_done
}

# Success message
success_message() {
    local url
    if [ "$SKIP_SSL" = "true" ] || [ "$DOMAIN" = "localhost" ]; then
        url="http://${DOMAIN}"
    else
        url="https://${DOMAIN}"
    fi

    echo ""
    echo "────────────────────────────────────────"
    echo -e "${GREEN}${BOLD}🚀 Deployed!${NC} ${url}"
    echo ""
    echo -e "   ${BOLD}SSH:${NC} ssh ${APP_USER}@${DOMAIN}"
    echo -e "   ${BOLD}Email:${NC} ${ADMIN_EMAIL}"
    echo -e "   ${BOLD}Password:${NC} (saved to /home/${APP_USER}/.credentials)"
    echo "────────────────────────────────────────"
    echo ""
}

# Main
main() {
    CURRENT_STEP=0
    TOTAL_STEPS=16

    # Check if interactive mode (no DOMAIN set)
    if [ -z "$DOMAIN" ]; then
        # Can't do interactive if stdin is not a terminal (e.g., curl | bash)
        if [ ! -t 0 ]; then
            echo -e "${RED}Error:${NC} DOMAIN is required when running non-interactively"
            echo ""
            echo "Usage: wget -qO /tmp/ignite.sh https://raw.githubusercontent.com/level09/ignite/main/ignite.sh && sudo DOMAIN=example.com bash /tmp/ignite.sh"
            exit 1
        fi
        interactive_setup
    else
        header
    fi

    validate

    install_packages
    install_caddy
    setup_redis
    install_postgres
    create_user
    setup_ssh
    clone_repo
    setup_python
    generate_env
    init_database
    create_admin
    create_uwsgi_config
    create_systemd_service
    configure_caddy
    harden_ssh
    setup_firewall
    start_services

    success_message
}

main "$@"
