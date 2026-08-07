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

# ---------------------------- local dev infra stack -------------------------
# T005's Stage-1 backing-services stack (postgres/redis/qdrant/nats/minio/
# casdoor/caddy/llm-gateway). The three app runtimes run on the HOST via
# `make dev` below, not as containers here — compare COMPOSE_PROD further
# down, which runs the built app images together with their own backing
# services. Matches specs/001-contextengine-mvp/quickstart.md exactly.
COMPOSE_DEV = docker compose -f deploy/docker-compose.yml
.PHONY: up down migrate dev
up: ## Start the local dev infra stack (postgres/redis/qdrant/nats/minio/casdoor/caddy/llm-gateway)
	$(COMPOSE_DEV) up -d
down: ## Stop the local dev infra stack
	$(COMPOSE_DEV) down
migrate: ## Apply Postgres migrations + Qdrant collection bootstrap against the local dev stack (placeholder; real steps land in T018/T034)
	@if [ -f $(GO_DIR)/migrations/0001_init.sql ]; then \
	  cd $(GO_DIR) && go run ./cmd/api migrate up; \
	else \
	  echo "migrate: $(GO_DIR)/migrations/0001_init.sql not present yet (T018) — nothing to run"; \
	fi
	@# Qdrant collection bootstrap (backend-python/src/services/retrieval/bootstrap.py)
	@# lands with T034 — wire its invocation in here once that script exists.
dev: ## Run all three runtimes concurrently for local dev: go-api :8080, uvicorn :8000, SPA :5173 (Ctrl+C stops all)
	@pids=""; \
	trap 'echo; echo "stopping dev runtimes..."; [ -n "$$pids" ] && kill $$pids 2>/dev/null; wait 2>/dev/null' INT TERM EXIT; \
	if [ -f $(GO_DIR)/go.mod ]; then \
	  (cd $(GO_DIR) && go run ./cmd/api) & pids="$$pids $$!"; \
	else echo "skip go dev (no $(GO_DIR)/go.mod)"; fi; \
	if [ -f $(PY_DIR)/pyproject.toml ]; then \
	  (uv run --project $(PY_DIR) uvicorn src.main:app --reload --port 8000) & pids="$$pids $$!"; \
	else echo "skip python dev (no $(PY_DIR)/pyproject.toml)"; fi; \
	if [ -f $(WEB_DIR)/package.json ]; then \
	  (npm --prefix $(WEB_DIR) run dev) & pids="$$pids $$!"; \
	else echo "skip web dev (no $(WEB_DIR)/package.json)"; fi; \
	if [ -z "$$pids" ]; then \
	  echo "dev: no runtime scaffolded yet (T002/T003/T004) — nothing to run"; \
	  exit 0; \
	fi; \
	wait $$pids

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

# ------------------------------- eval ---------------------------------------
.PHONY: eval
eval: ## Run the Python evals harness (placeholder until T125 lands)
	@if [ -f $(PY_DIR)/evals/run.py ]; then \
	  cd $(PY_DIR) && uv run python evals/run.py; \
	else \
	  echo "eval: $(PY_DIR)/evals/run.py not present yet (T125) — nothing to run"; \
	fi

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
	@# crawl has no image — it runs from backend-python; the crawl4ai toolchain is an E2B microVM template (deploy/sandbox/templates/).
	@[ -f $(WEB_DIR)/Dockerfile ]         && docker build -t $(IMG)-frontend:$(IMAGE_TAG) $(WEB_DIR)                          || echo "skip web image"

# ------------------------------ sandbox tier -------------------------------
# The isolated-execution tier. Templates build from backend-python/ as the BUILD
# CONTEXT (they COPY pyproject.toml + uv.lock) even though the Dockerfiles live in
# deploy/sandbox/templates/ — that is why -f and the context path differ.
#
# macOS note: gVisor (runsc) is Linux-only and Docker Desktop ships only runc, so
# local sandboxes run at a weaker boundary than the droplet. Dev-only concession.
COMPOSE_SBX = docker compose -f deploy/sandbox/docker-compose.sandbox.yml
SBX_TEMPLATES = crawl convert coderun
.PHONY: sandbox-templates sandbox-up sandbox-coderun sandbox-down sandbox-logs sandbox-ps sandbox-verify
sandbox-templates: ## Build the sandbox template images (context = backend-python/)
	@[ -f $(PY_DIR)/pyproject.toml ] || { echo "skip: $(PY_DIR)/pyproject.toml not present yet (T003)"; exit 0; }
	@for t in $(SBX_TEMPLATES); do \
	  echo "==> tmpl-$$t"; \
	  docker build -f deploy/sandbox/templates/tmpl-$$t.Dockerfile \
	    -t $(IMAGE_PREFIX)-sandbox-$$t:$(IMAGE_TAG) $(PY_DIR) || exit 1; \
	done
sandbox-up: ## Start the local crawl + convert sandbox pools
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_SBX) up -d
sandbox-coderun: ## Add the oneshot coderun replicas (N=1; override: make sandbox-coderun N=3)
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_SBX) --profile coderun up -d --scale sandbox-coderun=$(or $(N),1)
sandbox-down: ## Stop the local sandbox tier
	$(COMPOSE_SBX) --profile coderun down
sandbox-logs: ## Tail local sandbox logs
	$(COMPOSE_SBX) --profile coderun logs -f --tail=100
sandbox-ps: ## Status of the local sandbox tier
	$(COMPOSE_SBX) --profile coderun ps
sandbox-verify: ## Assert the sandbox hardening invariants against the rendered config
	@bash deploy/sandbox/verify-hardening.sh

# ---------------------------- local prod stack -----------------------------
COMPOSE_PROD = docker compose -f deploy/do/docker-compose.prod.yml --env-file deploy/do/.env.production
.PHONY: prod-pull prod-up prod-down prod-logs prod-migrate
prod-pull: ## Pull the prod images referenced by deploy/do/.env.production
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_PROD) pull
prod-up: ## Bring the prod stack up locally (needs deploy/do/.env.production)
	IMAGE_TAG=$(IMAGE_TAG) $(COMPOSE_PROD) up -d
prod-down: ## Stop the prod stack
	$(COMPOSE_PROD) down
prod-logs: ## Tail prod logs
	$(COMPOSE_PROD) logs -f --tail=100
prod-migrate: ## Run DB migrations against the prod stack (renamed from `migrate` — T007's `migrate` now targets the LOCAL dev stack)
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
.PHONY: tf-fmt tf-lint argocd-lint
tf-fmt: ## terraform fmt -check across both deploy paths
	terraform -chdir=deploy/eks/terraform fmt -check -recursive
	terraform -chdir=deploy/do/terraform fmt -check -recursive
tf-lint: ## TFLint both deploy paths (needs tflint; run `tflint --init` per dir once)
	cd deploy/eks/terraform && tflint --init && tflint --format compact
	cd deploy/do/terraform && tflint --init && tflint --format compact
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

# --- local Kind smoke-test of the EKS chart (no AWS; see deploy/eks/local) ---
.PHONY: kind-up kind-down kind-argocd
kind-up: ## Local Kind cluster + ingress-nginx + build/load images + helm install
	deploy/eks/local/up.sh
kind-down: ## Delete the local Kind cluster
	deploy/eks/local/down.sh
kind-argocd: ## Install Argo CD on the Kind cluster + apply the observability app-of-apps
	deploy/eks/local/argocd-up.sh

# ------------------------------- gate --------------------------------------
.PHONY: ci
ci: lint test build ## Full local gate — mirrors GitHub Actions CI
