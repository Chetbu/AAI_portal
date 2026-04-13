#!/bin/sh
set -e

# Substitute env vars into Traefik static config
envsubst '${ACME_EMAIL}' \
  < /etc/traefik/traefik.yml.template \
  > /etc/traefik/traefik.yml

# Hand off to the real Traefik entrypoint
exec /entrypoint.sh "$@"
