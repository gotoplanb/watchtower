# Watchtower — local observability (LGTM) + SonarQube stack.
#
# `make help` is auto-generated: any target with a `## description` after its colon
# shows up. Add the comment when you add a target — no hand-curated list to drift.
#
# .env is optional for `make help` (soft -include); the deploy/port-forward targets DO
# need it — copy it first: `cp .env.example .env`.
-include .env
export

.DEFAULT_GOAL := help

.PHONY: help setup teardown deploy deploy-tempo deploy-loki deploy-mimir deploy-grafana deploy-alloy \
        enable-local-only disable-local-only status port-forward logs test-data render \
        docker-up docker-down docker-logs docker-status docker-clean test

help: ## Show this list (any target with a trailing comment)
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'

# === Cluster lifecycle ===

setup: ## Create the kind cluster (scripts/setup.sh)
	./scripts/setup.sh

teardown: ## Delete the kind cluster
	kind delete cluster --name watchtower

# === Deploy LGTM stack ===

deploy: deploy-tempo deploy-loki deploy-mimir deploy-grafana deploy-alloy ## Deploy the full LGTM stack via Helm (tempo/loki/mimir/grafana/alloy)
	@echo "All components deployed. Run 'make status' to check pod health."
	@echo "Run 'make port-forward' to access Grafana at http://localhost:$(GRAFANA_PORT)"

deploy-tempo:
	helm upgrade --install tempo grafana/tempo \
		-n watchtower \
		-f helm/values/tempo.yaml

deploy-loki:
	helm upgrade --install loki grafana/loki \
		-n watchtower \
		-f helm/values/loki.yaml

deploy-mimir:
	helm upgrade --install mimir grafana/mimir-distributed \
		-n watchtower \
		-f helm/values/mimir.yaml

deploy-grafana:
	helm upgrade --install grafana grafana/grafana \
		-n watchtower \
		-f helm/values/grafana.yaml

deploy-alloy:
	kubectl create configmap alloy-config \
		-n watchtower \
		--from-file=config.alloy=alloy/config.alloy \
		--dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install alloy grafana/alloy \
		-n watchtower \
		-f helm/values/alloy.yaml

# === Switch Alloy to local-only mode (if Sumo endpoint is unavailable) ===

enable-local-only: ## Switch Alloy to local-LGTM-only (drop the Sumo write)
	kubectl create configmap alloy-config \
		-n watchtower \
		--from-file=config.alloy=alloy/config-local-only.alloy \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl rollout restart deployment alloy -n watchtower
	@echo "Alloy reverted to local LGTM only."

disable-local-only: ## Restore Alloy dual-write (LGTM + Sumo Logic)
	kubectl create configmap alloy-config \
		-n watchtower \
		--from-file=config.alloy=alloy/config.alloy \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl rollout restart deployment alloy -n watchtower
	@echo "Alloy restored to dual-write (LGTM + Sumo Logic)."

# === Operations ===

status: ## Show watchtower pod + service status
	kubectl get pods -n watchtower -o wide
	@echo ""
	kubectl get svc -n watchtower

port-forward: ## Port-forward Grafana + OTLP to localhost (needs .env)
	@echo "Starting port-forwards (Ctrl+C to stop)..."
	@echo "Grafana:  http://localhost:$(GRAFANA_PORT) ($(GRAFANA_ADMIN_USER) / $(GRAFANA_ADMIN_PASSWORD))"
	@echo "OTLP:     localhost:$(OTLP_GRPC_PORT) (gRPC), localhost:$(OTLP_HTTP_PORT) (HTTP)"
	@./scripts/port-forward.sh

logs: ## Tail Alloy logs (kind cluster)
	kubectl logs -n watchtower -l app.kubernetes.io/name=alloy -f --tail=50

# === Tests ===

test: ## Run the repo's test suite (no docker daemon needed)
	python3 -m unittest discover -s tests -v

# === Test data ===

test-data: ## Generate synthetic OTLP test data at localhost:14317
	cd test-data && pip install -r requirements.txt --break-system-packages && \
		python generate.py --endpoint localhost:14317 --rate 10

# === Learning: render Helm templates to see raw manifests ===

render: ## Render Helm templates to helm/rendered/ (learning aid)
	@mkdir -p helm/rendered
	helm template tempo grafana/tempo -f helm/values/tempo.yaml > helm/rendered/tempo.yaml
	helm template loki grafana/loki -f helm/values/loki.yaml > helm/rendered/loki.yaml
	helm template mimir grafana/mimir-distributed -f helm/values/mimir.yaml > helm/rendered/mimir.yaml
	helm template grafana grafana/grafana -f helm/values/grafana.yaml > helm/rendered/grafana.yaml
	helm template alloy grafana/alloy -f helm/values/alloy.yaml > helm/rendered/alloy.yaml
	@echo "Rendered manifests written to helm/rendered/"
	@echo "Open these files to see what Helm generates under the hood."

# =============================================================================
# Docker Compose Deployment (alternative to Kind/Helm)
# =============================================================================

docker-up: ## Start the stack via docker-compose (the primary path)
	docker-compose up -d
	@echo ""
	@echo "Watchtower stack started!"
	@echo "  Grafana:   http://localhost:3000 (admin / watchtower)"
	@echo "  OTLP gRPC: localhost:4317"
	@echo "  OTLP HTTP: localhost:4318"
	@echo ""
	@echo "Run 'make docker-logs' to tail Alloy logs"

docker-down: ## Stop the docker-compose stack
	docker-compose down

docker-logs: ## Tail Alloy logs (docker-compose)
	docker-compose logs -f alloy

docker-status: ## docker-compose ps
	docker-compose ps

docker-clean: ## docker-compose down -v (removes volumes — deletes all data)
	docker-compose down -v
	@echo "Volumes removed. All data deleted."
