module github.com/aisat-studio/aisat-studio/backend-go

go 1.23

require (
	github.com/gin-gonic/gin v1.10.0
	gorm.io/gorm v1.25.12
	gorm.io/driver/postgres v1.5.11
	github.com/nats-io/nats.go v1.37.0
	github.com/redis/go-redis/v9 v9.7.0
	go.opentelemetry.io/otel v1.31.0
	go.opentelemetry.io/otel/trace v1.31.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.31.0
	go.opentelemetry.io/otel/sdk v1.31.0
	github.com/rs/zerolog v1.33.0
	github.com/getsentry/sentry-go v0.29.1
	github.com/testcontainers/testcontainers-go v0.34.0
	github.com/testcontainers/testcontainers-go/modules/postgres v0.34.0
	github.com/testcontainers/testcontainers-go/modules/redis v0.34.0
	github.com/google/uuid v1.6.0
)
