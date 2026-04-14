#!/bin/sh
set -e

# Substitute env vars into Traefik static config (sed used — envsubst not in Traefik image)
sed \
  -e "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
  -e "s|\${BASE_DOMAIN}|${BASE_DOMAIN}|g" \
  /etc/traefik/traefik.yml.template \
  > /etc/traefik/traefik.yml

# Hand off to the real Traefik entrypoint
exec /entrypoint.sh "$@"
