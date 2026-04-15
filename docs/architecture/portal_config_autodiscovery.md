# Portal Config Auto-Discovery

## Context

Previously, registering a new project in the portal required a manual edit of `portal/config.json.template` in the infrastructure repo — adding a JSON entry with the project's slug, name, URLs, health endpoint, etc. This created a split-ownership problem: project metadata lived in the infrastructure repo rather than with the project itself, so every onboarding required a separate commit in a separate repo.

---

## Design

Each project maintains a `portal.json` at the root of its own repo. The portal container discovers and aggregates these files at startup to build `config.json`.

```
/opt/aai/projects/
├── pipeline/
│   └── portal.json   ← owned by the pipeline team
├── llm-chatbot/
│   └── portal.json   ← owned by the chatbot team
└── ...
```

The `projects/` directory is mounted into the portal container as a read-only volume (`../projects:/projects:ro`). On each container start, `entrypoint.sh` scans `/projects/*/portal.json` and assembles `config.json`.

### `portal.json` schema

```json
{
  "slug": "my-project",
  "name": "My Project",
  "description": "One-line description",
  "owner": "Team or person",
  "port": 8000,
  "repo": "https://github.com/yourorg/my-project"
}
```

| Field | Required | Notes |
|---|---|---|
| `slug` | Yes | Must match `container_name: aai-<slug>` and Traefik router name |
| `name` | Yes | Display name on the portal card |
| `description` | No | Short description |
| `owner` | No | Team or person responsible |
| `port` | Yes | The single port the container exposes; used for health checks and port conflict detection |
| `repo` | No | Adds a "Repository" button to the portal card |

### Single-port constraint

Each project exposes exactly one port externally. Multiple services within a project (frontend, API, MCP) are differentiated by path, not port:

| Path | Convention |
|---|---|
| `/` | Frontend |
| `/api` | REST API |
| `/mcp` | MCP server (Streamable HTTP) |
| `/health` | Health check — must return HTTP 200 |

Internal services (databases, caches) are not exposed externally and are excluded from this constraint.

MCP uses Streamable HTTP transport (the current MCP spec), not SSE. All paths are routed by Traefik on the single exposed port — no exceptions needed.

### Derived fields

`entrypoint.sh` constructs fields that are never hardcoded in `portal.json`:

| Field in `config.json` | Derived as |
|---|---|
| `url` | `https://<slug>.<BASE_DOMAIN>` |
| `port` | passed through as-is from `portal.json` |
| `healthInternal` | `http://aai-<slug>:<port>/health` (always set; down status if `/health` absent) |

`BASE_DOMAIN` is injected as an environment variable at container start — domain names are never hardcoded anywhere.

---

## Config assembly flow

```
Container start
  │
  ├─ envsubst '${BASE_DOMAIN}' < config.json.template       → platform section
  │
  ├─ for f in /projects/*/portal.json:
  │     jq: derive url, port, healthInternal
  │         from slug + healthPort + BASE_DOMAIN
  │     accumulate into projects array
  │
  └─ jq -n: merge platform + projects → /usr/share/nginx/html/config.json
```

If `/projects/` is empty or the volume is not mounted, the projects array is `[]` and the portal renders with no project cards — no crash, no error.

---

## Port conflict detection

The portal frontend computes port conflicts client-side from `config.json` on every data refresh.

**Logic** — a conflict exists when two or more projects declare the same `port` value:

```
portMap: { 8000: ["pipeline", "llm-chatbot"], 8742: ["other-project"] }
conflictCount = 1   (only port 8000 has multiple owners)
conflictsBySlug: {
  "pipeline":    { port: 8000, others: ["llm-chatbot"] },
  "llm-chatbot": { port: 8000, others: ["pipeline"]    }
}
```

**UI surface:**
- **Summary row** — a "Port Conflicts" card shows `0` (neutral) or `N` (orange) at a glance
- **Project cards** — each card shows a port badge (`:8000`) in the meta row; conflicting badges turn orange and display a tooltip naming the other project(s) sharing that port

**Why client-side?** The detection is purely presentational — it requires no persistent state and no backend logic. Computing it in JS on the data already fetched keeps `entrypoint.sh` simple and keeps the detection always consistent with the live `config.json`.

**Scope** — this detects internal port collisions within `portal.json` declarations. Since projects use `expose:` (not `ports:`), Docker-level conflicts on host ports are not possible; the concern is configuration hygiene and future-proofing if a project ever needs host port binding.

---

## Files changed

| File | Change |
|---|---|
| `portal/entrypoint.sh` | Replaced `envsubst` one-liner with `jq` discovery loop; adds `port` field to each project entry |
| `portal/config.json.template` | Removed `projects` array — now contains only `platform` metadata |
| `portal/index.html` | Port badge on project cards; port conflict detection and summary card; conflict tooltip |
| `docker-compose.yml` | Added `../projects:/projects:ro` volume to portal service |
| `scripts/new-project.sh` | Generates `portal.json` in the new project directory; removed the "paste this JSON" output |
| `docs/project-template/portal.json.template` | New reference template for manual onboarding |
| `docs/guides/new_project_greenfield.md` | Updated Part 4: fill in `portal.json` instead of editing infrastructure config |
| `docs/guides/integrate_existing_project.md` | Added step 1.6 (create `portal.json`); simplified Part 2.5 |

---

## Trade-offs and constraints

**Re-registration on restart** — `config.json` is rebuilt from scratch every time the portal container restarts. This is fine because the source of truth is always the mounted files; there is no persistent state to lose.

**Restart required to register new projects** — adding a project to the portal requires `make restart` in the infrastructure directory. A live watch/reload mechanism was not implemented to keep the container simple (no inotify, no polling loop in addition to the health checker). This is acceptable since project onboarding is not a frequent operation.

**No schema validation** — `entrypoint.sh` does not validate `portal.json` beyond what `jq` parses. A malformed file causes that project to be silently skipped (the `jq` call will fail and the loop iteration produces no output). This is intentional — one bad project file should not take down the entire portal.

**Volume path coupling** — the `../projects:/projects:ro` mount assumes the VPS layout is `infrastructure/` and `projects/` as siblings under the same parent. This is documented in `CLAUDE.md` and the guides. If the layout changes, update both the volume in `docker-compose.yml` and this document.
