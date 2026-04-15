# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AAI_portal is an **infrastructure-as-code project** that provides a shared VPS platform for running multiple independent microservices/POC projects behind a single public domain with centralized authentication. All 6 phases are complete and running in production. `docs/` contains detailed architecture discussions and a 2000+ line phased implementation plan.

## Architecture

```
Internet → Outer Traefik (TCP SNI passthrough for *.${BASE_DOMAIN})
              → aai-traefik / Inner Traefik (TLS termination, subdomain routing)
                  → aai-traefik-forward-auth (ForwardAuth — Azure AD OIDC, returns 307 not 401)
                      → Portal (static nginx, landing page)
                      → project-N.${BASE_DOMAIN} (independent project containers)
```

**Three core infrastructure services** (all run via a single `docker-compose.yml`):
1. **Traefik v3.1** — reverse proxy, SSL via Let's Encrypt (DNS-01 challenge via Hostinger), dynamic service discovery via Docker labels
2. **traefik-forward-auth** (`aai-traefik-forward-auth`) — ForwardAuth middleware, Azure AD OIDC. Returns `307` on unauthenticated requests (Traefik passes this straight to the browser — no errors middleware, no loop). Uses `AUTH_HOST=auth.${BASE_DOMAIN}` mode. Access control via Entra ID user assignment (no email whitelist in config).
3. **Portal** — nginx serving static HTML + client-side JS health checker + in-browser guides viewer

**Independent projects** live in separate git repos under `projects/`. They integrate by:
- Declaring `aai-public` as an external Docker network
- Adding 6 Traefik labels to their `docker-compose.yml`

## Key Conventions

### Environment Variables
Two env files are always loaded in sequence:
```bash
docker compose --env-file ../shared.env --env-file .env up -d --build
```
- `shared.env` — non-secret platform config, committed to git (`BASE_DOMAIN`, `ACME_EMAIL`, etc.)
- `.env` — secrets only, gitignored (`AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, `COOKIE_SECRET`, etc.)
- `.env.example` — template committed to git

`BASE_DOMAIN` is the single source of truth for domain names — never hardcode domain names anywhere.

### Traefik Label Pattern (for all routed services)
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=aai-public"
  - "traefik.http.routers.<name>.rule=Host(`<subdomain>.${BASE_DOMAIN}`)"
  - "traefik.http.routers.<name>.tls.certresolver=letsencrypt"
  - "traefik.http.routers.<name>.middlewares=tfa@docker,secure-headers@file"
  - "traefik.http.services.<name>.loadbalancer.server.port=<port>"
```

### Template Substitution
Three layers of variable substitution at different stages:
- `docker-compose.yml` — Docker Compose interpolates `${VAR}` at runtime
- `traefik.yml.template` → `traefik.yml` — `envsubst` via `entrypoint-wrapper.sh` at container start
- `portal/config.json.template` → `config.json` — `envsubst` via `portal/entrypoint.sh` at container start

### Makefile Targets
```bash
make up        # Start all services (builds if needed)
make down      # Stop services
make restart   # Force recreate containers
make logs      # Follow container logs
make validate  # Dry-run: check docker-compose config with env interpolation
```

### Network Isolation
- `aai-public` is the shared external Docker network (all front-facing containers)
- Projects can have additional internal networks for databases/caches
- Only containers that need Traefik routing attach to `aai-public`

## Directory Structure (target state)

```
infrastructure/          # This repo
├── docker-compose.yml
├── .env / .env.example
├── shared.env
├── Makefile
├── traefik/
│   ├── traefik.yml.template
│   ├── entrypoint-wrapper.sh
│   ├── acme.json            # gitignored, chmod 600
│   └── dynamic/
│       └── middlewares.yml
│   # traefik-forward-auth has no config files — entirely configured via env vars
├── portal/
│   ├── Dockerfile
│   ├── nginx.conf
│   ├── index.html
│   ├── config.json.template
│   ├── healthcheck.sh
│   └── entrypoint.sh
└── docs/
    ├── architecture/
    │   ├── detailed_plan_OPUS.md                # 6-phase implementation plan
    │   ├── highlevel_architecture_discussion.md
    │   ├── shared_vps_architecture_discussion.md
    │   ├── authentification_fix_with_Azure.md   # auth migration history and gotchas
    │   └── portal_guides_feature.md             # guides viewer design decisions
    └── guides/                                  # served in-browser via the portal
        ├── new_project_greenfield.md            # how to scaffold a new project
        ├── integrate_existing_project.md        # how to onboard an existing repo
        └── vps_operations.md                    # backup, cleanup, log rotation

projects/                # Sibling directory, separate git repos
├── project-1/
└── project-2/
```

## Implementation Plan

The `docs/detailed_plan_OPUS.md` contains the authoritative 6-phase implementation plan:
- **Phase 1**: VPS provisioning, DNS, Docker setup, directory layout
- **Phase 2**: Traefik setup, SSL, test container
- **Phase 3**: traefik-forward-auth, Azure AD OIDC, Entra ID user assignment (see `docs/authentification_fix_with_Azure.md`)
- **Phase 4**: Portal (static site, health checker, config templating)
- **Phase 5**: Project template (reusable scaffolding for new POCs)
- **Phase 6**: Hardening, backups, monitoring

When generating or modifying infrastructure files, consult `docs/architecture/detailed_plan_OPUS.md` for the exact intended configuration and `docs/architecture/shared_vps_architecture_discussion.md` for shared-VPS / nested Traefik scenarios. For project onboarding guides see `docs/guides/`.

## Authentication Notes

traefik-forward-auth runs in `AUTH_HOST` mode (`auth.${BASE_DOMAIN}`). Critical gotchas:

- The auth host router **must** have the `tfa@docker` ForwardAuth middleware applied — without it, `X-Forwarded-Uri` is empty and the `/_oauth` callback is never detected, causing an infinite redirect loop to Microsoft.
- Container is named `aai-traefik-forward-auth` (not `traefik-forward-auth`) to avoid collision with the outer VPS Traefik's own forward-auth container.
- traefik-forward-auth's email whitelist comparison is case-sensitive; to avoid issues, access control is handled entirely via Entra ID (Enterprise Application → Assignment required = Yes). No `WHITELIST`/`DOMAINS` config needed.

See `docs/architecture/authentification_fix_with_Azure.md` for the full migration history and auth flow diagram.

## Security Notes

- `acme.json` must have `chmod 600` or Traefik will refuse to start
- Docker socket should be mounted read-only on Traefik when possible
- Access is controlled by Entra ID user assignment (not an email whitelist in `.env`)
- Session cookies use `COOKIE_DOMAIN=${BASE_DOMAIN}` for SSO across all subdomains
- Traefik dashboard itself is protected behind traefik-forward-auth
- `COOKIE_SECRET` must be a strong random value — regenerating it invalidates all sessions
