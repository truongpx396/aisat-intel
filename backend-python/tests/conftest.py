"""Pytest configuration and shared fixtures for the AISAT-STUDIO test suite.

Will host Testcontainers fixtures (Postgres/Redis/NATS/Qdrant) for
`pytest -m integration`. The testcontainers import is deferred into the fixture
body so this conftest loads without the package installed.
"""

import pytest


def pytest_configure(config):
    """Register custom pytest markers."""
    config.addinivalue_line(
        "markers",
        "integration: mark test as an integration test requiring containers",
    )


@pytest.fixture
def container_placeholder(request):
    """Placeholder fixture; real Testcontainers wiring is added later."""
    if "integration" in request.keywords:
        # Deferred import: actual testcontainers logic will go here.
        pass
    yield None
