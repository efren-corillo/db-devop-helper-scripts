# db-devop-helper-scripts

Reusable DevOps and local development helper scripts for Docker Compose-based projects.

## Scripts

| Script | Status | Description |
| --- | --- | --- |
| [`dev.sh`](dev.sh) | Available | Local development CLI for managing Docker Compose stacks, automated Caddy local HTTPS trust, database/framework helpers, git hooks, and AI-assisted commit messages. |
| `deploy.sh` | Planned | Deployment helper script for automating production/staging releases and server rollout workflows. |

---

## `dev.sh`

`dev.sh` is a drop-in bash CLI intended to live in the root of a Docker Compose project (alongside `docker-compose.yml` and `.env` / `.env.example`).

### Prerequisites

- **Required**
  - Bash (`#!/usr/bin/env bash`)
  - Docker Engine and Docker Compose V2 (`docker compose`)
  - A `docker-compose.yml` and `.env` (or `.env.example`) in the same directory as `dev.sh`
- **Optional (feature-dependent)**
  - `openssl` and `curl` — certificate expiry detection, live leaf cert checks, and trusted HTTPS verification
  - `certutil` (`libnss3-tools`) — Linux Chrome/Chromium NSS database trust sync (`~/.pki/nssdb`)
  - `wslpath` and `certutil.exe` — Windows `CurrentUser` Root store sync under WSL2
  - `git` and `git-flow-avh` (AVH Edition) — automatic `.githooks` configuration and git-flow hook support
  - `agy` (Antigravity CLI) and a clipboard utility (`pbcopy`, `clip.exe`, `wl-copy`, `xclip`, or `xsel`) — `commit-msg` generation

### Setup

Copy `dev.sh` to your project root and make it executable:

```bash
chmod +x dev.sh
./dev.sh help
```

On startup, `dev.sh` automatically:
1. Configures `git config core.hooksPath .githooks` if inside a Git work tree (and warns if `git-flow-avh` is not installed).
2. For Docker stack commands, creates `.env` from `.env.example` if `.env` does not exist yet, then loads it into the environment. Standalone commands (`help`, `commit-msg`) work even without `.env` or `.env.example`.

### Environment Variables

Configure these in `.env` (defaults shown if unset):

| Variable | Default | Description |
| --- | --- | --- |
| `PROJECT` | `db-kanva` | Docker Compose project name and container prefix (`${PROJECT}-<service>`). |
| `DOMAIN` | `kanva.localhost` | Local HTTPS domain served by Caddy. |
| `HTTP_PORT` | `80` | Host HTTP port. |
| `HTTPS_PORT` | `443` | Host HTTPS port. |
| `POSTGRES_DB` | `db_kanva` | PostgreSQL database name used by `db psql`. |
| `POSTGRES_USER` | `postgres` | PostgreSQL user used by `db psql`. |
| `POSTGRES_PASSWORD` | `postgres` | PostgreSQL password. |

Expected Compose services for framework/service helpers: `caddy`, `api` (AdonisJS), `ui` (Expo), and `db` (PostgreSQL), with container names following `${PROJECT}-<service>`.

### Commands

```text
Usage: ./dev.sh <command> [args...]
```

| Command | Aliases | Description |
| --- | --- | --- |
| `up [services...]` | — | Start containers in detached mode. Automatically syncs Caddy's local HTTPS Root CA when starting all services or `caddy`. |
| `down [args...]` | — | Stop and remove containers and networks. |
| `restart [services...]` | — | Restart all or selected services. |
| `build [services...]` | — | Build or rebuild Docker images. |
| `logs [services...]` | — | Follow logs (`--tail=100`) for all or selected services. |
| `ps [args...]` | `status` | Show Compose container status and health. |
| `shell <service> [cmd...]` | — | Open an interactive shell (`bash` if available, else `sh`) or run a command inside a running container. |
| `ace <args...>` | — | Run AdonisJS Ace CLI (`node ace`) inside the `api` container. |
| `db [psql\|migrate\|seed\|fresh]` | `db:psql`, `db:migrate`, `db:seed`, `db:fresh` | Open `psql` in `db` (default), or run Lucid `migration:run`, `db:seed`, or `migration:fresh --seed` in `api`. |
| `expo <args...>` | — | Run Expo CLI (`npx expo`) inside the `ui` container. |
| `trust-cert [--force\|-f]` | — | Export Caddy's local Root CA, rotate expiring (within 24h) or forced certificates, sync host trust stores, check domain resolution, and verify trusted HTTPS. |
| `commit-msg` | `git-commit` | Generate a commit message via `agy` using the `git-commit` skill and copy it to the system clipboard (does not require Docker or `.env`/`.env.example`). |
| `clean [-y\|--yes]` | — | Stop the stack and remove named volumes (`docker compose down -v --remove-orphans`) with confirmation. |
| `help` | `-h`, `--help` | Show usage, active project/domain metadata, and available commands (does not require Docker or `.env`/`.env.example`). |

### Automated Local HTTPS Trust (`trust-cert`)

When starting Caddy via `./dev.sh up` (or running `./dev.sh trust-cert` directly), `dev.sh` exports Caddy's local Root CA to `docker/caddy/certs/caddy-local-root.crt`, checks Root CA and live leaf certificate validity (24-hour renewal window), and idempotently syncs host trust stores:

- **Linux**: Installs into the system trust store (`update-ca-certificates`, `update-ca-trust extract`, or `p11-kit trust anchor`, requiring `sudo`) and updates the Chrome/Chromium NSS database (`~/.pki/nssdb`) when `certutil` is available.
- **macOS**: Prunes stale rotated Root CAs by SHA-1 fingerprint and adds the active CA to `/Library/Keychains/System.keychain` (requiring `sudo`).
- **Windows (WSL2)**: Updates both the WSL2 Linux trust stores and the Windows `CurrentUser` Root store via `wslpath` and `certutil.exe`.

> **Additional Client Notes**
> - **Firefox**: Enable `security.enterprise_roots.enabled = true` in `about:config` (or import `docker/caddy/certs/caddy-local-root.crt` manually).
> - **Host Node.js CLIs**: Export `NODE_EXTRA_CA_CERTS="docker/caddy/certs/caddy-local-root.crt"`.

---

## Roadmap

- **`deploy.sh`**: Add a companion deployment helper script for managing builds, environment checks, and deployment pipelines across target environments.

## License

MIT License — see [LICENSE](LICENSE) for details.
