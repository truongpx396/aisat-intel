# AISAT-STUDIO — root Makefile (canonical task entrypoint for all three runtimes)

.PHONY: help up down migrate dev build test test-integration test-e2e lint format eval install

# Default target
help:
	@echo ""
	@echo "AISAT-STUDIO — available targets"
	@echo "────────────────────────────────────────────────────────────"
	@echo "  up               Start all infra containers (docker compose)"
	@echo "  down             Stop all infra containers"
	@echo "  migrate          Run DB migrations (Go) + Qdrant bootstrap (Python)"
	@echo "  dev              Start all three dev servers in parallel"
	@echo "  build            Build all three runtimes"
	@echo "  test             Run unit tests across all runtimes"
	@echo "  test-integration Run integration tests (Go + Python)"
	@echo "  test-e2e         Run Playwright end-to-end tests (frontend)"
	@echo "  lint             Lint all runtimes"
	@echo "  format           Auto-format all runtimes"
	@echo "  eval             Run Phase 1 LLM eval suite"
	@echo "  install          Install all runtime dependencies"
	@echo "────────────────────────────────────────────────────────────"
	@echo ""

## ── Infrastructure ──────────────────────────────────────────────────────────

up:
	docker compose -f deploy/docker-compose.yml up -d

down:
	docker compose -f deploy/docker-compose.yml down

## ── Migrations ───────────────────────────────────────────────────────────────

migrate:
	cd backend-go && go run ./cmd/migrate
	cd backend-python && uv run python -m src.services.retrieval.bootstrap

## ── Development ──────────────────────────────────────────────────────────────

dev:
	@echo ""
	@echo "Starting all dev servers in parallel…"
	@echo "  Go BFF   → http://localhost:8080"
	@echo "  Python   → http://localhost:8000"
	@echo "  Frontend → http://localhost:5173"
	@echo "Press Ctrl-C to stop all servers."
	@echo ""
	@( \
		cd backend-go && go run ./cmd/api & \
		cd backend-python && uv run uvicorn src.main:app --port 8000 --reload & \
		cd frontend && npm run dev & \
		wait \
	)

## ── Build ────────────────────────────────────────────────────────────────────

build:
	cd backend-go && go build ./...
	cd backend-python && uv build
	cd frontend && npm run build

## ── Tests ────────────────────────────────────────────────────────────────────

test:
	cd backend-go && go test ./... -count=1
	cd backend-python && uv run pytest tests/ -m "not integration"
	cd frontend && npm test

test-integration:
	cd backend-go && go test -tags=integration ./... -count=1
	cd backend-python && uv run pytest tests/ -m integration

test-e2e:
	cd frontend && npm run test:e2e

## ── Quality ──────────────────────────────────────────────────────────────────

lint:
	cd backend-go && golangci-lint run
	cd backend-python && uv run ruff check src/ tests/ && uv run black --check src/ tests/
	cd frontend && npm run lint && npm run typecheck

format:
	cd backend-go && gofmt -w .
	cd backend-python && uv run ruff check --fix src/ tests/ && uv run black src/ tests/
	cd frontend && npm run format

## ── Evals ────────────────────────────────────────────────────────────────────

eval:
	cd backend-python && uv run python evals/run.py

## ── Install ──────────────────────────────────────────────────────────────────

install:
	cd backend-go && go mod tidy
	cd backend-python && uv sync --all-extras
	cd frontend && npm install
