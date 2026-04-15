# AAI Portal

Shared VPS platform running multiple independent microservices/POC projects behind a single public domain with centralized Azure AD authentication.

## Architecture

The stack supports two deployment modes depending on whether this is the only Traefik on the host.

### Mode A — Shared VPS (current setup)

An outer Traefik already owns ports 80/443 on the host and forwards traffic via TCP SNI passthrough. `aai-traefik` has **no `ports:` mapping** — it is only reachable through the outer proxy.

```
Internet
  └─ Outer Traefik (ports 80/443 — TCP SNI passthrough for *.BASE_DOMAIN)
       └─ aai-traefik  (TLS termination, subdomain routing, Let's Encrypt)
            └─ aai-traefik-forward-auth  (ForwardAuth — Azure AD OIDC)
                 ├─ portal.BASE_DOMAIN   (landing page)
                 ├─ traefik.BASE_DOMAIN  (Traefik dashboard)
                 └─ <project>.BASE_DOMAIN  (independent project containers)
```

### Mode B — Standalone / isolated VPS

No outer proxy. `aai-traefik` binds directly to the host's ports 80/443. Add a `ports:` section to the `traefik` service in `docker-compose.yml`:

```yaml
traefik:
  ports:
    - "80:80"
    - "443:443"
```

Everything else (TLS via DNS-01, forward-auth, label patterns) works identically.

```
Internet
  └─ aai-traefik  (ports 80/443 — TLS termination, subdomain routing, Let's Encrypt)
       └─ aai-traefik-forward-auth  (ForwardAuth — Azure AD OIDC)
            ├─ portal.BASE_DOMAIN   (landing page)
            ├─ traefik.BASE_DOMAIN  (Traefik dashboard)
            └─ <project>.BASE_DOMAIN  (independent project containers)
```

---

**Three core services** (single `docker-compose.yml`):

| Service | Image | Purpose |
|---|---|---|
| `aai-traefik` | `traefik:v3` | Reverse proxy, TLS via Hostinger DNS-01, dynamic service discovery |
| `aai-traefik-forward-auth` | `thomseddon/traefik-forward-auth:2` | Azure AD OIDC, returns 307 on unauthenticated requests |
| `aai-portal` | custom nginx | Static landing page with live service health checker |

Authentication is enforced by Entra ID — access control is managed in the Azure portal (Enterprise Applications → AAI Platform → Users and groups), not in config files.

## Prerequisites

- Docker + Docker Compose
- The `aai-public` external network must exist on the host:
  ```bash
  docker network create aai-public
  ```
- A `shared.env` file in the **parent directory** (`../shared.env`) with non-secret platform config
- A `.env` file in this directory with secrets (see [Configuration](#configuration))
- `traefik/acme.json` must exist with permissions `600`:
  ```bash
  touch traefik/acme.json && chmod 600 traefik/acme.json
  ```

## Configuration

### `../shared.env` (committed, no secrets)

```env
BASE_DOMAIN=aai.example.com
ACME_EMAIL=admin@example.com
```

`BASE_DOMAIN` is the single source of truth — never hardcode domain names anywhere else.

### `.env` (gitignored, secrets only)

Copy the template and fill in real values:

```bash
cp .env.example .env
```

| Variable | Description |
|---|---|
| `HOSTINGER_API_TOKEN` | Hostinger API token for ACME DNS-01 challenge |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_CLIENT_SECRET` | App registration client secret |
| `COOKIE_SECRET` | Cookie signing secret — generate with `openssl rand -hex 32` |

## Usage

```bash
make up        # Build and start all services
make down      # Stop services
make restart   # Force-recreate all containers
make logs      # Follow container logs
make ps        # Show container status
make validate  # Dry-run: render compose config with variable substitution
```

## Adding a new project

Independent projects live in separate git repos under the sibling `projects/` directory. To integrate with the platform:

1. Declare `aai-public` as an external network in the project's `docker-compose.yml`:
   ```yaml
   networks:
     aai-public:
       external: true
   ```

2. Add these 6 Traefik labels to the service:
   ```yaml
   labels:
     - "traefik.enable=true"
     - "traefik.docker.network=aai-public"
     - "traefik.http.routers.<name>.rule=Host(`<subdomain>.${BASE_DOMAIN}`)"
     - "traefik.http.routers.<name>.tls.certresolver=letsencrypt"
     - "traefik.http.routers.<name>.middlewares=tfa@docker,secure-headers@file"
     - "traefik.http.services.<name>.loadbalancer.server.port=<port>"
   ```

3. Start the project with both env files:
   ```bash
   docker compose --env-file ../shared.env --env-file .env up -d --build
   ```

The service will be reachable at `https://<subdomain>.BASE_DOMAIN` and protected by Azure AD authentication.

## Directory structure

```
.
├── docker-compose.yml
├── Makefile
├── shared.env             # (in parent dir) non-secret platform config
├── .env                   # secrets, gitignored
├── .env.example           # template
├── traefik/
│   ├── traefik.yml.template        # rendered to traefik.yml at container start
│   ├── entrypoint-wrapper.sh       # runs envsubst then starts Traefik
│   ├── acme.json                   # gitignored, must be chmod 600
│   └── dynamic/
│       └── middlewares.yml         # secure-headers and other file-based middleware
├── portal/
│   ├── Dockerfile
│   ├── index.html
│   ├── config.json.template        # rendered to config.json at container start
│   ├── healthcheck.sh
│   └── entrypoint.sh
└── docs/
    ├── detailed_plan_OPUS.md               # 6-phase implementation plan
    ├── highlevel_architecture_discussion.md
    ├── shared_vps_architecture_discussion.md
    └── authentification_fix_with_Azure.md  # auth migration history and gotchas
```

## Further reading

**Guides** (`docs/guides/`):
- `docs/guides/new_project_greenfield.md` — scaffolding a new project from scratch
- `docs/guides/integrate_existing_project.md` — onboarding an existing git project
- `docs/guides/vps_operations.md` — manual VPS setup: cron jobs, log rotation, backups
- `docs/guides/authentification_fix_with_Azure.md` — auth migration history and known gotchas

**Architecture & planning** (`docs/architecture/`):
- `docs/architecture/detailed_plan_OPUS.md` — authoritative 6-phase implementation plan
- `docs/architecture/shared_vps_architecture_discussion.md` — nested Traefik and shared-VPS design decisions
- `docs/architecture/highlevel_architecture_discussion.md` — high-level architecture discussion
