#!/bin/sh
set -e

echo "[portal] Building config.json..."

# Platform section from template
PLATFORM=$(envsubst '${BASE_DOMAIN}' < /etc/portal/config.json.template | jq '.platform')

# Collect project entries from /projects/*/portal.json
PROJECTS_JSON="[]"
for f in /projects/*/portal.json; do
    [ -f "$f" ] || continue
    SLUG=$(jq -r '.slug' "$f")
    echo "[portal]   Registering project: $SLUG"
    ENTRY=$(jq --arg domain "$BASE_DOMAIN" '{
        slug: .slug,
        name: .name,
        description: (.description // ""),
        owner: (.owner // ""),
        url: ("https://" + .slug + "." + $domain),
        port: .port,
        healthInternal: ("http://aai-" + .slug + ":" + (.port | tostring) + "/health"),
        repo: (.repo // "")
    }' "$f")
    PROJECTS_JSON=$(printf '%s' "$PROJECTS_JSON" | jq --argjson e "$ENTRY" '. + [$e]')
done

COUNT=$(printf '%s' "$PROJECTS_JSON" | jq 'length')
echo "[portal] Registered $COUNT project(s)."

jq -n --argjson platform "$PLATFORM" --argjson projects "$PROJECTS_JSON" \
    '{platform: $platform, projects: $projects}' \
    > /usr/share/nginx/html/config.json

echo "[portal] Writing initial empty status.json..."
echo '{}' > /usr/share/nginx/html/status.json

echo "[portal] Starting health checker in background..."
/usr/local/bin/healthcheck.sh &

echo "[portal] Starting nginx..."
exec "$@"
