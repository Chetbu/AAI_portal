# Creating a New Greenfield Project on the AAI Infrastructure

This guide covers everything needed to scaffold a brand new project from scratch — both what gets generated automatically by the scaffold script and what the admin needs to do in the infrastructure repo.

For bringing an **existing** repo onto the platform, see `integrate_existing_project.md` instead.

---

## Overview

The platform provides a scaffold script (`scripts/new-project.sh`) that generates a ready-to-run project directory from a template. It handles the Makefile, docker-compose labels, container naming, a placeholder app with a `/health` endpoint, and the initial git commit. You then replace the placeholder app with your actual code.

---

## Part 1 — Scaffold the Project

### 1.1 Choose a slug

The slug is used as the subdomain, the Traefik router name, and the container name suffix. It must:

- Use **hyphens only** — underscores are invalid in DNS hostnames and Let's Encrypt will reject the certificate request
- Be lowercase and URL-safe
- Be unique across all projects on the platform

```
# Good
my-project
llm-chatbot

# Bad — will cause ACME certificate errors
my_project
llm_chatbot
```

### 1.2 Run the scaffold script

From the infrastructure directory on the VPS:

```bash
./scripts/new-project.sh <slug> "<name>" [port] [owner]
```

| Argument | Required | Description |
|---|---|---|
| `slug` | Yes | URL-safe identifier (hyphens only) |
| `name` | Yes | Human-readable project name (quote if it contains spaces) |
| `port` | No | Port your app will listen on (default: `8000`) |
| `owner` | No | Name or team responsible (default: `unassigned`) |

Example:
```bash
./scripts/new-project.sh llm-chatbot "LLM Chatbot" 8000 alice
```

This creates `/opt/aai/projects/llm-chatbot/` with:

```
llm-chatbot/
├── docker-compose.yml      # pre-configured with Traefik labels
├── Makefile                # platform-standard make targets
├── Dockerfile              # python:3.12-slim placeholder
├── portal.json             # portal registration metadata (commit this)
├── .gitignore
├── .env.example
├── .env                    # copy of .env.example, gitignored
└── src/
    └── main.py             # placeholder app with / and /health endpoints
```

The script also initialises a git repo and makes an initial commit.

### 1.3 What the script generates

**`docker-compose.yml`** — fully configured with:
- `container_name: aai-<slug>` for predictable naming
- `expose` (not `ports`) so the app is only reachable through Traefik
- All 6 Traefik labels with correct slug, port, and `tfa@docker` middleware
- `aai-public` declared as an external network
- An `internal` bridge network for future databases or caches

**`Makefile`** — standard platform targets (`up`, `down`, `restart`, `logs`, `ps`, `build`) with `SHARED_ENV` pointing to `../..`

**`src/main.py`** — minimal Python HTTP server with:
- `/` — placeholder HTML page
- `/health` — returns `{"status": "ok", "service": "<slug>"}` with HTTP 200

**`Dockerfile`** — `python:3.12-slim`, copies `src/`, exposes the port

The script also generates `portal.json` — the metadata file the portal reads to register this project. You will fill in `description` and `repo` in Part 4.

### 1.4 Verify the generated files

```bash
cd /opt/aai/projects/<slug>

# No placeholder strings should remain
grep -r "__PROJECT" docker-compose.yml   # should return nothing

# Middleware must be tfa@docker
grep "middlewares" docker-compose.yml
# → traefik.http.routers.<slug>.middlewares=tfa@docker,secure-headers@file
```

---

## Part 2 — Replace the Placeholder App

The scaffold gives you a working skeleton. Replace `src/main.py` and `Dockerfile` with your actual application.

### Keep in mind

- **Keep `container_name: aai-<slug>`** — do not remove or rename it
- **Keep `expose: - "<port>"`** and update the port in both the Dockerfile/app and the Traefik label if you change it
- **Keep the `/health` endpoint** — it powers the portal status badge; it just needs to return HTTP 200
- **Do not change `ports:` to bind to the host** — this bypasses Traefik and exposes the app without auth
- Your app does not need to handle HTTPS or authentication — Traefik does both before requests reach your container

### Adding project-specific secrets

Add variables to `.env.example` (committed) and `.env` (gitignored):

```bash
# .env.example
DATABASE_URL=<your-database-url>
API_KEY=<your-api-key>
```

Reference them in `docker-compose.yml`:

```yaml
environment:
  - DATABASE_URL=${DATABASE_URL}
  - API_KEY=${API_KEY}
```

### Adding a database or cache

The generated `docker-compose.yml` has a commented-out Postgres example. Uncomment and adapt it. Internal services (databases, caches) should only join the `internal` network — not `aai-public` — so they are never reachable from outside the project.

```yaml
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: appdb
      POSTGRES_USER: user
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - internal      # ← internal only, NOT aai-public

volumes:
  db-data:
```

---

## Part 3 — Start and Verify

### 3.1 Start the project

```bash
cd /opt/aai/projects/<slug>
make up
make ps    # confirm aai-<slug> shows "Up"
```

### 3.2 Check logs

```bash
make logs
```

### 3.3 Verify routing and auth

Browser → `https://<slug>.BASE_DOMAIN` → Azure AD login → your app loads.

### 3.4 Verify the health endpoint

```bash
docker exec aai-<slug> curl -s http://localhost:<port>/health
# → {"status": "ok", "service": "<slug>"}
```

---

## Part 4 — Admin Steps in the Infrastructure Repo

### 4.1 Fill in `portal.json`

The scaffold script generated `portal.json` in your project directory. Open it and fill in the two `TODO` fields:

```json
{
  "slug": "<slug>",
  "name": "<name>",
  "description": "One-line description of what this project does",
  "owner": "<owner>",
  "port": <port>,
  "repo": "https://github.com/yourorg/<repo>"
}
```

- `port` — mandatory, the single port the container exposes. The portal derives the health check URL (`http://aai-<slug>:<port>/health`) from it automatically. If `/health` doesn't return HTTP 200, the card shows as down.

Commit `portal.json` to the project repo.

### 4.2 Reload the portal

```bash
cd /opt/aai/infrastructure
make restart
```

Within 30 seconds the health checker will make its first request and the status badge will appear on the portal.

### 4.3 Push the project to a remote (optional but recommended)

```bash
cd /opt/aai/projects/<slug>
git remote add origin <repo-url>
git push -u origin main
```

---

## Quick reference checklist

**Scaffold & configure:**
```
[  ] Slug uses hyphens only (no underscores)
[  ] ./scripts/new-project.sh run successfully
[  ] Placeholder app replaced with real code
[  ] /health endpoint returns HTTP 200
[  ] Project-specific secrets added to .env.example and .env
[  ] container_name: aai-<slug> preserved
[  ] Makefile committed to the repo
```

**Start & verify:**
```
[  ] make up && make ps shows container "Up"
[  ] make logs shows no errors
[  ] Browser test: routing and auth work
[  ] Health endpoint reachable from inside the container
```

**Admin — infrastructure repo:**
```
[  ] portal.json description and repo fields filled in
[  ] portal.json committed to the project repo
[  ] make restart run in infrastructure directory
[  ] Portal card appears with correct status badge
```
