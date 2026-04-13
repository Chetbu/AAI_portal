# Initial plan From user

I would like to structure a project for a internal and small team. Please help me structure it as cleanly as possible, for it to be usable by AI agents to help me deliver it

Goal would be to have only one VPS, with one domain (let's take aai.example.com) for now
On this domain I would like to have a root portal (html) that would link to a number of small POCs, all running in separate dockers
If I try to illustrate, I would have aai.example.com/project_1 that would lead to project 1, aai.example.com/project_2 that would lead to project 2 etc
All these projects would be independant (would have their own git repo, their own admin)
The portal would only be hyperlinks to access everything and check the health of everything

I was envisioning (please challenge to make sure it is right for my need)
- to do a git repo to host the portal & redirection & authentification part of the system.
- I was thinking about traefik as a reverse proxy to route the request through the right services 
- I would want to have a restricted access to the portal, to a defined number of user. If possible and easy enough we can use the microsoft azure login and restrict it to a defined list of users
- To have the git of the project in the respective projects folders above root ('*/project_1 for example) with their own git management

How does this sounds ? Please challenge highlight any painpoints you may already see


# Architecture Review & Recommendations (Challenge by Claude Opus)

## Your instincts are solid — here are the refinements

---

## Pain Point #1 (Critical): Path-based vs Subdomain Routing

You proposed `aai.example.com/project_1`. This **will cause you pain**. Most web apps assume they run at `/`. Traefik can strip the prefix, but the app's internal links, asset paths, API calls, and redirects will break unless each app is specifically built to be base-path-aware.

**Recommendation: use subdomains instead**

```
aai.example.com          → portal
project1.aai.example.com → project 1
project2.aai.example.com → project 2
```

This requires only:
- One wildcard DNS record: `*.aai.example.com → your VPS IP`
- Traefik handles wildcard SSL via Let's Encrypt DNS challenge (or individual certs per subdomain with HTTP challenge)

Each POC then believes it lives at `/` and nothing breaks. This is the single biggest improvement you can make.

---

## Pain Point #2: Auth Placement

Azure AD (Microsoft Entra ID) is doable but not trivial. Traefik has no native Azure AD middleware. You need an intermediary.

**Recommendation: `oauth2-proxy` as a ForwardAuth middleware**

```
Browser → Traefik → [ForwardAuth: oauth2-proxy] → project container
                         ↓
                    Microsoft Entra ID
```

- `oauth2-proxy` natively supports Azure AD as a provider
- You configure an allowed email list (or Azure AD group)
- Traefik calls oauth2-proxy on every request via `forwardAuth`
- If not authenticated → redirect to Microsoft login
- If authenticated but not in allowed list → 403
- Cookie-based session so login happens once

**One gotcha**: the auth cookie domain must be set to `.aai.example.com` so a single login covers the portal and all subdomains.

---

## Pain Point #3: Docker Network Isolation

Each project has its own `docker-compose.yml` and thus its own default network. Traefik cannot reach them unless they share a network.

**Solution: one shared external Docker network**

```bash
docker network create aai-public
```

Every project joins this network in addition to any internal networks it needs. Traefik only needs to see the front-facing container.

---

## Recommended Directory Structure on VPS

```
/opt/aai/
│
├── infrastructure/                  # ← Git repo #1: "aai-infrastructure"
│   ├── docker-compose.yml           #    Traefik + oauth2-proxy + portal
│   ├── .env                         #    Secrets (Azure client ID, etc.)
│   ├── .env.example                 #    Template for secrets
│   ├── Makefile                     #    Common commands
│   │
│   ├── traefik/
│   │   ├── traefik.yml              #    Static config
│   │   ├── acme.json                #    SSL certs (auto-generated, gitignored)
│   │   └── dynamic/                 #    Dynamic config (optional overrides)
│   │       └── middlewares.yml
│   │
│   ├── portal/
│   │   ├── Dockerfile               #    nginx serving static files
│   │   ├── index.html               #    Main portal page
│   │   ├── healthcheck.js           #    JS that pings each project
│   │   └── config.json              #    List of projects (name, url, health endpoint)
│   │
│   └── docs/
│       ├── SETUP.md                 #    Initial VPS setup instructions
│       ├── ADD_PROJECT.md           #    How to add a new POC
│       └── ARCHITECTURE.md          #    This design document
│
├── projects/
│   ├── project-1/                   # ← Git repo #2: "aai-project-1"
│   │   ├── docker-compose.yml       #    App-specific, joins aai-public network
│   │   ├── .env
│   │   ├── .env.example
│   │   ├── Makefile
│   │   └── src/
│   │
│   ├── project-2/                   # ← Git repo #3: "aai-project-2"
│   │   ├── docker-compose.yml
│   │   ├── ...
```

---

## Infrastructure `docker-compose.yml`

```yaml
version: "3.9"

services:
  traefik:
    image: traefik:v3.1
    container_name: aai-traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
      - ./traefik/acme.json:/acme.json
    networks:
      - aai-public
    labels:
      # Traefik dashboard (optional, restricted)
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`traefik.aai.example.com`)"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.dashboard.middlewares=oauth@docker"

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    container_name: aai-oauth2-proxy
    restart: unless-stopped
    environment:
      - OAUTH2_PROXY_PROVIDER=azure
      - OAUTH2_PROXY_AZURE_TENANT=${AZURE_TENANT_ID}
      - OAUTH2_PROXY_CLIENT_ID=${AZURE_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
      - OAUTH2_PROXY_COOKIE_SECRET=${COOKIE_SECRET}        # generate: openssl rand -hex 16
      - OAUTH2_PROXY_COOKIE_DOMAINS=.aai.example.com       # wildcard for SSO across subdomains
      - OAUTH2_PROXY_WHITELIST_DOMAINS=.aai.example.com
      - OAUTH2_PROXY_EMAIL_DOMAINS=*
      - OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE=/etc/oauth2-proxy/allowed_emails.txt
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_REVERSE_PROXY=true
      - OAUTH2_PROXY_SET_XAUTHREQUEST=true
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_REDIRECT_URL=https://auth.aai.example.com/oauth2/callback
    volumes:
      - ./oauth2-proxy/allowed_emails.txt:/etc/oauth2-proxy/allowed_emails.txt:ro
    networks:
      - aai-public
    labels:
      - "traefik.enable=true"
      # OAuth2 proxy endpoint (handles login flow)
      - "traefik.http.routers.oauth2-proxy.rule=Host(`auth.aai.example.com`)"
      - "traefik.http.routers.oauth2-proxy.tls.certresolver=letsencrypt"
      - "traefik.http.services.oauth2-proxy.loadbalancer.server.port=4180"
      # ForwardAuth middleware definition (used by all other services)
      - "traefik.http.middlewares.oauth.forwardauth.address=http://oauth2-proxy:4180/oauth2/auth"
      - "traefik.http.middlewares.oauth.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.oauth.forwardauth.authResponseHeaders=X-Auth-Request-User,X-Auth-Request-Email"

  portal:
    build: ./portal
    container_name: aai-portal
    restart: unless-stopped
    networks:
      - aai-public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portal.rule=Host(`aai.example.com`)"
      - "traefik.http.routers.portal.tls.certresolver=letsencrypt"
      - "traefik.http.routers.portal.middlewares=oauth@docker"
      - "traefik.http.services.portal.loadbalancer.server.port=80"

networks:
  aai-public:
    external: true
```

---

## Traefik Static Config (`traefik/traefik.yml`)

```yaml
api:
  dashboard: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: aai-public

certificatesResolvers:
  letsencrypt:
    acme:
      email: your-email@example.com
      storage: /acme.json
      httpChallenge:
        entryPoint: web
```

---

## Example Project `docker-compose.yml` (project-1)

```yaml
version: "3.9"

services:
  app:
    build: .
    container_name: aai-project-1
    restart: unless-stopped
    networks:
      - aai-public
      - internal
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.project-1.rule=Host(`project1.aai.example.com`)"
      - "traefik.http.routers.project-1.tls.certresolver=letsencrypt"
      - "traefik.http.routers.project-1.middlewares=oauth@docker"
      - "traefik.http.services.project-1.loadbalancer.server.port=8000"

  # Project-specific services (DB, redis, etc.) stay internal
  db:
    image: postgres:16-alpine
    networks:
      - internal

networks:
  aai-public:
    external: true
  internal:
    driver: bridge
```

Notice: the project only needs to add 6 labels to be fully integrated — routed, SSL-terminated, and authenticated. The project team does not need to touch the infrastructure repo.

---

## Portal Design (`portal/index.html` concept)

```
┌─────────────────────────────────────────────────────┐
│  AAI Platform Portal          Logged in: user@co.com│
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌─────────────────┐  ┌─────────────────┐          │
│  │ Project 1       │  │ Project 2       │          │
│  │ LLM Chatbot POC │  │ Doc Analyzer    │          │
│  │                 │  │                 │          │
│  │ Status: ● UP    │  │ Status: ● UP    │          │
│  │ [Open] [Docs]   │  │ [Open] [Docs]   │          │
│  └─────────────────┘  └─────────────────┘          │
│                                                     │
│  ┌─────────────────┐                               │
│  │ Project 3       │                               │
│  │ RAG Pipeline    │                               │
│  │                 │                               │
│  │ Status: ● DOWN  │                               │
│  │ [Open] [Docs]   │                               │
│  └─────────────────┘                               │
└─────────────────────────────────────────────────────┘
```

The portal reads `config.json` and pings health endpoints client-side:

```json
{
  "projects": [
    {
      "name": "LLM Chatbot POC",
      "slug": "project-1",
      "url": "https://project1.aai.example.com",
      "healthEndpoint": "https://project1.aai.example.com/health",
      "description": "Conversational AI prototype",
      "owner": "Alice"
    }
  ]
}
```

---

## Remaining Pain Points to Be Aware Of

| Concern | Severity | Mitigation |
|---|---|---|
| **Single VPS = single point of failure** | Medium (acceptable for POC) | Automated backups, document rebuild process |
| **Resource contention** | Medium | Set memory limits in each docker-compose. Monitor with `docker stats` or add a lightweight Prometheus + Grafana |
| **Docker socket exposure to Traefik** | Low-medium | Use `ro` mount. For higher security, use Traefik's Docker socket proxy |
| **Secret management** | Low-medium | `.env` files work for small teams. Never commit them. `.env.example` as templates |
| **Deployment coordination** | Low | Each project is independent. Only risk: someone takes down the `aai-public` network. Makefile guards help |
| **Disk space** | Low | Docker images accumulate. Add a cron: `docker image prune -af --filter "until=168h"` |

---

## Checklist for Initial VPS Setup

```bash
# 1. Install Docker + Docker Compose
# 2. Create shared network
docker network create aai-public

# 3. DNS records (at your registrar)
#    A    aai.example.com        → <VPS_IP>
#    A    *.aai.example.com      → <VPS_IP>

# 4. Azure AD App Registration
#    - Create app registration in Azure portal
#    - Redirect URI: https://auth.aai.example.com/oauth2/callback
#    - Note: client ID, client secret, tenant ID
#    - No special API permissions needed (just sign-in)

# 5. Clone and start infrastructure
cd /opt/aai
git clone <infra-repo> infrastructure
cd infrastructure
cp .env.example .env   # fill in secrets
touch traefik/acme.json && chmod 600 traefik/acme.json
docker compose up -d

# 6. Clone and start a project
cd /opt/aai/projects
git clone <project-1-repo> project-1
cd project-1
cp .env.example .env
docker compose up -d
```

---

## Summary of Decisions

| Decision | Your proposal | My recommendation |
|---|---|---|
| Reverse proxy | Traefik ✅ | Confirmed — best fit for Docker-native label-based discovery |
| Routing | Path-based | **Subdomain-based** — avoids base-path hell |
| Auth | Azure AD | Azure AD **via oauth2-proxy** as ForwardAuth middleware |
| Repo structure | Portal + infra in one repo | Confirmed — infra repo is the "platform", projects are independent |
| Project isolation | Separate repos + folders | Confirmed — add shared Docker network as the only coupling point |

This structure means adding a new POC is: clone repo, write 6 Docker labels, `docker compose up -d`. That's it.

# How to distribute the domain name ?

# Parameterizing the Domain

## Where the domain appears today (hardcoded)

| File | Example | Supports `${VAR}`? |
|---|---|---|
| Infrastructure `docker-compose.yml` labels | `` Host(`aai.example.com`) `` | ✅ Yes — docker compose interpolates |
| oauth2-proxy env vars in compose | `COOKIE_DOMAINS=.aai.example.com` | ✅ Yes — same mechanism |
| Project `docker-compose.yml` labels | `` Host(`project1.aai.example.com`) `` | ✅ Yes |
| `traefik.yml` static config | No domain present | N/A — already clean |
| Portal `config.json` | `https://project1.aai.example.com` | ❌ No — static file |

Good news: almost everything runs through `docker-compose.yml`, which **natively interpolates `${VARIABLES}`** from `.env` files.

---

## The challenge: multiple repos, one shared value

Docker Compose only reads the `.env` file **next to its own `docker-compose.yml`**. So a shared value like `BASE_DOMAIN` needs a distribution strategy.

---

## Recommended approach: shared env file + Makefile convention

### 1. Shared platform config at the root

```
/opt/aai/
├── shared.env              ← single source of truth for platform-wide config
├── infrastructure/
│   ├── .env                ← secrets only (Azure creds, cookie secret)
│   ├── Makefile
│   └── docker-compose.yml
└── projects/
    └── project-1/
        ├── .env            ← project-specific secrets only
        ├── Makefile
        └── docker-compose.yml
```

```bash
# /opt/aai/shared.env
# Platform-wide configuration — not secret, checked into infra repo
BASE_DOMAIN=aai.example.com
ACME_EMAIL=admin@example.com
```

```bash
# /opt/aai/infrastructure/.env
# Secrets — NEVER committed
AZURE_TENANT_ID=xxxxxxxx
AZURE_CLIENT_ID=xxxxxxxx
AZURE_CLIENT_SECRET=xxxxxxxx
COOKIE_SECRET=xxxxxxxx
```

### 2. Makefile in every repo loads both files

```makefile
# /opt/aai/infrastructure/Makefile

SHARED_ENV := $(shell cd .. && pwd)/shared.env

.PHONY: up down restart logs

up:
	docker compose --env-file $(SHARED_ENV) --env-file .env up -d --build

down:
	docker compose --env-file $(SHARED_ENV) --env-file .env down

restart:
	docker compose --env-file $(SHARED_ENV) --env-file .env up -d --force-recreate

logs:
	docker compose --env-file $(SHARED_ENV) --env-file .env logs -f
```

```makefile
# /opt/aai/projects/project-1/Makefile

SHARED_ENV := $(shell cd ../.. && pwd)/shared.env

.PHONY: up down logs

up:
	docker compose --env-file $(SHARED_ENV) --env-file .env up -d --build

down:
	docker compose --env-file $(SHARED_ENV) --env-file .env down

logs:
	docker compose --env-file $(SHARED_ENV) --env-file .env logs -f
```

> The `--env-file` flag can be passed **multiple times** in Docker Compose v2.17+. The second file takes precedence on conflicts, so project-specific `.env` overrides shared values if needed.

---

## Updated docker-compose files using variables

### Infrastructure `docker-compose.yml`

```yaml
services:
  traefik:
    image: traefik:v3.1
    container_name: aai-traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/acme.json:/acme.json
    networks:
      - aai-public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`traefik.${BASE_DOMAIN}`)"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.dashboard.middlewares=oauth@docker"

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    container_name: aai-oauth2-proxy
    restart: unless-stopped
    environment:
      - OAUTH2_PROXY_PROVIDER=azure
      - OAUTH2_PROXY_AZURE_TENANT=${AZURE_TENANT_ID}
      - OAUTH2_PROXY_CLIENT_ID=${AZURE_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
      - OAUTH2_PROXY_COOKIE_SECRET=${COOKIE_SECRET}
      - OAUTH2_PROXY_COOKIE_DOMAINS=.${BASE_DOMAIN}
      - OAUTH2_PROXY_WHITELIST_DOMAINS=.${BASE_DOMAIN}
      - OAUTH2_PROXY_EMAIL_DOMAINS=*
      - OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE=/etc/oauth2-proxy/allowed_emails.txt
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_REVERSE_PROXY=true
      - OAUTH2_PROXY_SET_XAUTHREQUEST=true
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_REDIRECT_URL=https://auth.${BASE_DOMAIN}/oauth2/callback
    volumes:
      - ./oauth2-proxy/allowed_emails.txt:/etc/oauth2-proxy/allowed_emails.txt:ro
    networks:
      - aai-public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.oauth2-proxy.rule=Host(`auth.${BASE_DOMAIN}`)"
      - "traefik.http.routers.oauth2-proxy.tls.certresolver=letsencrypt"
      - "traefik.http.services.oauth2-proxy.loadbalancer.server.port=4180"
      - "traefik.http.middlewares.oauth.forwardauth.address=http://oauth2-proxy:4180/oauth2/auth"
      - "traefik.http.middlewares.oauth.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.oauth.forwardauth.authResponseHeaders=X-Auth-Request-User,X-Auth-Request-Email"

  portal:
    build: ./portal
    container_name: aai-portal
    restart: unless-stopped
    environment:
      - BASE_DOMAIN=${BASE_DOMAIN}
    networks:
      - aai-public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portal.rule=Host(`${BASE_DOMAIN}`)"
      - "traefik.http.routers.portal.tls.certresolver=letsencrypt"
      - "traefik.http.routers.portal.middlewares=oauth@docker"
      - "traefik.http.services.portal.loadbalancer.server.port=80"

networks:
  aai-public:
    external: true
```

### Project `docker-compose.yml`

```yaml
services:
  app:
    build: .
    container_name: aai-project-1
    restart: unless-stopped
    networks:
      - aai-public
      - internal
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.project-1.rule=Host(`project1.${BASE_DOMAIN}`)"
      - "traefik.http.routers.project-1.tls.certresolver=letsencrypt"
      - "traefik.http.routers.project-1.middlewares=oauth@docker"
      - "traefik.http.services.project-1.loadbalancer.server.port=8000"

networks:
  aai-public:
    external: true
  internal:
```

---

## Solving the portal `config.json` problem

Since the portal is a static nginx container, we use **`envsubst` at startup** — a standard pattern for injecting env vars into static files:

```json
// portal/config.json.template
{
  "platform": "AAI Portal",
  "projects": [
    {
      "name": "LLM Chatbot POC",
      "slug": "project-1",
      "url": "https://project1.${BASE_DOMAIN}",
      "healthEndpoint": "https://project1.${BASE_DOMAIN}/health",
      "owner": "Alice"
    },
    {
      "name": "Doc Analyzer",
      "slug": "project-2",
      "url": "https://project2.${BASE_DOMAIN}",
      "healthEndpoint": "https://project2.${BASE_DOMAIN}/health",
      "owner": "Bob"
    }
  ]
}
```

```dockerfile
# portal/Dockerfile
FROM nginx:alpine

COPY index.html /usr/share/nginx/html/
COPY healthcheck.js /usr/share/nginx/html/
COPY config.json.template /etc/nginx/templates/config.json.template
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
```

```bash
#!/bin/sh
# portal/entrypoint.sh

# Substitute env vars in config template → static file served by nginx
envsubst '${BASE_DOMAIN}' \
  < /etc/nginx/templates/config.json.template \
  > /usr/share/nginx/html/config.json

# Hand off to nginx
exec "$@"
```

Now `config.json` is generated at container startup with the real domain, and the portal JavaScript reads it normally.

---

## What about actual secrets? (upgrade path)

Your current setup with `.env` files is fine for a small team. If you later want secrets encrypted in git:

```
Low effort          ──────────────────────────────►  High effort
                                                     
.env files          SOPS-encrypted         Docker       HashiCorp
(gitignored)        .env in git            Swarm        Vault
                                           secrets      
✅ Current          Good next step         Needs Swarm  Overkill
                    for your scale                      for POCs
```

**SOPS** (Mozilla) is the sweet spot if you ever need it: encrypts `.env` files with an age key, lets you commit them safely, and decrypts at deploy time. One command change in the Makefile.

---

## Summary: what gets committed where

```
shared.env          → committed in infra repo (no secrets, just config)
infrastructure/.env → gitignored (secrets only)
project-X/.env      → gitignored (project secrets)
.env.example files  → committed everywhere (templates with placeholder values)
```

```bash
# infrastructure/.env.example
AZURE_TENANT_ID=<your-azure-tenant-id>
AZURE_CLIENT_ID=<your-azure-client-id>
AZURE_CLIENT_SECRET=<your-azure-client-secret>
COOKIE_SECRET=<run: openssl rand -hex 16>
```

The domain is **never hardcoded in any configuration file**. Change `shared.env` once, run `make restart` in each stack, and everything updates.