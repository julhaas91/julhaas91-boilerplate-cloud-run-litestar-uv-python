from collections.abc import Iterator

import pytest
from litestar import Litestar
from litestar.status_codes import HTTP_200_OK
from litestar.testing import TestClient

from src.main import app


@pytest.fixture(scope="function")
def test_client() -> Iterator[TestClient[Litestar]]:
    with TestClient(app=app) as client:
        yield client


def test_health_check(test_client):
    """
    Function that tests the /health route.
    :param test_client:
    :return: None
    """
    response = test_client.get("/health")

    assert response.status_code == HTTP_200_OK
    assert response.json() == {"status": "ok"}