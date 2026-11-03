.DEFAULT_GOAL := help
SHELL := /bin/bash

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

# ── Platform team: set up and run the mirror ──────────────────────────────────
login: ## Log in to Docker Hub, the Scout registry and Artifactory
	@bash scripts/01-login.sh

inspect: ## Show tags, digests and attestations on the Docker Hub side
	@bash scripts/02-inspect.sh

mirror: ## Copy image + all attestations into the Artifactory repo (by digest)
	@bash scripts/03-mirror.sh

verify: ## Prove digests, attestations and signatures in Artifactory
	@bash scripts/04-verify.sh

sync: ## Keep Artifactory in sync continuously (regsync, hourly)
	@set -a; . ./.env; set +a; regsync server -c regsync.yaml

sync-once: ## One regsync pass (what the sync CI workflow runs)
	@set -a; . ./.env; set +a; regsync once -c regsync.yaml

# ── Developers and CI: consume from Artifactory ───────────────────────────────
use: ## Pull/run via the consumer URL, export SBOM + VEX, scan with Docker Scout
	@bash scripts/05-use.sh

app: ## Verify the DHI base, build examples/app FROM it and run it locally
	@bash scripts/06-app.sh

demo: login inspect mirror verify use app ## Full run

.PHONY: help login inspect mirror verify sync sync-once use app demo
