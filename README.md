# Ignite 🔥

One command to deploy Enferno-based Flask apps with automatic SSL.

## Quick Start

```bash
# One-liner
curl -sSL https://raw.githubusercontent.com/level09/ignite/main/ignite.sh | sudo DOMAIN=app.example.com bash

# Or download and run interactively
wget https://raw.githubusercontent.com/level09/ignite/main/ignite.sh
sudo bash ignite.sh
```

## What It Does

- Deploys [Enferno](https://github.com/level09/enferno) or [ReadyKit](https://github.com/level09/readykit) apps
- Automatic SSL via Caddy (zero config)
- Python 3.13 + uv package manager
- Redis for sessions and Celery
- systemd services with auto-restart
- UFW firewall (ports 22, 80, 443)
- SSH access with sudo for app user

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
- Logs: `journalctl -u {domain}.service`

## License

MIT
