"""
Pytest fixtures for integration tests using Testcontainers.

All fixtures are session-scoped to spin up containers once per test session.
Mark integration tests with @pytest.mark.integration.
"""

import pytest
from testcontainers.postgres import PostgresContainer
from testcontainers.redis import RedisContainer
from testcontainers.core.container import DockerContainer


@pytest.fixture(scope="session")
def postgres():
    """Start a Postgres 16-alpine container for integration tests."""
    with PostgresContainer("postgres:16-alpine") as container:
        yield container.get_connection_url()


@pytest.fixture(scope="session")
def redis_fixture():
    """Start a Redis 7-alpine container for integration tests.

    Named redis_fixture to avoid shadowing the redis module.
    """
    with RedisContainer("redis:7-alpine") as container:
        host = container.get_container_host_ip()
        port = container.get_exposed_port(6379)
        yield f"redis://{host}:{port}"


@pytest.fixture(scope="session")
def nats():
    """Start a NATS 2.10-alpine container with JetStream for integration tests."""
    container = DockerContainer("nats:2.10-alpine")
    container.with_command("-js")
    container.with_exposed_ports(4222)
    with container:
        host = container.get_container_host_ip()
        port = container.get_exposed_port(4222)
        yield f"nats://{host}:{port}"


@pytest.fixture(scope="session")
def qdrant():
    """Start a Qdrant v1.12.4 container for integration tests."""
    container = DockerContainer("qdrant/qdrant:v1.12.4")
    container.with_exposed_ports(6333, 6334)
    with container:
        host = container.get_container_host_ip()
        http_port = container.get_exposed_port(6333)
        grpc_port = container.get_exposed_port(6334)
        yield {
            "http_url": f"http://{host}:{http_port}",
            "grpc_port": int(grpc_port),
        }


def pytest_configure(config: pytest.Config) -> None:
    """Register custom markers."""
    config.addinivalue_line(
        "markers",
        "integration: mark test as an integration test (requires Docker)",
    )
