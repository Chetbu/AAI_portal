#!/bin/sh
set -e

echo "[portal] Substituting environment variables..."
envsubst '${BASE_DOMAIN}' \
  < /etc/portal/config.json.template \
  > /usr/share/nginx/html/config.json

echo "[portal] Writing initial empty status.json..."
echo '{}' > /usr/share/nginx/html/status.json

echo "[portal] Starting health checker in background..."
/usr/local/bin/healthcheck.sh &

echo "[portal] Starting nginx..."
exec "$@"
