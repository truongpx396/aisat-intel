module github.com/aisat-studio/aisat-studio/backend-go

go 1.23.0

toolchain go1.23.0

require (
	github.com/getsentry/sentry-go v0.29.0
	github.com/gin-gonic/gin v1.10.0
	github.com/golang-migrate/migrate/v4 v4.18.1
	github.com/google/uuid v1.6.0
	github.com/nats-io/nats.go v1.37.0
	github.com/redis/go-redis/v9 v9.7.0
	github.com/rs/zerolog v1.33.0
	github.com/testcontainers/testcontainers-go v0.34.0
	github.com/testcontainers/testcontainers-go/modules/postgres v0.34.0
	github.com/testcontainers/testcontainers-go/modules/redis v0.34.0
	go.opentelemetry.io/otel v1.32.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.32.0
	go.opentelemetry.io/otel/sdk v1.32.0
	go.opentelemetry.io/otel/trace v1.32.0
	gorm.io/driver/postgres v1.5.11
	gorm.io/gorm v1.25.12
)

// go.sum is intentionally omitted from version control for this scaffold.
// Run `go mod tidy` from backend-go/ to resolve and pin all indirect
// dependencies and generate a valid go.sum before building or testing.
