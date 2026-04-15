Here's the full summary for Claude Code to consolidate into your docs:

---

## Authentication Migration: oauth2-proxy → traefik-forward-auth

### The Problem with oauth2-proxy

oauth2-proxy was designed for nginx's `auth_request` pattern. When used with Traefik's ForwardAuth:

- `/oauth2/auth` returns **401** when unauthenticated
- Traefik has no native "redirect on 401" (unlike nginx's `error_page 401 =`)
- The `errors` middleware was used as a workaround, but it **proxies content inline** — the browser URL never changes
- The sign-in page's relative links pointed back to the protected domain → **infinite redirect loop**
- A JS template hack was attempted but was fragile and required hardcoded domain names

**Root cause:** Architectural mismatch — oauth2-proxy was built for nginx, not Traefik.

### The Solution: traefik-forward-auth

[thomseddon/traefik-forward-auth](https://github.com/thomseddon/traefik-forward-auth) is purpose-built for Traefik's ForwardAuth middleware. It returns **307 redirects** (not 401s) when unauthenticated, which Traefik passes directly to the browser. No errors middleware, no JS hacks.

### Issues Encountered During Migration

#### 1. Container name collision

The outer VPS Traefik had its own `traefik-forward-auth` container. Our container used the same name, causing the outer Traefik's middleware to route to our container instead.

**Fix:** Renamed container to `aai-traefik-forward-auth`.

#### 2. AUTH_HOST router missing ForwardAuth middleware

In `AUTH_HOST` mode, traefik-forward-auth reads the request path from the `X-Forwarded-Uri` header (set by Traefik's ForwardAuth middleware). Without the middleware on the auth router, requests arrived as raw HTTP — `X-Forwarded-Uri` was empty — so traefik-forward-auth never detected the `/_oauth` callback path and kept redirecting to Microsoft in a loop.

**Fix:** The auth host router **must** have the ForwardAuth middleware applied. traefik-forward-auth handles `/_oauth` requests on the AUTH_HOST specially — it processes the callback instead of checking authentication. This is not circular.

```yaml
- "traefik.http.routers.traefik-forward-auth.middlewares=tfa@docker"
```

#### 3. Email case sensitivity

Azure AD returned `Fabien_Chazal@epam.com` but the whitelist had `fabien_chazal@epam.com`. traefik-forward-auth's whitelist comparison is case-sensitive.

**Fix:** Removed email whitelist entirely. Access control is handled by Entra ID user assignment (see below).

### Final Architecture

```
Internet → Outer Traefik (TCP SNI passthrough for *.aai.chetbu.fr)
              → Inner aai-traefik (TLS termination, subdomain routing)
                  → traefik-forward-auth (ForwardAuth, Azure AD OIDC)
                      → Portal, projects, etc.
```

### Auth Flow

```
1. Browser → test.aai.chetbu.fr
2. Traefik ForwardAuth → traefik-forward-auth: "not authenticated"
3. 307 redirect → https://auth.aai.chetbu.fr/_oauth (AUTH_HOST)
4. Traefik ForwardAuth → traefik-forward-auth: detects /_oauth, no code
5. 307 redirect → Microsoft login
6. User authenticates at Microsoft
7. Microsoft → https://auth.aai.chetbu.fr/_oauth?code=xxx&state=xxx
8. Traefik ForwardAuth → traefik-forward-auth: detects /_oauth + code
9. Exchanges code for tokens, validates, sets cookie on .aai.chetbu.fr
10. 307 redirect → https://test.aai.chetbu.fr/ (original URL)
11. Traefik ForwardAuth → traefik-forward-auth: valid cookie → 200
12. Page served
```

### Access Control via Entra ID

Instead of managing email whitelists in config files, access is controlled in Azure AD / Microsoft Entra ID:

- **Enterprise Applications** → AAI Platform → Properties → **Assignment required = Yes**
- Users/groups are assigned in the **Users and groups** tab
- Unassigned users are blocked by Azure AD before any token is issued (`AADSTS50105`)
- No `WHITELIST` or `DOMAINS` config needed in traefik-forward-auth

### Key Configuration

**docker-compose.yml — traefik-forward-auth service:**
```yaml
traefik-forward-auth:
  image: thomseddon/traefik-forward-auth:2
  container_name: aai-traefik-forward-auth
  restart: unless-stopped
  environment:
    - DEFAULT_PROVIDER=oidc
    - PROVIDERS_OIDC_ISSUER_URL=https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0
    - PROVIDERS_OIDC_CLIENT_ID=${AZURE_CLIENT_ID}
    - PROVIDERS_OIDC_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
    - SECRET=${COOKIE_SECRET}
    - COOKIE_DOMAIN=${BASE_DOMAIN}
    - AUTH_HOST=auth.${BASE_DOMAIN}
    - URL_PATH=/_oauth
    - LOG_LEVEL=info
  networks:
    - aai-public
  labels:
    - "traefik.enable=true"
    - "traefik.docker.network=aai-public"
    - "traefik.http.routers.traefik-forward-auth.rule=Host(`auth.${BASE_DOMAIN}`)"
    - "traefik.http.routers.traefik-forward-auth.tls.certresolver=letsencrypt"
    - "traefik.http.routers.traefik-forward-auth.middlewares=tfa@docker"
    - "traefik.http.services.traefik-forward-auth.loadbalancer.server.port=4181"
    - "traefik.http.middlewares.tfa.forwardAuth.address=http://aai-traefik-forward-auth:4181"
    - "traefik.http.middlewares.tfa.forwardAuth.trustForwardHeader=true"
    - "traefik.http.middlewares.tfa.forwardAuth.authResponseHeaders=X-Forwarded-User"
```

**Protected services use:**
```yaml
- "traefik.http.routers.<name>.middlewares=tfa@docker,secure-headers@file"
```

**Azure AD app registration:**
- Redirect URI: `https://auth.aai.chetbu.fr/_oauth`
- Platform: Web (not SPA)
- Enterprise Application: Assignment required = Yes

---