"""Deterministic test fakes for setup-doctor checks.

The checks receive API clients as arguments, so tests inject lightweight fakes
that mimic the google-api-python-client chained-call shape
(``client.resource().method(...).execute()``) and either return a canned dict
or raise an ``HttpError``. No network access; no real project.
"""

from __future__ import annotations

import httplib2
import pytest
from googleapiclient.errors import HttpError

from setup_doctor.config import Config


def http_error(status: int) -> HttpError:
    """Build an HttpError carrying the given HTTP status code."""
    resp = httplib2.Response({"status": status})
    return HttpError(resp, b"{}", uri="https://example.test")


class _Request:
    """A fake request whose ``execute()`` returns a result or raises."""

    def __init__(self, result: object = None, error: HttpError | None = None) -> None:
        self._result = result
        self._error = error

    def execute(self, num_retries: int = 0) -> object:
        if self._error is not None:
            raise self._error
        return self._result


class FakeServiceUsage:
    """Fakes ``serviceusage.services().get(name=...).execute()``.

    ``states`` maps an API name to its state; unlisted APIs default to ENABLED.
    """

    def __init__(
        self, states: dict[str, str] | None = None, error: HttpError | None = None
    ) -> None:
        self._states = states or {}
        self._error = error

    def services(self) -> FakeServiceUsage:
        return self

    def get(self, name: str) -> _Request:
        api = name.split("/services/")[-1]
        return _Request(result={"state": self._states.get(api, "ENABLED")}, error=self._error)


class _ProvidersNs:
    def __init__(self, provider: object, error: HttpError | None) -> None:
        self._provider = provider
        self._error = error

    def get(self, name: str) -> _Request:
        return _Request(self._provider, self._error)


class _PoolsNs:
    def __init__(
        self,
        pool: object,
        pool_error: HttpError | None,
        provider: object,
        provider_error: HttpError | None,
    ) -> None:
        self._pool = pool
        self._pool_error = pool_error
        self._provider = provider
        self._provider_error = provider_error

    def get(self, name: str) -> _Request:  # pool get
        return _Request(self._pool, self._pool_error)

    def providers(self) -> _ProvidersNs:
        return _ProvidersNs(self._provider, self._provider_error)


class _ServiceAccountsNs:
    def __init__(self, error: HttpError | None) -> None:
        self._error = error

    def get(self, name: str) -> _Request:
        return _Request({"email": name.split("/")[-1]}, self._error)


class _IamLocations:
    def __init__(self, pools: _PoolsNs) -> None:
        self._pools = pools

    def workloadIdentityPools(self) -> _PoolsNs:  # noqa: N802 - matches API method name
        return self._pools


class _IamProjects:
    def __init__(self, pools: _PoolsNs, sa_error: HttpError | None) -> None:
        self._pools = pools
        self._sa_error = sa_error

    def locations(self) -> _IamLocations:
        return _IamLocations(self._pools)

    def serviceAccounts(self) -> _ServiceAccountsNs:  # noqa: N802 - matches API method name
        return _ServiceAccountsNs(self._sa_error)


class FakeIam:
    """Fakes the IAM v1 surface used for WIF pools/providers and service accounts."""

    def __init__(
        self,
        pool: object | None = None,
        provider: object | None = None,
        pool_error: HttpError | None = None,
        provider_error: HttpError | None = None,
        sa_error: HttpError | None = None,
    ) -> None:
        self._pools = _PoolsNs(pool, pool_error, provider, provider_error)
        self._sa_error = sa_error

    def projects(self) -> _IamProjects:
        return _IamProjects(self._pools, self._sa_error)


class FakeResourceManager:
    """Fakes ``resourcemanager.projects().getIamPolicy(...).execute()``."""

    def __init__(self, policy: dict | None = None, error: HttpError | None = None) -> None:
        self._policy = policy if policy is not None else {"bindings": []}
        self._error = error

    def projects(self) -> FakeResourceManager:
        return self

    def getIamPolicy(self, resource: str, body: dict) -> _Request:  # noqa: N802 - matches API
        return _Request(self._policy, self._error)


@pytest.fixture
def config() -> Config:
    """A representative Config for the checks under test."""
    return Config(
        project_number="152743400949",
        pool_id="github",
        provider_id="iac-gke",
        service_account_email="cluster-ctrl-automation@example.iam.gserviceaccount.com",
        expected_repository_id="1260827836",
        expected_ref="refs/heads/main",
        expected_roles=frozenset({"roles/serviceusage.serviceUsageViewer"}),
        expected_identity_email="cluster-ctrl-automation@example.iam.gserviceaccount.com",
    )
