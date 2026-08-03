"""Session-scoped Testcontainers fixtures for backend-python integration tests.

These fixtures spin up real, ephemeral Postgres/Redis/NATS/Qdrant containers so
integration-tagged tests exercise actual backing-service wire protocols instead of
mocks (constitution Principle V — Testing Standards). Each fixture is session-scoped:
one container per service starts once for the whole test session and tears down
after the last test finishes, keeping container churn low across a large suite.

Requires a local Docker daemon. Tests that consume these fixtures should be marked
with `@pytest.mark.integration` (registered in `pyproject.toml`) so they can be
deselected with `pytest -m "not integration"` in fast local/unit runs.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from testcontainers.core.container import DockerContainer
from testcontainers.core.waiting_utils import wait_for_logs
from testcontainers.postgres import PostgresContainer
from testcontainers.redis import RedisContainer

# Pinned to the same image tags used by deploy/docker-compose.yml and
# deploy/do/docker-compose.prod.yml so integration tests exercise the same
# backing-service versions as dev/production.
_POSTGRES_IMAGE = "postgres:16-alpine"
_REDIS_IMAGE = "redis:7-alpine"
_NATS_IMAGE = "nats:2.10-alpine"
_QDRANT_IMAGE = "qdrant/qdrant:v1.12.4"

_NATS_CLIENT_PORT = 4222
_NATS_MONITOR_PORT = 8222
_QDRANT_HTTP_PORT = 6333
_QDRANT_GRPC_PORT = 6334


@pytest.fixture(scope="session")
def postgres_container() -> Iterator[str]:
    """Start a real Postgres container for the session; yield a plain DSN."""
    with PostgresContainer(
        _POSTGRES_IMAGE,
        username="aisat_test",
        password="aisat_test",
        dbname="aisat_test",
        driver=None,
    ) as postgres:
        yield postgres.get_connection_url()


@pytest.fixture(scope="session")
def redis_container() -> Iterator[str]:
    """Start a real Redis container for the session; yield its connection URL."""
    with RedisContainer(_REDIS_IMAGE) as redis:
        host = redis.get_container_host_ip()
        port = redis.get_exposed_port(redis.port)
        yield f"redis://{host}:{port}/0"


@pytest.fixture(scope="session")
def nats_container() -> Iterator[str]:
    """Start a real NATS (JetStream-enabled) container; yield its client URL.

    No dedicated `testcontainers` module ships for NATS, so the generic
    `DockerContainer` wrapper is used directly with explicit port exposure,
    JetStream enabled via `-js`, and a log-based readiness wait.
    """
    container = (
        DockerContainer(_NATS_IMAGE)
        .with_command("-js")
        .with_exposed_ports(_NATS_CLIENT_PORT, _NATS_MONITOR_PORT)
    )
    with container:
        wait_for_logs(container, "Server is ready")
        host = container.get_container_host_ip()
        port = container.get_exposed_port(_NATS_CLIENT_PORT)
        yield f"nats://{host}:{port}"


@pytest.fixture(scope="session")
def qdrant_container() -> Iterator[str]:
    """Start a real Qdrant container for the session; yield its HTTP base URL.

    No dedicated `testcontainers` module ships for Qdrant either, so the
    generic `DockerContainer` wrapper is used here too.
    """
    container = DockerContainer(_QDRANT_IMAGE).with_exposed_ports(
        _QDRANT_HTTP_PORT, _QDRANT_GRPC_PORT
    )
    with container:
        wait_for_logs(container, "Qdrant HTTP listening")
        host = container.get_container_host_ip()
        port = container.get_exposed_port(_QDRANT_HTTP_PORT)
        yield f"http://{host}:{port}"
