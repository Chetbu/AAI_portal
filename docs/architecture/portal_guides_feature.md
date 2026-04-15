# Portal Guides Viewer

## Context

The `docs/guides/` directory holds step-by-step onboarding guides for the platform, but they were only accessible by cloning the repo. Team members deploying or integrating projects had to leave the portal and hunt through git to find them. This feature surfaces those guides directly in the portal UI.

---

## Design Decisions

### Client-side markdown rendering (no backend)

The portal is a **static nginx container with no backend API**. Options considered:

| Option | Verdict |
|---|---|
| Client-side markdown rendering (chosen) | Zero new infrastructure, fits the existing static pattern |
| Pre-render to HTML at build time (pandoc) | Adds a heavy build dependency for a small payoff |
| Separate docs microservice (MkDocs, etc.) | Overkill; adds a new container, DNS entry, and auth registration |

Client-side rendering via **marked.js** was the natural fit — one `<script>` tag, the markdown files are plain static assets served by nginx.

### marked.js bundled at build time

marked.js is downloaded during the Docker build (`RUN curl ...`), not loaded from a CDN at runtime. This avoids a runtime external dependency — the portal works fully offline and is not affected by CDN availability.

Version pinned to `marked@9.1.6` in the Dockerfile. To upgrade, update the version in the `RUN curl` line and rebuild.

### Guide list hardcoded in HTML

The guide list is hardcoded in `index.html` rather than added to `config.json.template`. Rationale:

- Guides are static infrastructure documentation — they only change when code in this repo changes.
- `config.json` is designed for dynamic project registration (it changes every time a new project is onboarded).
- Adding guides to `config.json` would conflate two unrelated concerns.

Only files under `docs/guides/` are bundled in the portal image and accessible at runtime. Files in `docs/architecture/` are reference/traceability documents intended for repo readers, not served via the portal.

To add a new guide: drop a `.md` file in `docs/guides/`, add a card to the `<div class="guides-grid">` block in `index.html`.

### Build context change

The original `docker-compose.yml` used `build: ./portal` (context = the `portal/` subdirectory), which made `docs/guides/` unreachable from the Dockerfile. The build context was changed to the repo root:

```yaml
# Before
build: ./portal

# After
build:
  context: .
  dockerfile: portal/Dockerfile
```

All `COPY` paths in `portal/Dockerfile` were updated with the `portal/` prefix to match. No other behaviour changed.

---

## Files Changed

### `docker-compose.yml`
- Portal `build:` key expanded from shorthand to long form with `context: .` and `dockerfile: portal/Dockerfile`.

### `portal/Dockerfile`
- All `COPY` paths prefixed with `portal/` (required after build context change).
- Added `COPY docs/guides/ /usr/share/nginx/html/guides/` — embeds all guide markdown files in the image.
- Added `RUN curl` to download and vendor `marked.min.js` into `/usr/share/nginx/html/`.

### `portal/nginx.conf`
- Added `location /guides/` block: serves `.md` files as `text/plain; charset=utf-8` with no-cache headers. Without this, the generic `try_files` catch-all would eventually serve the file correctly, but with the wrong `Content-Type`.

### `portal/index.html`
- Added CSS for:
  - `.section-heading` — small-caps label for section separators
  - `.guides-grid` / `.guide-card` — card grid reusing existing CSS variables and hover patterns
  - `.modal-overlay` / `.modal-container` / `.modal-header` / `.modal-body` — full-screen modal
  - `.markdown-body` — typography styles for rendered markdown (headings, code blocks, tables, blockquotes, links)
- Added HTML: "Guides" section with 4 hardcoded guide cards + a modal `<div>` (hidden by default).
- Added `<script src="/marked.min.js">` tag.
- Added JS:
  - `openGuide(slug, title)` — fetches `/guides/<slug>.md`, calls `marked.parse()`, injects HTML into modal.
  - `closeGuide()` — hides modal, restores body scroll.
  - Event listeners for backdrop click and Escape key to close modal.

---

## Runtime Flow

```
User clicks guide card
  → openGuide('new_project_greenfield', 'New Project (Greenfield)')
    → fetch('/guides/new_project_greenfield.md')   [nginx serves text/plain]
      → marked.parse(text)                          [client-side rendering]
        → modal shown with rendered HTML
```

---

## Adding a New Guide

1. Add the `.md` file to `docs/guides/`.
2. Add a card to the `<div class="guides-grid">` block in `portal/index.html`:
   ```html
   <div class="guide-card" onclick="openGuide('your_filename', 'Display Title')">
       <div class="guide-card-title">Display Title</div>
       <div class="guide-card-desc">One-line description.</div>
       <div class="guide-card-action"><span class="btn btn-secondary">Read guide</span></div>
   </div>
   ```
3. Rebuild and restart the portal: `make restart`.
