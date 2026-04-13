SHARED_ENV := $(shell cd .. && pwd)/shared.env

.PHONY: up down restart logs ps validate

up:
	docker compose --env-file $(SHARED_ENV) --env-file .env up -d --build

down:
	docker compose --env-file $(SHARED_ENV) --env-file .env down

restart:
	docker compose --env-file $(SHARED_ENV) --env-file .env up -d --force-recreate --build

logs:
	docker compose --env-file $(SHARED_ENV) --env-file .env logs -f

ps:
	docker compose --env-file $(SHARED_ENV) --env-file .env ps

# Dry-run: renders the compose file with all variables substituted
validate:
	docker compose --env-file $(SHARED_ENV) --env-file .env config
