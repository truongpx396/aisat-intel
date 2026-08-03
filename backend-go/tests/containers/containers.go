//go:build integration

// Package containers provides reusable Testcontainers bootstrap helpers that
// spin up real backing services — Postgres, Redis, NATS, and Qdrant — for Go
// integration tests. It is compiled only under the "integration" build tag,
// so it is excluded from the default `go test ./...` run and exercised via
// `go test -tags=integration ./...` (Constitution Principle V).
package containers

import (
	"context"
	"fmt"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/modules/redis"
	"github.com/testcontainers/testcontainers-go/wait"
)

const (
	// Pinned to the same versions used in deploy/docker-compose.yml and
	// deploy/do/docker-compose.prod.yml, so integration tests exercise the
	// same backing-service versions as dev/prod.
	postgresImage = "postgres:16-alpine"
	redisImage    = "redis:7-alpine"
	natsImage     = "nats:2.10-alpine"
	qdrantImage   = "qdrant/qdrant:v1.12.4"

	postgresUser     = "aisat"
	postgresPassword = "aisat"
	postgresDB       = "aisat"

	natsClientPort = "4222/tcp"
	qdrantHTTPPort = "6333/tcp"
)

// StartPostgres launches a disposable Postgres container and returns it
// along with a ready-to-use DSN (sslmode disabled, suitable for local
// integration tests only). Callers MUST terminate the returned container,
// typically via `testcontainers.TerminateContainer` in `t.Cleanup`.
func StartPostgres(ctx context.Context) (*postgres.PostgresContainer, string, error) {
	container, err := postgres.Run(ctx, postgresImage,
		postgres.WithDatabase(postgresDB),
		postgres.WithUsername(postgresUser),
		postgres.WithPassword(postgresPassword),
	)
	if err != nil {
		return nil, "", fmt.Errorf("start postgres container: %w", err)
	}

	dsn, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		return nil, "", fmt.Errorf("build postgres dsn: %w", err)
	}

	return container, dsn, nil
}

// StartRedis launches a disposable Redis container and returns it along
// with a ready-to-use connection URL. Callers MUST terminate the returned
// container once the test finishes.
func StartRedis(ctx context.Context) (*redis.RedisContainer, string, error) {
	container, err := redis.Run(ctx, redisImage)
	if err != nil {
		return nil, "", fmt.Errorf("start redis container: %w", err)
	}

	uri, err := container.ConnectionString(ctx)
	if err != nil {
		return nil, "", fmt.Errorf("build redis connection string: %w", err)
	}

	return container, uri, nil
}

// StartNATS launches a disposable NATS container with JetStream enabled,
// using a generic container definition since testcontainers-go does not
// ship a dedicated NATS module. JetStream is required, not optional: every
// subject in this project is a JetStream stream (see
// specs/001-contextengine-mvp/contracts/nats-subjects.md), so plain core
// NATS is insufficient for integration tests. Callers MUST terminate the
// returned container once the test finishes.
func StartNATS(ctx context.Context) (testcontainers.Container, string, error) {
	req := testcontainers.ContainerRequest{
		Image:        natsImage,
		ExposedPorts: []string{natsClientPort},
		Cmd:          []string{"-js"},
		WaitingFor:   wait.ForLog("Server is ready"),
	}

	container, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	if err != nil {
		return nil, "", fmt.Errorf("start nats container: %w", err)
	}

	endpoint, err := container.Endpoint(ctx, "nats")
	if err != nil {
		return nil, "", fmt.Errorf("resolve nats endpoint: %w", err)
	}

	return container, endpoint, nil
}

// StartQdrant launches a disposable Qdrant container using a generic
// container definition, since testcontainers-go does not ship a dedicated
// Qdrant module. It returns the container and the HTTP API base URL.
// Callers MUST terminate the returned container once the test finishes.
func StartQdrant(ctx context.Context) (testcontainers.Container, string, error) {
	req := testcontainers.ContainerRequest{
		Image:        qdrantImage,
		ExposedPorts: []string{qdrantHTTPPort},
		WaitingFor:   wait.ForLog("Qdrant HTTP listening"),
	}

	container, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	if err != nil {
		return nil, "", fmt.Errorf("start qdrant container: %w", err)
	}

	endpoint, err := container.Endpoint(ctx, "http")
	if err != nil {
		return nil, "", fmt.Errorf("resolve qdrant endpoint: %w", err)
	}

	return container, endpoint, nil
}
