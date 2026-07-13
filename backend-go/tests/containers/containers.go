//go:build integration

// Package containers provides reusable Testcontainers-Go fixtures for
// integration tests. Each helper spins up a real service container, returns
// the address needed to connect, and provides a cleanup function that
// terminates the container.
//
// Usage:
//
//	func TestSomething(t *testing.T) {
//	    ctx := context.Background()
//	    dsn, cleanup := containers.StartPostgres(ctx, t)
//	    defer cleanup()
//	    // use dsn …
//	}
package containers

import (
	"context"
	"fmt"
	"testing"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	tcredis "github.com/testcontainers/testcontainers-go/modules/redis"
	"github.com/testcontainers/testcontainers-go/wait"
)

// StartPostgres starts a postgres:16-alpine container and returns a
// postgresql:// DSN (sslmode=disable) and a cleanup function.
func StartPostgres(ctx context.Context, t testing.TB) (connStr string, cleanup func()) {
	t.Helper()

	ctr, err := postgres.Run(ctx, "postgres:16-alpine",
		postgres.WithDatabase("testdb"),
		postgres.WithUsername("test"),
		postgres.WithPassword("test"),
	)
	if err != nil {
		t.Fatalf("containers: start postgres: %v", err)
	}

	dsn, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		_ = ctr.Terminate(context.Background())
		t.Fatalf("containers: postgres connection string: %v", err)
	}

	return dsn, func() {
		if terr := ctr.Terminate(context.Background()); terr != nil {
			t.Logf("containers: terminate postgres: %v", terr)
		}
	}
}

// StartRedis starts a redis:7-alpine container and returns a host:port
// address and a cleanup function.
func StartRedis(ctx context.Context, t testing.TB) (addr string, cleanup func()) {
	t.Helper()

	ctr, err := tcredis.Run(ctx, "redis:7-alpine")
	if err != nil {
		t.Fatalf("containers: start redis: %v", err)
	}

	endpoint, err := ctr.Endpoint(ctx, "")
	if err != nil {
		_ = ctr.Terminate(context.Background())
		t.Fatalf("containers: redis endpoint: %v", err)
	}

	return endpoint, func() {
		if terr := ctr.Terminate(context.Background()); terr != nil {
			t.Logf("containers: terminate redis: %v", terr)
		}
	}
}

// StartNATS starts a nats:2.10-alpine container with JetStream enabled
// (-js flag) and returns a nats:// URL and a cleanup function.
func StartNATS(ctx context.Context, t testing.TB) (natsURL string, cleanup func()) {
	t.Helper()

	ctr, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "nats:2.10-alpine",
			ExposedPorts: []string{"4222/tcp"},
			Cmd:          []string{"-js"},
			WaitingFor:   wait.ForLog("Server is ready"),
		},
		Started: true,
	})
	if err != nil {
		t.Fatalf("containers: start nats: %v", err)
	}

	host, err := ctr.Host(ctx)
	if err != nil {
		_ = ctr.Terminate(context.Background())
		t.Fatalf("containers: nats host: %v", err)
	}

	mappedPort, err := ctr.MappedPort(ctx, "4222/tcp")
	if err != nil {
		_ = ctr.Terminate(context.Background())
		t.Fatalf("containers: nats mapped port: %v", err)
	}

	return fmt.Sprintf("nats://%s:%s", host, mappedPort.Port()), func() {
		if terr := ctr.Terminate(context.Background()); terr != nil {
			t.Logf("containers: terminate nats: %v", terr)
		}
	}
}

// StartQdrant starts a qdrant/qdrant:v1.12.0 container and returns the
// gRPC address (port 6334) and HTTP address (port 6333) as "host:port"
// strings, plus a cleanup function.
func StartQdrant(ctx context.Context, t testing.TB) (grpcAddr string, httpAddr string, cleanup func()) {
	t.Helper()

	ctr, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "qdrant/qdrant:v1.12.0",
			ExposedPorts: []string{"6333/tcp", "6334/tcp"},
			WaitingFor:   wait.ForHTTP("/healthz").WithPort("6333/tcp"),
		},
		Started: true,
	})
	if err != nil {
		t.Fatalf("containers: start qdrant: %v", err)
	}

	host, err := ctr.Host(ctx)
	if err != nil {
		_ = ctr.Terminate(context.Background())
		t.Fatalf("containers: qdrant host: %v", err)
	}

	httpPort, err := ctr.MappedPort(ctx, "6333/tcp")
	if err != nil {
		_ = ctr.Terminate(context.Background())
		t.Fatalf("containers: qdrant HTTP port: %v", err)
	}

	grpcPort, err := ctr.MappedPort(ctx, "6334/tcp")
	if err != nil {
		_ = ctr.Terminate(context.Background())
		t.Fatalf("containers: qdrant gRPC port: %v", err)
	}

	return fmt.Sprintf("%s:%s", host, grpcPort.Port()),
		fmt.Sprintf("%s:%s", host, httpPort.Port()),
		func() {
			if terr := ctr.Terminate(context.Background()); terr != nil {
				t.Logf("containers: terminate qdrant: %v", terr)
			}
		}
}
