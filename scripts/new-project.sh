#!/bin/bash
set -e

# Usage: ./scripts/new-project.sh <slug> <name> [port] [owner]
# Example: ./scripts/new-project.sh my-app "My App" 8000 alice
#
# PROJECTS_DIR defaults to /opt/aai/projects but can be overridden:
#   PROJECTS_DIR=/tmp/test ./scripts/new-project.sh ...

SLUG="$1"
NAME="$2"
PORT="${3:-8000}"
OWNER="${4:-unassigned}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../docs/project-template"
PROJECTS_DIR="${PROJECTS_DIR:-/opt/aai/projects}"

# ── Validate args ─────────────────────────────────────────────
if [ -z "$SLUG" ] || [ -z "$NAME" ]; then
    echo "Usage: $0 <slug> <name> [port] [owner]"
    echo "Example: $0 my-app 'My App' 8000 alice"
    exit 1
fi

PROJECT_DIR="${PROJECTS_DIR}/${SLUG}"

if [ -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} already exists"
    exit 1
fi

echo "Creating project: ${NAME} (${SLUG})"
echo "  Directory: ${PROJECT_DIR}"
echo "  Port:      ${PORT}"
echo "  Owner:     ${OWNER}"
echo ""

# ── Create directory ──────────────────────────────────────────
mkdir -p "${PROJECT_DIR}/src"

# ── Fill and copy templates ───────────────────────────────────
sed \
    -e "s/__PROJECT_NAME__/${NAME}/g" \
    -e "s/__PROJECT_SLUG__/${SLUG}/g" \
    -e "s/__APP_PORT__/${PORT}/g" \
    "${TEMPLATE_DIR}/docker-compose.yml.template" > "${PROJECT_DIR}/docker-compose.yml"

cp "${TEMPLATE_DIR}/Makefile.template"      "${PROJECT_DIR}/Makefile"
cp "${TEMPLATE_DIR}/gitignore.template"     "${PROJECT_DIR}/.gitignore"
cp "${TEMPLATE_DIR}/env.example.template"   "${PROJECT_DIR}/.env.example"
cp "${PROJECT_DIR}/.env.example"            "${PROJECT_DIR}/.env"

# ── portal.json (read by the portal container to register this project) ───
cat > "${PROJECT_DIR}/portal.json" << JSON
{
  "slug": "${SLUG}",
  "name": "${NAME}",
  "description": "TODO: Add description",
  "owner": "${OWNER}",
  "port": ${PORT},
  "repo": "TODO: Add repo URL"
}
JSON

# ── Minimal Python placeholder app ───────────────────────────
cat > "${PROJECT_DIR}/src/main.py" << PYTHON
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "service": "${SLUG}"}).encode())
        else:
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b"""<!DOCTYPE html>
<html>
<body style="font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;background:#0f172a;color:#e2e8f0;">
  <div style="text-align:center;">
    <h1>${NAME}</h1>
    <p>Placeholder — replace with your application.</p>
  </div>
</body>
</html>""")

    def log_message(self, format, *args):
        print(f"[${SLUG}] {args[0]}")

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', ${PORT}), Handler)
    print(f"[${SLUG}] Starting on port ${PORT}")
    server.serve_forever()
PYTHON

# ── Dockerfile ────────────────────────────────────────────────
cat > "${PROJECT_DIR}/Dockerfile" << DOCKER
FROM python:3.12-slim
WORKDIR /app
COPY src/ .
EXPOSE ${PORT}
CMD ["python", "main.py"]
DOCKER

# ── Init git repo ─────────────────────────────────────────────
cd "${PROJECT_DIR}"
git init
git add -A
git commit -m "chore: scaffold project ${SLUG}"

echo ""
echo "Project created at: ${PROJECT_DIR}"
echo ""
echo "Next steps:"
echo "  1. Fill in description and repo in ${PROJECT_DIR}/portal.json"
echo "  2. cd ${PROJECT_DIR} && make up"
echo "  3. Run 'make restart' in the infrastructure directory to register the project in the portal."
