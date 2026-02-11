include .env
export

.PHONY: setup teardown deploy status port-forward logs test-data render

# === Cluster lifecycle ===

setup:
	./scripts/setup.sh

teardown:
	kind delete cluster --name watchtower

# === Deploy LGTM stack ===

deploy: deploy-tempo deploy-loki deploy-mimir deploy-grafana deploy-alloy
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

enable-local-only:
	kubectl create configmap alloy-config \
		-n watchtower \
		--from-file=config.alloy=alloy/config-local-only.alloy \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl rollout restart deployment alloy -n watchtower
	@echo "Alloy reverted to local LGTM only."

disable-local-only:
	kubectl create configmap alloy-config \
		-n watchtower \
		--from-file=config.alloy=alloy/config.alloy \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl rollout restart deployment alloy -n watchtower
	@echo "Alloy restored to dual-write (LGTM + Sumo Logic)."

# === Operations ===

status:
	kubectl get pods -n watchtower -o wide
	@echo ""
	kubectl get svc -n watchtower

port-forward:
	@echo "Starting port-forwards (Ctrl+C to stop)..."
	@echo "Grafana:  http://localhost:$(GRAFANA_PORT) ($(GRAFANA_ADMIN_USER) / $(GRAFANA_ADMIN_PASSWORD))"
	@echo "OTLP:     localhost:$(OTLP_GRPC_PORT) (gRPC), localhost:$(OTLP_HTTP_PORT) (HTTP)"
	@./scripts/port-forward.sh

logs:
	kubectl logs -n watchtower -l app.kubernetes.io/name=alloy -f --tail=50

# === Test data ===

test-data:
	cd test-data && pip install -r requirements.txt --break-system-packages && \
		python generate.py --endpoint localhost:14317 --rate 10

# === Learning: render Helm templates to see raw manifests ===

render:
	@mkdir -p helm/rendered
	helm template tempo grafana/tempo -f helm/values/tempo.yaml > helm/rendered/tempo.yaml
	helm template loki grafana/loki -f helm/values/loki.yaml > helm/rendered/loki.yaml
	helm template mimir grafana/mimir-distributed -f helm/values/mimir.yaml > helm/rendered/mimir.yaml
	helm template grafana grafana/grafana -f helm/values/grafana.yaml > helm/rendered/grafana.yaml
	helm template alloy grafana/alloy -f helm/values/alloy.yaml > helm/rendered/alloy.yaml
	@echo "Rendered manifests written to helm/rendered/"
	@echo "Open these files to see what Helm generates under the hood."
