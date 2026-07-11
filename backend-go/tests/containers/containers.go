//go:build integration

package containers

import (
	"context"
	"fmt"
	"time"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/modules/redis"
	"github.com/testcontainers/testcontainers-go/wait"
)

// PostgresContainer wraps a running Postgres container with its connection string.
type PostgresContainer struct {
	Container  testcontainers.Container
	ConnString string
}

// RedisContainer wraps a running Redis container with its address.
type RedisContainer struct {
	Container testcontainers.Container
	Addr      string
}

// NATSContainer wraps a running NATS container with its URL.
type NATSContainer struct {
	Container testcontainers.Container
	URL       string
}

// QdrantContainer wraps a running Qdrant container with its gRPC and HTTP addresses.
type QdrantContainer struct {
	Container testcontainers.Container
	GRPCAddr  string
	HTTPAddr  string
}

// StartPostgres starts a Postgres 16-alpine container and returns the connection string.
func StartPostgres(ctx context.Context) (*PostgresContainer, error) {
	container, err := postgres.RunContainer(ctx,
		testcontainers.WithImage("postgres:16-alpine"),
		postgres.WithDatabase("test"),
		postgres.WithUsername("postgres"),
		postgres.WithPassword("password"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(30*time.Second),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to start postgres container: %w", err)
	}

	connString, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		_ = container.Terminate(ctx)
		return nil, fmt.Errorf("failed to get postgres connection string: %w", err)
	}

	return &PostgresContainer{
		Container:  container,
		ConnString: connString,
	}, nil
}

// StartRedis starts a Redis 7-alpine container and returns the address.
func StartRedis(ctx context.Context) (*RedisContainer, error) {
	container, err := redis.RunContainer(ctx,
		testcontainers.WithImage("redis:7-alpine"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("Ready to accept connections").
				WithStartupTimeout(30*time.Second),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to start redis container: %w", err)
	}

	addr, err := container.ConnectionString(ctx)
	if err != nil {
		_ = container.Terminate(ctx)
		return nil, fmt.Errorf("failed to get redis address: %w", err)
	}

	return &RedisContainer{
		Container: container,
		Addr:      addr,
	}, nil
}

// StartNATS starts a NATS 2.10-alpine container with JetStream enabled and returns the URL.
func StartNATS(ctx context.Context) (*NATSContainer, error) {
	req := testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "nats:2.10-alpine",
			ExposedPorts: []string{"4222/tcp"},
			Cmd:          []string{"-js"},
			WaitingFor: wait.ForLog("Listening for client connections").
				WithStartupTimeout(30 * time.Second),
		},
		Started: true,
	}

	container, err := testcontainers.GenericContainer(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("failed to start nats container: %w", err)
	}

	host, err := container.Host(ctx)
	if err != nil {
		_ = container.Terminate(ctx)
		return nil, fmt.Errorf("failed to get nats host: %w", err)
	}

	port, err := container.MappedPort(ctx, "4222")
	if err != nil {
		_ = container.Terminate(ctx)
		return nil, fmt.Errorf("failed to get nats port: %w", err)
	}

	return &NATSContainer{
		Container: container,
		URL:       fmt.Sprintf("nats://%s:%s", host, port.Port()),
	}, nil
}

// StartQdrant starts a Qdrant v1.12.4 container and returns gRPC and HTTP addresses.
func StartQdrant(ctx context.Context) (*QdrantContainer, error) {
	req := testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "qdrant/qdrant:v1.12.4",
			ExposedPorts: []string{"6333/tcp", "6334/tcp"},
			WaitingFor: wait.ForLog("Qdrant HTTP server initialized").
				WithStartupTimeout(30 * time.Second),
		},
		Started: true,
	}

	container, err := testcontainers.GenericContainer(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("failed to start qdrant container: %w", err)
	}

	host, err := container.Host(ctx)
	if err != nil {
		_ = container.Terminate(ctx)
		return nil, fmt.Errorf("failed to get qdrant host: %w", err)
	}

	httpPort, err := container.MappedPort(ctx, "6333")
	if err != nil {
		_ = container.Terminate(ctx)
		return nil, fmt.Errorf("failed to get qdrant http port: %w", err)
	}

	grpcPort, err := container.MappedPort(ctx, "6334")
	if err != nil {
		_ = container.Terminate(ctx)
		return nil, fmt.Errorf("failed to get qdrant grpc port: %w", err)
	}

	return &QdrantContainer{
		Container: container,
		HTTPAddr:  fmt.Sprintf("http://%s:%s", host, httpPort.Port()),
		GRPCAddr:  fmt.Sprintf("%s:%s", host, grpcPort.Port()),
	}, nil
}
