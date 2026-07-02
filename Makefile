.PHONY: up down migrate dev build test lint eval

up:
	docker compose -f deploy/docker-compose.yml up -d

down:
	docker compose -f deploy/docker-compose.yml down

migrate:
	@echo "Running database migrations..."

dev:
	@echo "Starting development environment..."

build:
	@echo "==> Building Go backend..."
	cd backend-go && go build ./...
	@echo "==> Compiling Python backend..."
	python3 -m py_compile backend-python/src/main.py
	@echo "==> Building React frontend..."
	cd frontend && npm run build

test:
	@echo "==> Testing Go..."
	@echo "==> Testing Python..."
	@echo "==> Testing frontend..."

lint:
	@echo "==> Linting Go..."
	@echo "==> Linting Python..."
	@echo "==> Linting frontend..."

eval:
	@echo "==> Running evals..."
