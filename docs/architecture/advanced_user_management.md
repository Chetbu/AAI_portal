# Plan: Centralized User Identity Service — SSO Claims Forwarding

## Context

Currently every authenticated request only carries `X-Forwarded-User` (email). `thomseddon/traefik-forward-auth` v2 is a compiled Go binary that parses the Azure AD OIDC ID token at login time but only forwards the email claim. The ID token already contains `name`, `given_name`, `family_name`, and `roles` (app roles) — but the binary discards them.

The goal is to enrich identity forwarding with full name and Azure AD App Roles, without any service account or admin-level Graph API permissions. All data comes from the OIDC ID token that Azure AD issues during the normal user SSO login.

**Approach chosen:** Replace `traefik-forward-auth` with a custom Python (FastAPI + authlib) ForwardAuth service (`aai-auth`) that stores the full claim set in the session and forwards three headers. Add a tiny `aai-userinfo` sidecar that turns those headers into a JSON endpoint for project frontends.

---

## Architecture After This Change

```
Browser → Traefik → tfa@docker (ForwardAuth)
                         ↓
                    aai-auth service
                    ├── Valid session  → 200 + X-Forwarded-User / X-Forwarded-Name / X-Forwarded-Roles
                    └── No session    → 307 → Azure AD OIDC login (SSO only, no service account)
                                             ↓ ID token contains email + name + roles
                                        Store in signed session cookie
                                        307 → original URL

Each protected project backend receives:
  X-Forwarded-User:  user@domain.com
  X-Forwarded-Name:  Fabien Chazal
  X-Forwarded-Roles: Developer,Admin      ← from Azure AD App Roles

Browser GET https://userinfo.BASE_DOMAIN/userinfo
  → protected by tfa@docker
  → aai-userinfo reads the three injected headers
  → returns { email, name, roles[] } JSON
```

---

## Azure AD Configuration (one-time, no admin consent for Graph API)

1. **OIDC scopes**: ensure the App Registration requests `openid email profile`. The `profile` scope makes Azure AD include `name`, `given_name`, `family_name` in the ID token. No extra permissions needed.

2. **App Roles**: in the App Registration manifest, define roles (e.g. `Developer`, `Admin`). In Entra ID → Enterprise Applications → [App] → Users and Groups, assign each user a role. Azure AD then includes a `roles` claim in the ID token automatically — no Graph API call required.

3. **No new permissions, no admin consent, no service principal credentials beyond the existing `AZURE_CLIENT_ID / SECRET`.**

---

## Files to Create

### `auth/` directory (new — replaces traefik-forward-auth)

#### `auth/requirements.txt`
```
fastapi==0.115.*
uvicorn[standard]==0.32.*
authlib==1.3.*
httpx==0.27.*
itsdangerous==2.2.*
python-multipart==0.0.*
PyJWT[crypto]==2.9.*
cryptography==43.*
```

#### `auth/Dockerfile`
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
CMD ["uvicorn", "main.py:app", "--host", "0.0.0.0", "--port", "4181"]
```

#### `auth/main.py` (~280 lines, key sections below)

**Session format** — `itsdangerous.URLSafeTimedSerializer` signs a JSON payload:
```python
{
  "email": "user@domain.com",
  "name": "Fabien Chazal",
  "given_name": "Fabien",
  "family_name": "Chazal",
  "roles": ["Developer"],
  "exp": 1234567890          # UNIX timestamp, 12h TTL
}
```
Cookie name: `_aai_session`, domain: `${COOKIE_DOMAIN}`, httpOnly, Secure, SameSite=Lax.

**ForwardAuth handler logic** (called by Traefik for every request):
```
GET /_oauth?code=...&state=...   →  handle_callback()
All other paths                  →  check_session()
```

`check_session()`:
1. Deserialise `_aai_session` cookie with `itsdangerous` (verifies signature + expiry)
2. If valid → return `200` with headers:
   ```
   X-Forwarded-User:  {email}
   X-Forwarded-Name:  {name}
   X-Forwarded-Roles: {roles joined with comma}
   ```
3. If invalid/missing → build Azure AD authorize URL (with PKCE, state, nonce) →  return `307`

`handle_callback()`:
1. Verify state (CSRF) from a separate short-lived `_aai_state` cookie
2. Exchange code for tokens via `authlib` AsyncOAuth2Client (token_endpoint)
3. Decode ID token with `PyJWT` — verify signature against JWKS, validate aud/iss/nonce
4. Extract claims: `email`, `name`, `given_name`, `family_name`, `roles` (list, default [])
5. Sign session with `itsdangerous`, set cookie
6. `307` → original URL from state

**PKCE**: generate `code_verifier` (random 43-128 bytes), store in state cookie alongside original URL and nonce. Include `code_challenge` in authorization URL.

**OIDC discovery**: fetch `https://login.microsoftonline.com/{TENANT_ID}/v2.0/.well-known/openid-configuration` once at startup (cached) to get `authorization_endpoint`, `token_endpoint`, `jwks_uri`.

**Environment variables consumed** (same names as current traefik-forward-auth, no `.env` changes):
```
AZURE_TENANT_ID
AZURE_CLIENT_ID
AZURE_CLIENT_SECRET
COOKIE_SECRET          ← used as itsdangerous secret key
COOKIE_DOMAIN          ← e.g. aai.chetbu.fr
AUTH_HOST              ← e.g. auth.aai.chetbu.fr
URL_PATH               ← /_oauth  (redirect URI path)
```

---

### `userinfo/` directory (new — tiny service)

#### `userinfo/requirements.txt`
```
fastapi==0.115.*
uvicorn[standard]==0.32.*
```

#### `userinfo/Dockerfile`
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
CMD ["uvicorn", "main.py:app", "--host", "0.0.0.0", "--port", "8080"]
```

#### `userinfo/main.py` (~40 lines)
```python
from fastapi import FastAPI, Header
from typing import Optional

app = FastAPI()

@app.get("/userinfo")
async def userinfo(
    x_forwarded_user: Optional[str] = Header(None),
    x_forwarded_name: Optional[str] = Header(None),
    x_forwarded_roles: Optional[str] = Header(None),
):
    roles = [r.strip() for r in (x_forwarded_roles or "").split(",") if r.strip()]
    return {
        "email": x_forwarded_user,
        "name":  x_forwarded_name,
        "roles": roles,
    }

@app.get("/health")
async def health():
    return {"status": "ok", "service": "userinfo"}
```

The service has no secrets — it only reads headers injected by Traefik after ForwardAuth validates the session. 

For project **backends** (internal Docker network, no Traefik), they already receive the three headers directly — no need to call this service at all.

---

## Files to Modify

### `docker-compose.yml`

**Remove** the `traefik-forward-auth` service block entirely.

**Add** two new services and update the `authResponseHeaders` label:

```yaml
  # ── AAI Auth (ForwardAuth + OIDC, replaces traefik-forward-auth) ──────────
  auth:
    build:
      context: .
      dockerfile: auth/Dockerfile
    container_name: aai-auth
    restart: unless-stopped
    environment:
      - AZURE_TENANT_ID=${AZURE_TENANT_ID}
      - AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
      - AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
      - COOKIE_SECRET=${COOKIE_SECRET}
      - COOKIE_DOMAIN=${BASE_DOMAIN}
      - AUTH_HOST=auth.${BASE_DOMAIN}
      - URL_PATH=/_oauth
    networks:
      - aai-public
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: '0.25'
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=aai-public"
      - "traefik.http.routers.aai-auth.rule=Host(`auth.${BASE_DOMAIN}`)"
      - "traefik.http.routers.aai-auth.tls.certresolver=letsencrypt"
      - "traefik.http.routers.aai-auth.middlewares=tfa@docker"
      - "traefik.http.services.aai-auth.loadbalancer.server.port=4181"
      # ForwardAuth middleware definition (referenced as tfa@docker by all other routers)
      - "traefik.http.middlewares.tfa.forwardAuth.address=http://aai-auth:4181"
      - "traefik.http.middlewares.tfa.forwardAuth.trustForwardHeader=true"
      - "traefik.http.middlewares.tfa.forwardAuth.authResponseHeaders=X-Forwarded-User,X-Forwarded-Name,X-Forwarded-Roles"
      - "traefik.http.middlewares.tfa.forwardAuth.maxResponseBodySize=1048576"

  # ── AAI Userinfo (JSON endpoint for project frontends) ────────────────────
  userinfo:
    build:
      context: .
      dockerfile: userinfo/Dockerfile
    container_name: aai-userinfo
    restart: unless-stopped
    networks:
      - aai-public
    deploy:
      resources:
        limits:
          memory: 64M
          cpus: '0.1'
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=aai-public"
      - "traefik.http.routers.userinfo.rule=Host(`userinfo.${BASE_DOMAIN}`)"
      - "traefik.http.routers.userinfo.tls.certresolver=letsencrypt"
      - "traefik.http.routers.userinfo.middlewares=tfa@docker,secure-headers@file"
      - "traefik.http.services.userinfo.loadbalancer.server.port=8080"
```

**Key diff on line 74** (current `authResponseHeaders`):
```diff
- "traefik.http.middlewares.tfa.forwardAuth.authResponseHeaders=X-Forwarded-User"
+ "traefik.http.middlewares.tfa.forwardAuth.authResponseHeaders=X-Forwarded-User,X-Forwarded-Name,X-Forwarded-Roles"
```

### `.env.example`
No new variables needed. All env vars are already present.

### `docs/guides/integrate_existing_project.md` and `new_project_greenfield.md`
Update the identity headers section to document all three headers, and add a "User Info API" section:

```markdown
## Identity Headers (injected by Traefik on every authenticated request)

| Header               | Example value          | Notes                      |
|----------------------|------------------------|----------------------------|
| `X-Forwarded-User`   | `user@domain.com`      | Azure AD email             |
| `X-Forwarded-Name`   | `Fabien Chazal`        | Display name from AAD      |
| `X-Forwarded-Roles`  | `Developer,Admin`      | Comma-separated app roles  |

## User Info JSON API (for project frontends)

Browser:
```js
const user = await fetch('https://userinfo.BASE_DOMAIN/userinfo').then(r => r.json());
// { email, name, roles: [] }
```

Project backend: read the three headers directly — no HTTP call needed.
```

### `docs/architecture/authentification_fix_with_Azure.md`
Add a section documenting the migration from `traefik-forward-auth` to `aai-auth` and the motivation.

---

## Migration Notes

- The new `aai-auth` session cookie (`_aai_session`) is incompatible with the old traefik-forward-auth cookie. All users will be logged out once on deploy — expected behavior.
- The redirect URI registered in Azure AD App Registration (`https://auth.${BASE_DOMAIN}/_oauth`) does not change.
- The `AUTH_HOST` mode behavior is preserved: all OAuth callbacks route through `auth.${BASE_DOMAIN}`, not per-service hosts.
- PKCE is added (traefik-forward-auth didn't use it). No Azure AD change needed — Azure AD supports PKCE for all app types.

---

## Verification

1. `make up` → all three infra containers start: `aai-traefik`, `aai-auth`, `aai-userinfo`, `aai-portal`
2. Open `https://BASE_DOMAIN` in browser → redirected to Azure AD login (SSO flow)
3. After login → portal loads correctly; verify `X-Forwarded-Name` in portal nginx access log (or a test echo endpoint)
4. `curl https://userinfo.BASE_DOMAIN/userinfo` from browser session → returns `{email, name, roles}`
5. Test unauthenticated request → 307 redirect to Azure AD (not 401)
6. Verify no existing project breaks: all still receive `X-Forwarded-User` (backward-compatible)
7. Log out (clear cookie), attempt access → re-authenticates via Azure AD
8. Assign an App Role to a user in Entra ID → verify `X-Forwarded-Roles` contains role name after re-login
