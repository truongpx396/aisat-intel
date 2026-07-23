SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Project directories
GO_DIR := backend-go
PY_DIR := backend-python
FE_DIR := frontend
DOCKER_COMPOSE_FILE := deploy/docker-compose.yml
DOCKER_COMPOSE := docker compose

# Color output for help
HELP_COLOR := \033[36m
RESET := \033[0m

# All targets that don't produce files
.PHONY: help up down logs build build-go build-python build-frontend \
        dev dev-go dev-python dev-frontend \
        test test-go test-go-integration test-python test-frontend test-e2e \
        lint lint-go lint-python lint-frontend \
        migrate migrate-down eval \
        install install-go install-python install-frontend clean

## Help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "} {printf "$(HELP_COLOR)%-25s$(RESET) %s\n", $$1, $$2}'

# ============================================================================
# Infrastructure targets
# ============================================================================

up: ## Start all infra services (postgres, redis, qdrant, nats, minio, casdoor, caddy)
	@$(DOCKER_COMPOSE) -f $(DOCKER_COMPOSE_FILE) up -d

down: ## Stop all services
	@$(DOCKER_COMPOSE) -f $(DOCKER_COMPOSE_FILE) down

logs: ## Follow service logs
	@$(DOCKER_COMPOSE) -f $(DOCKER_COMPOSE_FILE) logs -f

# ============================================================================
# Build targets
# ============================================================================

build: build-go build-python build-frontend ## Build all runtimes (Go, Python, React)

build-go: ## Build Go backend
	@cd $(GO_DIR) && go build ./...

build-python: ## Verify Python backend is importable
	@cd $(PY_DIR) && uv run python -c "import src; print('Build OK')"

build-frontend: ## Build React frontend
	@cd $(FE_DIR) && npm run build

# ============================================================================
# Development targets
# ============================================================================

dev: ## Run all dev servers concurrently (Go :8080, Python :8001, React :5173)
	@echo "Starting all development servers..."
	@echo ""
	@echo "  Go API:       http://localhost:8080"
	@echo "  Python RAG:   http://localhost:8001"
	@echo "  Frontend:     http://localhost:5173"
	@echo ""
	@echo "Press Ctrl+C to stop all servers"
	@echo ""
	@(trap 'kill 0' SIGINT SIGTERM EXIT; \
		cd $(GO_DIR) && go run ./cmd/api/main.go & \
		cd $(PY_DIR) && uv run uvicorn src.main:app --reload --port 8001 & \
		cd $(FE_DIR) && npm run dev & \
		wait)

dev-go: ## Run Go development server (port 8080)
	@cd $(GO_DIR) && go run ./cmd/api/main.go

dev-python: ## Run Python development server (uvicorn, reload, port 8001)
	@cd $(PY_DIR) && uv run uvicorn src.main:app --reload --port 8001

dev-frontend: ## Run React development server (port 5173)
	@cd $(FE_DIR) && npm run dev

# ============================================================================
# Testing targets
# ============================================================================

test: test-go test-python test-frontend ## Run all tests (Go, Python, React)

test-go: ## Run Go unit tests
	@cd $(GO_DIR) && go test ./... -count=1

test-go-integration: ## Run Go integration tests (Testcontainers — requires Docker)
	@cd $(GO_DIR) && go test ./... -tags=integration -count=1

test-python: ## Run Python tests (pytest + coverage)
	@cd $(PY_DIR) && uv run pytest

test-frontend: ## Run React unit/component tests (vitest)
	@cd $(FE_DIR) && npm run test

test-e2e: ## Run Playwright end-to-end tests (requires running app)
	@cd $(FE_DIR) && npm run test:e2e

# ============================================================================
# Linting targets
# ============================================================================

lint: lint-go lint-python lint-frontend ## Lint all runtimes

lint-go: ## Lint Go code (golangci-lint)
	@cd $(GO_DIR) && golangci-lint run

lint-python: ## Lint Python code (ruff + black --check)
	@cd $(PY_DIR) && uv run ruff check src tests && uv run black --check src tests

lint-frontend: ## Lint React/TypeScript code (eslint)
	@cd $(FE_DIR) && npm run lint

# ============================================================================
# Database targets
# ============================================================================

migrate: ## Run database migrations + Qdrant bootstrap
	@cd $(GO_DIR) && go run ./cmd/migrate/main.go up
	@cd $(PY_DIR) && uv run python -m src.services.retrieval.bootstrap

migrate-down: ## Rollback database migrations
	@cd $(GO_DIR) && go run ./cmd/migrate/main.go down

# ============================================================================
# Evaluation targets
# ============================================================================

eval: ## Run Phase-1 evaluation suite
	@cd $(PY_DIR) && uv run python evals/run.py

# ============================================================================
# Installation & Utilities
# ============================================================================

install: install-go install-python install-frontend ## Install all dependencies

install-go: ## Install Go dependencies (go mod download)
	@cd $(GO_DIR) && go mod download

install-python: ## Install Python dependencies (uv sync)
	@cd $(PY_DIR) && uv sync

install-frontend: ## Install Node dependencies (npm install)
	@cd $(FE_DIR) && npm install

clean: ## Remove build artifacts and caches
	@echo "Cleaning build artifacts..."
	@cd $(GO_DIR) && go clean -cache -testcache || true
	@cd $(FE_DIR) && rm -rf dist/ node_modules/.vite || true
	@find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	@echo "Clean complete"

# Default target
.DEFAULT_GOAL := help
