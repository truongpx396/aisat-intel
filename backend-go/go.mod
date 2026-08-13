module github.com/truongpx396/aisat-intel/backend-go

go 1.23

require (
	github.com/getsentry/sentry-go v0.28.1
	github.com/gin-gonic/gin v1.10.0
	github.com/nats-io/nats.go v1.37.0
	github.com/redis/go-redis/v9 v9.6.1
	github.com/rs/zerolog v1.33.0
	// testcontainers-go and its module wrappers are integration-test-only
	// dependencies, consumed exclusively by tests/containers (built with the
	// "integration" tag) and *_test.go files under that tag; they are never
	// imported by production code in kernel/ or internal/.
	github.com/testcontainers/testcontainers-go v0.33.0
	github.com/testcontainers/testcontainers-go/modules/postgres v0.33.0
	github.com/testcontainers/testcontainers-go/modules/redis v0.33.0
	go.opentelemetry.io/otel v1.29.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace v1.29.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.29.0
	go.opentelemetry.io/otel/sdk v1.29.0
	go.opentelemetry.io/otel/trace v1.29.0
	gorm.io/driver/postgres v1.5.9
	gorm.io/gorm v1.25.12
)
