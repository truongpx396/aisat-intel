SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Immutable tag used for local image builds (CI uses the git SHA).
IMAGE_TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
REGISTRY ?= docker.io
IMAGE_PREFIX ?= aisat
DOCKERHUB_USERNAME ?= your-dockerhub-username

# Every runtime target is guarded: absent runtimes are skipped, so `make ci`
# runs cleanly on a specs-only checkout and expands as code lands.
GO_DIR := backend-go
PY_DIR := backend-python
WEB_DIR := frontend

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ------------------------------- lint --------------------------------------
.PHONY: lint lint-go lint-python lint-web
lint: lint-go lint-python lint-web ## Lint all present runtimes
lint-go: ## Lint Go
	@if [ -f $(GO_DIR)/go.mod ]; then cd $(GO_DIR) && golangci-lint run ./...; else echo "skip go (no $(GO_DIR)/go.mod)"; fi
lint-python: ## Lint Python
	@if [ -f $(PY_DIR)/pyproject.toml ]; then cd $(PY_DIR) && uv run ruff check . && uv run ruff format --check .; else echo "skip python"; fi
lint-web: ## Lint frontend
	@if [ -f $(WEB_DIR)/package.json ]; then cd $(WEB_DIR) && npm run lint --if-present; else echo "skip web"; fi

# ------------------------------- test --------------------------------------
.PHONY: test test-go test-python test-web
test: test-go test-python test-web ## Test all present runtimes
test-go: ## Test Go (race + cover)
	@if [ -f $(GO_DIR)/go.mod ]; then cd $(GO_DIR) && go test -race -count=1 ./...; else echo "skip go"; fi
test-python: ## Test Python
	@if [ -f $(PY_DIR)/pyproject.toml ]; then cd $(PY_DIR) && uv run pytest; else echo "skip python"; fi
test-web: ## Test frontend
	@if [ -f $(WEB_DIR)/package.json ]; then cd $(WEB_DIR) && npm run test --if-present; else echo "skip web"; fi

# ------------------------------- build -------------------------------------
.PHONY: build build-go build-web
build: build-go build-web ## Build all present runtimes
build-go: ## Build Go entrypoints
	@if [ -f $(GO_DIR)/go.mod ]; then cd $(GO_DIR) && for c in api relay worker; do [ -d ./cmd/$$c ] && go build -o /dev/null ./cmd/$$c || true; done; else echo "skip go"; fi
build-web: ## Build frontend
	@if [ -f $(WEB_DIR)/package.json ]; then cd $(WEB_DIR) && npm run build --if-present; else echo "skip web"; fi

# ------------------------------- security ----------------------------------
.PHONY: scan
scan: ## Vulnerability scans (present runtimes)
	@if [ -f $(GO_DIR)/go.mod ]; then cd $(GO_DIR) && govulncheck ./... || true; fi
	@if [ -f $(PY_DIR)/pyproject.toml ]; then cd $(PY_DIR) && uvx pip-audit || true; fi
	@if [ -f $(WEB_DIR)/package.json ]; then cd $(WEB_DIR) && npm audit --omit=dev || true; fi

# ------------------------------- docker ------------------------------------
IMG = $(REGISTRY)/$(DOCKERHUB_USERNAME)/$(IMAGE_PREFIX)
.PHONY: docker-build
docker-build: ## Build all present images locally (tag = IMAGE_TAG)
	@[ -f $(GO_DIR)/Dockerfile ]          && docker build -t $(IMG)-backend-go:$(IMAGE_TAG) $(GO_DIR)                         || echo "skip go image"
	@[ -f $(PY_DIR)/Dockerfile ]          && docker build -t $(IMG)-backend-python:$(IMAGE_TAG) $(PY_DIR)                     || echo "skip py image"
	@[ -f $(PY_DIR)/Dockerfile.crawl ]    && docker build -f $(PY_DIR)/Dockerfile.crawl -t $(IMG)-crawl:$(IMAGE_TAG) $(PY_DIR) || echo "skip crawl image"
	@[ -f $(WEB_DIR)/Dockerfile ]         && docker build -t $(IMG)-frontend:$(IMAGE_TAG) $(WEB_DIR)                          || echo "skip web image"

# ---------------------------- local prod stack -----------------------------
COMPOSE_PROD = docker compose -f deploy/do/docker-compose.prod.yml --env-file deploy/do/.env.production
.PHONY: prod-pull prod-up prod-down prod-logs migrate
prod-pull: ## Pull the prod images referenced by deploy/do/.env.production
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_PROD) pull
prod-up: ## Bring the prod stack up locally (needs deploy/do/.env.production)
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_PROD) up -d
prod-down: ## Stop the prod stack
	$(COMPOSE_PROD) down
prod-logs: ## Tail prod logs
	$(COMPOSE_PROD) logs -f --tail=100
migrate: ## Run DB migrations against the prod stack
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_PROD) --profile migrate run --rm migrate

# ---------------------- monitoring overlay (DO droplet) --------------------
# Prometheus · Grafana · cAdvisor · Node Exporter · Loki · Tempo · Alertmanager
# · Promtail · Langfuse — layered on top of the prod compose project.
COMPOSE_MON = docker compose \
  -f deploy/do/docker-compose.prod.yml \
  -f deploy/do/monitoring/docker-compose.monitoring.yml \
  --env-file deploy/do/.env.production
.PHONY: mon-up mon-down mon-logs mon-ps mon-config
mon-up: ## Bring the full stack up WITH the monitoring overlay (needs .env.production)
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_MON) up -d
mon-down: ## Stop the stack + monitoring overlay
	$(COMPOSE_MON) down
mon-logs: ## Tail monitoring logs (Langfuse is in the base stack — use prod-logs)
	$(COMPOSE_MON) logs -f --tail=100 prometheus grafana loki tempo alertmanager
mon-ps: ## Status of the stack + monitoring overlay
	$(COMPOSE_MON) ps
mon-config: ## Validate the merged compose config (base + overlay)
	$(COMPOSE_MON) config -q && echo "compose config OK"

# ---------------------------- kubernetes / EKS -----------------------------
HELM_CHART := deploy/eks/helm/aisat
EKS_NAMESPACE ?= aisat
# Sample coordinates so `helm template` renders locally; real deploys inject these.
ECR_REGISTRY ?= 000000000000.dkr.ecr.us-east-1.amazonaws.com
.PHONY: helm-lint helm-template eks-deploy
helm-lint: ## Lint + render the EKS Helm chart (both overlays)
	helm lint $(HELM_CHART)
	helm template aisat $(HELM_CHART) --namespace $(EKS_NAMESPACE) \
	  --set image.registry=$(ECR_REGISTRY) --set image.tag=$(IMAGE_TAG) >/dev/null
	helm template aisat $(HELM_CHART) --namespace $(EKS_NAMESPACE) \
	  -f $(HELM_CHART)/values-production.yaml \
	  --set image.registry=$(ECR_REGISTRY) --set image.tag=$(IMAGE_TAG) \
	  --set ingress.host=example.com --set ingress.certificateArn=arn:aws:acm:x:0:certificate/y >/dev/null
	@echo "helm chart OK"
helm-template: ## Render the chart to stdout (set ECR_REGISTRY / IMAGE_TAG)
	helm template aisat $(HELM_CHART) --namespace $(EKS_NAMESPACE) \
	  --set image.registry=$(ECR_REGISTRY) --set image.tag=$(IMAGE_TAG)

# --- infra + GitOps validation (offline; no cluster/cloud needed) ---
.PHONY: tf-fmt argocd-lint
tf-fmt: ## terraform fmt -check across both deploy paths
	terraform -chdir=deploy/eks/terraform fmt -check -recursive
	terraform -chdir=deploy/do/terraform fmt -check -recursive
argocd-lint: ## YAML-parse the Argo CD app-of-apps manifests (uses Ruby's YAML)
	@for f in $$(find deploy/eks/argocd -name '*.yaml'); do \
	  ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0]))' "$$f" && echo "ok: $$f" || exit 1; \
	done
eks-deploy: ## helm upgrade --install to the current kube-context (needs ECR_REGISTRY, IMAGE_TAG, PRODUCTION_HOST, ACM_CERTIFICATE_ARN)
	helm upgrade --install aisat $(HELM_CHART) \
	  --namespace $(EKS_NAMESPACE) --create-namespace \
	  -f $(HELM_CHART)/values-production.yaml \
	  --set image.registry=$(ECR_REGISTRY) --set image.tag=$(IMAGE_TAG) \
	  --set ingress.host=$(PRODUCTION_HOST) --set ingress.certificateArn=$(ACM_CERTIFICATE_ARN) \
	  --atomic --timeout 15m

# ------------------------------- gate --------------------------------------
.PHONY: ci
ci: lint test build ## Full local gate — mirrors GitHub Actions CI
