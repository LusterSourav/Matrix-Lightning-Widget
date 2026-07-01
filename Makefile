.PHONY: up down shell status clean

up: secrets/hsm_secret
	docker compose up -d --build
	@echo ""
	@echo "  http://citadel.test — build dashboard"
	@echo "  (add '127.0.0.1 citadel.test' to /etc/hosts)"

down:
	docker compose down

shell:
	docker compose exec lightningd-a lightning-cli --network=regtest

status:
	@docker compose ps --format "table {{.Name}}\t{{.Status}}"
	@echo ""
	@echo "channels:"
	@output=$$(docker compose exec lightningd-a lightning-cli --network=regtest listpeerchannels 2>/dev/null | jq -r '.channels[]? | "\(.peer_id[0:20])... \(.state) \(.funding.local_funds_msat/1000 // "?") sats"' 2>/dev/null); \
	if [ -z "$$output" ]; then echo "(no channels yet)"; else echo "$$output"; fi

clean:
	docker compose down -v
	rm -rf secrets data

secrets/hsm_secret:
	mkdir -p secrets
	openssl rand -hex 32 > secrets/hsm_secret
