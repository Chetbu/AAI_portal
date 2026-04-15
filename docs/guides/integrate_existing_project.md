# Integrating an Existing Git Project into the AAI Infrastructure

This guide covers everything needed to bring an existing project onto the platform — both the changes required in the **project repo itself** and the **admin steps** in the infrastructure repo.

---

## Overview

The platform handles TLS, routing, and authentication entirely at the Traefik layer. Your application does not need to know it is behind a proxy, handle HTTPS, or do anything auth-related. The only requirements are:

- Your container joins the shared `aai-public` Docker network
- Traefik labels are declared on your service
- Your container has an explicit name following the `aai-` naming convention

---

## Part 1 — Changes in the Project Repo

### 1.1 Choose a slug

The slug is used as the subdomain, the Traefik router name, and the container name suffix. It must:

- Use **hyphens only** — underscores are invalid in DNS hostnames and Let's Encrypt will reject the certificate request
- Be lowercase and URL-safe
- Be unique across all projects on the platform

```
# Good
pipeline
my-project
llm-chatbot

# Bad — will cause ACME certificate errors
my_project
llm_chatbot
```

### 1.2 Update `docker-compose.yml`

Three things to add: a `container_name`, the `aai-public` network, and the 6 Traefik labels.

```yaml
services:
  app:
    build: .
    container_name: aai-<slug>        # ← required — use aai- prefix for consistency
    expose:
      - "<port>"                       # expose to Docker network only, NOT ports:
    environment:
      # ... your existing env vars ...
    volumes:
      # ... your existing volumes ...
    networks:
      - aai-public                     # ← add to existing networks if any
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=aai-public"
      - "traefik.http.routers.<slug>.rule=Host(`<slug>.${BASE_DOMAIN}`)"
      - "traefik.http.routers.<slug>.tls.certresolver=letsencrypt"
      - "traefik.http.routers.<slug>.middlewares=tfa@docker,secure-headers@file"
      - "traefik.http.services.<slug>.loadbalancer.server.port=<port>"
    restart: unless-stopped

networks:
  aai-public:
    external: true       # ← declares the shared network as external
  # keep any existing internal networks you already had
```

**Why `expose` and not `ports`?**
`ports` binds to the host and makes the service publicly accessible, bypassing Traefik entirely. `expose` only makes the port reachable on the Docker network — Traefik connects to it internally.

**Why `container_name: aai-<slug>`?**
Without an explicit `container_name`, Docker Compose generates one like `<directory>-app-1`. The portal's health checker (and any internal service-to-service communication) reaches containers by name on `aai-public` — an unpredictable name breaks this.

**Replace in all 6 labels:**
- `<slug>` — your chosen slug (e.g. `pipeline`)
- `<port>` — the port your app listens on internally (e.g. `8742`)
- `${BASE_DOMAIN}` — keep as-is, Docker Compose interpolates it from `shared.env` at startup

### 1.3 Add a `Makefile`

Copy the platform Makefile template into your repo:

```bash
cp /opt/aai/infrastructure/docs/project-template/Makefile.template Makefile
```

Or create it manually:

```makefile
SHARED_ENV := $(shell cd ../.. && pwd)/shared.env

.PHONY: up down restart logs ps build

up:
	docker compose --env-file $(SHARED_ENV) --env-file .env up -d --build

down:
	docker compose --env-file $(SHARED_ENV) --env-file .env down

restart:
	docker compose --env-file $(SHARED_ENV) --env-file .env up -d --force-recreate --build

logs:
	docker compose --env-file $(SHARED_ENV) --env-file .env logs -f

ps:
	docker compose --env-file $(SHARED_ENV) --env-file .env ps

build:
	docker compose --env-file $(SHARED_ENV) --env-file .env build --no-cache
```

`SHARED_ENV` points to `../..` because projects are expected to live at `/opt/aai/projects/<slug>/`, making `shared.env` two levels up at `/opt/aai/shared.env`. If you clone your repo elsewhere, this path will be wrong.

**Commit the Makefile** to the repo so anyone cloning it gets the correct setup out of the box.

### 1.4 Add a health endpoint (recommended)

The portal dashboard shows a live status badge for each project. It works by curling each project's `healthInternal` URL from inside the portal container every 30 seconds.

Your app should expose a `/health` route that returns HTTP 200. The response body can be anything — a simple JSON is conventional:

```json
{"status": "ok", "service": "<slug>"}
```

This endpoint is called internally (Docker hostname, no auth, no TLS) so it requires no special handling. If you skip it, the portal will show the project card without a health badge.

### 1.5 Add a `.env.example`

If your project requires secrets, commit a `.env.example` with placeholder values. The actual `.env` should be gitignored.

### 1.6 Add a `portal.json`

Create a `portal.json` at the root of your project repo (alongside `docker-compose.yml`) and commit it. The portal reads this file to register the project automatically — no manual edit of the infrastructure repo is needed.

```json
{
  "slug": "<slug>",
  "name": "Human-readable project name",
  "description": "One-line description of what this project does",
  "owner": "Name or team",
  "port": <port>,
  "repo": "https://github.com/yourorg/<repo>"
}
```

| Field | Required | Notes |
|---|---|---|
| `slug` | Yes | Must match the slug in your Traefik labels and `container_name` |
| `name` | Yes | Display name on the portal card |
| `description` | No | Short description shown on the card |
| `owner` | No | Team or person responsible |
| `port` | Yes | The single port the container exposes; used for health checks and port conflict detection |
| `repo` | No | Adds a "Repository" button to the portal card |

The portal derives the public URL (`https://<slug>.BASE_DOMAIN`) and health check URL (`http://aai-<slug>:<port>/health`) automatically. If `/health` doesn't return HTTP 200 the card shows as down. You never need to hardcode domain names.

---

## Part 2 — Admin Steps in the Infrastructure Repo

### 2.1 Clone the project on the VPS

Projects must live under `/opt/aai/projects/` for the Makefile's `SHARED_ENV` path to resolve correctly:

```bash
cd /opt/aai/projects
git clone <repo-url> <slug>
cd <slug>
```

### 2.2 Create the `.env`

```bash
cp .env.example .env
# fill in real values
```

If the project has no secrets, create an empty file:

```bash
touch .env
```

Docker Compose requires the file to exist even if it is empty.

### 2.3 Start the project

```bash
make up
make ps    # confirm aai-<slug> shows "Up"
```

### 2.4 Verify routing and auth

Open a browser and navigate to `https://<slug>.BASE_DOMAIN`. You should be redirected to the Azure AD login (or pass through if already authenticated), then land on the project's UI.

### 2.5 Reload the portal

The `portal.json` committed in the project repo is already present after the `git clone` in step 2.1. The portal discovers it automatically on startup — no changes to the infrastructure repo are needed.

### 2.6 Reload the portal

```bash
cd /opt/aai/infrastructure
make restart
```

The portal container re-renders `config.json` with the updated template on startup. Within 30 seconds the health checker will make its first request and the status badge will appear.

---

## Quick reference checklist

**In the project repo:**
```
[  ] Slug uses hyphens only (no underscores)
[  ] container_name: aai-<slug>
[  ] expose: - "<port>"  (not ports:)
[  ] 6 Traefik labels added
[  ] aai-public declared as external network
[  ] Makefile committed
[  ] /health endpoint implemented
[  ] .env.example committed, .env gitignored
[  ] portal.json committed
```

**Admin steps on the VPS:**
```
[  ] Repo cloned to /opt/aai/projects/<slug>/
[  ] .env created
[  ] make up && make ps shows container "Up"
[  ] Browser test: routing and auth work
[  ] make restart run in infrastructure directory
[  ] Portal card appears with correct status
```
