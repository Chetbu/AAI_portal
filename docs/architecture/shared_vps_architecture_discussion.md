# Nested Traefik: Migration-Ready Architecture

## The concept

```
Today (shared VPS):

  Client
    → existing Traefik (:80/:443)
        ├─ llm.example.com        → existing services (TLS terminated here)
        └─ *.aai.example.com      → TCP passthrough (TLS NOT terminated)
            → AAI Traefik (:443 internal)
                ├─ aai.example.com          → portal
                ├─ auth.aai.example.com     → oauth2-proxy
                └─ project-1.aai.example.com → project-1

Migration day (dedicated VPS):

  Client
    → AAI Traefik (:80/:443)     ← same container, just exposed to host
        ├─ aai.example.com          → portal
        ├─ auth.aai.example.com     → oauth2-proxy
        └─ project-1.aai.example.com → project-1
```

**The entire AAI stack is written as if it owns the VPS.** The only adaptation is a thin TCP passthrough layer on the existing Traefik. On migration day, you change DNS and remove that layer. Zero changes to the AAI stack itself.

---

## Network topology

```
┌───────────────────────────────────────────────────────────┐
│  VPS                                                      │
│                                                           │
│  ┌─── existing-proxy (network) ────────────────────────┐  │
│  │                                                     │  │
│  │  existing-traefik (:80, :443 on host)               │  │
│  │  existing-app (llm.example.com)                     │  │
│  │                                                     │  │
│  │  aai-traefik  ← bridge: visible to existing traefik │  │
│  │               ← labels tell existing traefik what   │  │
│  │                  to forward                         │  │
│  └─────────────────────────┬───────────────────────────┘  │
│                            │                              │
│  ┌─── aai-public (network)─┴──────────────────────────┐   │
│  │                                                     │  │
│  │  aai-traefik  ← also here: routes AAI services      │  │
│  │  aai-oauth2-proxy                                   │  │
│  │  aai-portal                                         │  │
│  │  aai-project-1                                      │  │
│  │  aai-project-2                                      │  │
│  │                                                     │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  Existing Traefik sees: aai-traefik (passthrough labels)  │
│  Existing Traefik does NOT see: portal, projects, etc.    │
│                                                           │
│  AAI Traefik sees: all aai-* containers (routing labels)  │
│  AAI Traefik does NOT see: existing services              │
│                                                           │
│  → Clean isolation. No cross-contamination of labels.     │
└───────────────────────────────────────────────────────────┘
```

---

## What changes vs the original plan

| Component | Original plan | Shared VPS adaptation |
|-----------|--------------|----------------------|
| AAI Traefik | `ports: ["80:80", "443:443"]` | **No host ports** — traffic arrives via existing Traefik |
| AAI Traefik networks | `aai-public` only | `aai-public` **+ existing proxy network** |
| AAI Traefik labels | Only internal AAI labels | **Add TCP/HTTP passthrough labels** for existing Traefik |
| All other AAI services | As designed | **Completely unchanged** |
| Existing Traefik | Untouched | **Add `aai-public` to its networks** |

---

## Implementation

### 1. Create the AAI network

```bash
docker network create aai-public
```

### 2. Connect existing Traefik to AAI network

In your **existing** Traefik's `docker-compose.yml`, add the network:

```yaml
services:
  traefik:
    # ... existing config stays exactly as-is ...
    networks:
      - proxy            # existing
      - aai-public       # ← add this line

networks:
  proxy:
    external: true
  aai-public:            # ← add this block
    external: true
```

Restart existing Traefik:
```bash
cd /path/to/existing/traefik
docker compose up -d
```

Verify:
```bash
docker inspect traefik --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# Should show both: proxy aai-public
```

---

### 3. AAI Traefik `docker-compose.yml`

This is the **full infrastructure docker-compose.yml** — the AAI Traefik is back (unlike the "shared Traefik" approach), but it doesn't bind host ports:

```yaml
services:

  # ── AAI Traefik (internal, receives traffic via existing Traefik) ──
  traefik:
    image: traefik:v3.1
    container_name: aai-traefik
    restart: unless-stopped
    environment:
      - ACME_EMAIL=${ACME_EMAIL}
    # ⚠️  NO ports: section — existing Traefik forwards traffic to us
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml.template:/etc/traefik/traefik.yml.template:ro
      - ./traefik/entrypoint-wrapper.sh:/entrypoint-wrapper.sh:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
      - ./traefik/acme.json:/acme.json
      - traefik-logs:/var/log/traefik
    entrypoint: ["/entrypoint-wrapper.sh"]
    command: ["traefik"]
    networks:
      aai-public: {}
      existing-proxy:
        # On this network, existing Traefik discovers our passthrough labels
        aliases:
          - aai-traefik
    labels:
      # ─────────────────────────────────────────────────────
      # Labels for the EXISTING Traefik (TCP/HTTP passthrough)
      # ─────────────────────────────────────────────────────

      # Tell existing Traefik to route to us
      - "traefik.enable=true"
      - "traefik.docker.network=existing-proxy"

      # HTTPS: TCP passthrough (TLS stays encrypted end-to-end)
      - "traefik.tcp.routers.aai-passthrough.rule=HostSNI(`${BASE_DOMAIN}`) || HostSNIRegexp(`^.+\\.aai\\.example\\.com$$`)"
      - "traefik.tcp.routers.aai-passthrough.entrypoints=websecure"
      - "traefik.tcp.routers.aai-passthrough.tls.passthrough=true"
      - "traefik.tcp.routers.aai-passthrough.service=aai-traefik-tcp"
      - "traefik.tcp.services.aai-traefik-tcp.loadbalancer.server.port=443"

      # HTTP: forward port 80 (needed for ACME challenges + HTTP→HTTPS redirect)
      - "traefik.http.routers.aai-http-passthrough.rule=Host(`${BASE_DOMAIN}`) || HostRegexp(`^.+\\.aai\\.example\\.com$$`)"
      - "traefik.http.routers.aai-http-passthrough.entrypoints=web"
      - "traefik.http.routers.aai-http-passthrough.priority=100"
      - "traefik.http.services.aai-http-passthrough.loadbalancer.server.port=80"


  # ── OAuth2 Proxy ───────────────────────────────────────────
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    container_name: aai-oauth2-proxy
    restart: unless-stopped
    environment:
      - OAUTH2_PROXY_PROVIDER=azure
      - OAUTH2_PROXY_AZURE_TENANT=${AZURE_TENANT_ID}
      - OAUTH2_PROXY_CLIENT_ID=${AZURE_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
      - OAUTH2_PROXY_OIDC_ISSUER_URL=https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0
      - OAUTH2_PROXY_COOKIE_SECRET=${COOKIE_SECRET}
      - OAUTH2_PROXY_COOKIE_DOMAINS=.${BASE_DOMAIN}
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_COOKIE_SAMESITE=lax
      - OAUTH2_PROXY_COOKIE_NAME=_aai_oauth2
      - OAUTH2_PROXY_COOKIE_EXPIRE=168h
      - OAUTH2_PROXY_EMAIL_DOMAINS=*
      - OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE=/etc/oauth2-proxy/allowed_emails.txt
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_REVERSE_PROXY=true
      - OAUTH2_PROXY_SET_XAUTHREQUEST=true
      - OAUTH2_PROXY_SET_AUTHORIZATION_HEADER=true
      - OAUTH2_PROXY_PASS_USER_HEADERS=true
      - OAUTH2_PROXY_WHITELIST_DOMAINS=.${BASE_DOMAIN}
      - OAUTH2_PROXY_REDIRECT_URL=https://auth.${BASE_DOMAIN}/oauth2/callback
      - OAUTH2_PROXY_SKIP_PROVIDER_BUTTON=true
    volumes:
      - ./oauth2-proxy/allowed_emails.txt:/etc/oauth2-proxy/allowed_emails.txt:ro
    networks:
      - aai-public
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=aai-public"
      - "traefik.http.routers.oauth2-proxy.rule=Host(`auth.${BASE_DOMAIN}`)"
      - "traefik.http.routers.oauth2-proxy.tls.certresolver=letsencrypt"
      - "traefik.http.services.oauth2-proxy.loadbalancer.server.port=4180"
      - "traefik.http.middlewares.oauth.forwardauth.address=http://oauth2-proxy:4180/oauth2/auth"
      - "traefik.http.middlewares.oauth.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.oauth.forwardauth.authResponseHeaders=X-Auth-Request-User,X-Auth-Request-Email,X-Auth-Request-Access-Token"

  # ── Portal ─────────────────────────────────────────────────
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
      - "traefik.docker.network=aai-public"
      - "traefik.http.routers.portal.rule=Host(`${BASE_DOMAIN}`)"
      - "traefik.http.routers.portal.tls.certresolver=letsencrypt"
      - "traefik.http.routers.portal.middlewares=oauth@docker,secure-headers@file"
      - "traefik.http.services.portal.loadbalancer.server.port=80"

volumes:
  traefik-logs:

networks:
  aai-public:
    external: true
  existing-proxy:
    external: true
    name: proxy       # ← the actual name of your existing Traefik's network
```

---

### 4. The `HostSNIRegexp` gotcha

The passthrough label contains the **literal domain** because `${BASE_DOMAIN}` gets substituted by Docker Compose, but the regex dots need escaping and the `$` needs doubling in YAML:

```yaml
# In docker-compose.yml, $$ produces a literal $ in the container label
- "traefik.tcp.routers.aai-passthrough.rule=HostSNI(`${BASE_DOMAIN}`) || HostSNIRegexp(`^.+\\.aai\\.example\\.com$$`)"
```

> ⚠️ The regex part can't use `${BASE_DOMAIN}` because it needs escaped dots. Add this to `shared.env`:

```bash
# /opt/aai/shared.env
BASE_DOMAIN=aai.example.com
BASE_DOMAIN_REGEX=^.+\\.aai\\.example\\.com$$
ACME_EMAIL=admin@example.com
```

Then the label becomes:
```yaml
- "traefik.tcp.routers.aai-passthrough.rule=HostSNI(`${BASE_DOMAIN}`) || HostSNIRegexp(`${BASE_DOMAIN_REGEX}`)"
```

---

### 5. Handle the HTTP→HTTPS redirect priority

The existing Traefik likely has a global HTTP→HTTPS redirect on its `web` entrypoint. This would redirect AAI's ACME challenges before they reach the AAI Traefik.

**Check your existing Traefik config:**

```bash
docker exec traefik cat /etc/traefik/traefik.yml | grep -A5 redirections
```

If you see a global redirect like:
```yaml
entryPoints:
  web:
    http:
      redirections:
        entryPoint:
          to: websecure
```

**You need to change it** to per-router redirects on the existing services, so AAI HTTP traffic passes through. Or set a **higher priority** on the AAI HTTP router (which we already did with `priority=100` — Traefik's auto-calculated priorities for your existing routes will typically be lower).

Actually, the entrypoint-level redirect takes precedence over routers. **If you have a global redirect, you need to remove it** and add it as a middleware to your existing routers instead:

```yaml
# Existing traefik.yml — REMOVE the global redirect:
entryPoints:
  web:
    address: ":80"
    # DELETE the http.redirections block
  websecure:
    address: ":443"
```

```yaml
# Existing services — ADD redirect middleware via labels:
labels:
  - "traefik.http.routers.myapp.middlewares=redirect-to-https@file"

# Or define in dynamic config:
http:
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
```

This way existing services still redirect HTTP→HTTPS, but AAI HTTP traffic reaches the AAI Traefik unmodified.

---

### 6. AAI Traefik static config

The AAI Traefik's `traefik.yml.template` stays **exactly as in the original plan** — it thinks it owns the world:

```yaml
api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: aai-public        # only sees AAI containers
  file:
    directory: "/etc/traefik/dynamic"
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme.json
      httpChallenge:
        entryPoint: web
```

Key detail: `network: aai-public` means the AAI Traefik ignores containers on the `existing-proxy` network. It only routes AAI services. No label conflicts.

---

## Verification after deployment

```bash
# 1. Check both Traefiks see the right containers
docker exec traefik           traefik healthcheck  # existing
docker exec aai-traefik       traefik healthcheck  # AAI

# 2. Check existing Traefik has the TCP router
curl -s http://localhost:8080/api/tcp/routers 2>/dev/null | jq '.[].name' 
# Should include: aai-passthrough@docker

# 3. Test the full chain
curl -I https://aai.example.com
# Should: get SSL cert issued to aai.example.com (by AAI Traefik's ACME)
# Should: redirect to Microsoft login (oauth2-proxy working)

# 4. Existing services still work
curl -I https://llm.example.com
# Should: work exactly as before
```

---

## Migration day checklist

When you get the dedicated VPS:

```bash
# ── On the NEW VPS ──────────────────────────────────────────

# 1. Set up the new VPS (Phase 1 from the original plan)
# 2. Copy /opt/aai/ from old VPS (or git clone + restore .env files)

# 3. One change in docker-compose.yml — add host port binding:
#    In the traefik service, add:
    ports:
      - "80:80"
      - "443:443"

# 4. Remove the existing-proxy network reference:
#    Delete the existing-proxy network block and remove it from traefik's networks

# 5. Remove the passthrough labels (lines marked "for EXISTING Traefik"):
#    Delete the traefik.tcp.* and aai-http-passthrough labels

# 6. Start everything
cd /opt/aai/infrastructure && make up
cd /opt/aai/projects/project-1 && make up

# ── DNS ─────────────────────────────────────────────────────

# 7. Update DNS:
#    A    aai.example.com      → NEW_VPS_IP
#    A    *.aai.example.com    → NEW_VPS_IP

# ── On the OLD VPS ─────────────────────────────────────────

# 8. Remove AAI stack
cd /opt/aai/infrastructure && make down
cd /opt/aai/projects/project-1 && make down

# 9. Disconnect existing Traefik from aai-public
docker network disconnect aai-public traefik
docker network rm aai-public

# 10. Remove the aai-public network from existing Traefik's docker-compose
# 11. Revert the global HTTP→HTTPS redirect if you changed it
# 12. Restart existing Traefik
```

**Total migration effort: ~30 minutes, near-zero risk to the AAI stack since nothing inside it changes.**