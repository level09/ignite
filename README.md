# Ignite 🔥

One command to deploy Enferno-based Flask apps with automatic SSL.

## Quick Start

```bash
# Download and deploy
wget -qO /tmp/ignite.sh https://raw.githubusercontent.com/level09/ignite/main/ignite.sh
sudo DOMAIN=app.example.com bash /tmp/ignite.sh

# Or run interactively
wget -qO /tmp/ignite.sh https://raw.githubusercontent.com/level09/ignite/main/ignite.sh
sudo bash /tmp/ignite.sh
```

## What It Does

- Deploys [Enferno](https://github.com/level09/enferno) or [ReadyKit](https://github.com/level09/readykit) apps
- Automatic SSL via Caddy (zero config)
- Python 3.13 + uv package manager
- Redis for sessions and Celery
- systemd services with auto-restart
- UFW firewall (ports 22, 80, 443)
- SSH access for app user (scoped to service management)

### Security & Performance (Built-in)

- **SSH Hardening** - Key-only authentication, password login disabled
- **fail2ban** - SSH brute-force protection
- **Scoped Sudo** - App user can only restart its own services
- **HSTS** - Strict Transport Security with 1 year max-age
- **Security Headers** - X-Frame-Options, X-Content-Type-Options, XSS Protection
- **Permissions-Policy** - Disables geolocation, microphone, camera by default
- **Compression** - zstd + gzip for all responses
- **Static Caching** - 1 year cache for `/static/*` assets
- **JSON Logging** - Structured logs at `/var/log/caddy/{domain}.log`
- **Server Header Removed** - Hides Caddy version from responses

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | required | Your domain name |
| `REPO` | `level09/enferno` | GitHub repository |
| `BRANCH` | `master` | Git branch |
| `DB` | `sqlite` | Database: `sqlite` or `postgres` |
| `ADMIN_EMAIL` | `admin@{DOMAIN}` | Admin login email |
| `ADMIN_PASSWORD` | auto-generated | Admin password |
| `SKIP_SSL` | `false` | Skip SSL for localhost/IP testing |

## Examples

```bash
# Deploy ReadyKit with PostgreSQL
DOMAIN=app.example.com REPO=level09/readykit DB=postgres ./ignite.sh

# Deploy with custom admin
DOMAIN=app.example.com ADMIN_EMAIL=me@example.com ./ignite.sh

# Local testing (no SSL)
DOMAIN=localhost SKIP_SSL=true ./ignite.sh
```

## Requirements

- Ubuntu 22.04 or 24.04
- Root access
- Domain pointing to server (for SSL)

## After Deployment

- App: `https://your-domain.com`
- SSH: `ssh {user}@your-domain.com` (uses your existing SSH key)
- Credentials: `/home/{user}/.credentials`
- App Logs: `journalctl -u {domain}.service`
- Access Logs: `/var/log/caddy/{domain}.log` (JSON format)

## Optional: Rate Limiting

Caddy supports rate limiting via plugin. To enable:

```bash
# Install Caddy with rate-limit plugin
caddy add-package github.com/mholt/caddy-ratelimit

# Edit /etc/caddy/Caddyfile and add inside your domain block:
rate_limit {remote.ip} 100r/s
```

For auth endpoints, add stricter limits:
```caddy
@auth path /login* /register* /reset*
rate_limit @auth {remote.ip} 5r/m
```

## License

MIT
