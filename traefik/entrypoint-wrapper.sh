#!/bin/sh
set -e

# Substitute env vars into Traefik static config (sed used — envsubst not in Traefik image)
sed "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
  /etc/traefik/traefik.yml.template \
  > /etc/traefik/traefik.yml

# Hand off to the real Traefik entrypoint
exec /entrypoint.sh "$@"
