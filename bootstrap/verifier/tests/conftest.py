"""Deterministic test fakes for setup-doctor checks.

The checks receive API clients as arguments, so tests inject lightweight fakes
that mimic the google-api-python-client chained-call shape
(``client.resource().method(...).execute()``) and either return a canned dict
or raise an ``HttpError``. No network access; no real project.
"""

from __future__ import annotations

import dataclasses

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


class _CryptoKeysNs:
    def __init__(self, policy: object, error: HttpError | None) -> None:
        self._policy = policy
        self._error = error

    def getIamPolicy(self, resource: str) -> _Request:  # noqa: N802 - matches API method name
        return _Request(self._policy, self._error)


class FakeKms:
    """Fakes ``cloudkms.projects().locations().keyRings().cryptoKeys().getIamPolicy()``."""

    def __init__(self, policy: dict | None = None, error: HttpError | None = None) -> None:
        self._ck = _CryptoKeysNs(policy if policy is not None else {"bindings": []}, error)

    def projects(self) -> FakeKms:
        return self

    def locations(self) -> FakeKms:
        return self

    def keyRings(self) -> FakeKms:  # noqa: N802 - matches API method name
        return self

    def cryptoKeys(self) -> _CryptoKeysNs:  # noqa: N802 - matches API method name
        return self._ck


class FakePrivateCa:
    """Fakes the CAS certificate-authority get. ``states`` maps a CA id to its state."""

    def __init__(
        self, states: dict[str, str] | None = None, error: HttpError | None = None
    ) -> None:
        self._states = states or {}
        self._error = error

    def projects(self) -> FakePrivateCa:
        return self

    def locations(self) -> FakePrivateCa:
        return self

    def caPools(self) -> FakePrivateCa:  # noqa: N802 - matches API method name
        return self

    def certificateAuthorities(self) -> FakePrivateCa:  # noqa: N802 - matches API method name
        return self

    def get(self, name: str) -> _Request:
        ca = name.split("/certificateAuthorities/")[-1]
        return _Request(result={"state": self._states.get(ca, "ENABLED")}, error=self._error)


class _CertificatesNs:
    def __init__(self, cert: object, error: HttpError | None) -> None:
        self._cert = cert
        self._error = error

    def get(self, name: str) -> _Request:
        return _Request(self._cert, self._error)


class FakeCertificateManager:
    """Fakes ``certificatemanager.projects().locations().certificates().get().execute()``."""

    def __init__(self, state: str = "ACTIVE", error: HttpError | None = None) -> None:
        self._certs = _CertificatesNs({"managed": {"state": state}}, error)

    def projects(self) -> FakeCertificateManager:
        return self

    def locations(self) -> FakeCertificateManager:
        return self

    def certificates(self) -> _CertificatesNs:
        return self._certs


class FakeCompute:
    """Fakes ``compute.globalAddresses().get(project=, address=).execute()``."""

    def __init__(self, status: str = "RESERVED", error: HttpError | None = None) -> None:
        self._status = status
        self._error = error

    def globalAddresses(self) -> FakeCompute:  # noqa: N802 - matches API method name
        return self

    def get(self, project: str, address: str) -> _Request:
        return _Request(result={"status": self._status}, error=self._error)


class FakeContainer:
    """Fakes ``container.projects().locations().clusters().nodePools().get()``."""

    def __init__(self, pool: dict | None = None, error: HttpError | None = None) -> None:
        self._pool = pool if pool is not None else {}
        self._error = error

    def projects(self) -> FakeContainer:
        return self

    def locations(self) -> FakeContainer:
        return self

    def clusters(self) -> FakeContainer:
        return self

    def nodePools(self) -> FakeContainer:  # noqa: N802 - matches API method name
        return self

    def get(self, name: str) -> _Request:
        return _Request(result=self._pool, error=self._error)


class FakeGkeBackup:
    """Fakes ``gkebackup.projects().locations().backupPlans().get()``."""

    def __init__(self, plan: dict | None = None, error: HttpError | None = None) -> None:
        self._plan = plan if plan is not None else {"state": "READY"}
        self._error = error

    def projects(self) -> FakeGkeBackup:
        return self

    def locations(self) -> FakeGkeBackup:
        return self

    def backupPlans(self) -> FakeGkeBackup:  # noqa: N802 - matches API method name
        return self

    def get(self, name: str) -> _Request:
        return _Request(result=self._plan, error=self._error)


class _RrsetsNs:
    def __init__(self, records: set[str], error: HttpError | None) -> None:
        self._records = records
        self._error = error

    def get(self, project: str, managedZone: str, name: str, type: str) -> _Request:  # noqa: A002,N803
        if self._error is not None:
            return _Request(error=self._error)
        if name in self._records:
            return _Request(result={"name": name, "type": type})
        return _Request(error=http_error(404))


class FakeDns:
    """Fakes Cloud DNS zone + record-set reads.

    ``records`` holds the record names (with trailing dot) that exist; lookups
    for anything else return 404, mimicking ``resourceRecordSets.get``.
    """

    def __init__(
        self,
        zone: dict | None = None,
        records: set[str] | None = None,
        zone_error: HttpError | None = None,
        record_error: HttpError | None = None,
    ) -> None:
        self._zone = zone if zone is not None else {"visibility": "private"}
        self._zone_error = zone_error
        self._rrsets = _RrsetsNs(records or set(), record_error)

    def managedZones(self) -> FakeDns:  # noqa: N802 - matches API method name
        return self

    def get(self, project: str, managedZone: str) -> _Request:  # noqa: N803 - matches API
        return _Request(result=self._zone, error=self._zone_error)

    def resourceRecordSets(self) -> _RrsetsNs:  # noqa: N802 - matches API method name
        return self._rrsets


@pytest.fixture
def config() -> Config:
    """A representative Config for the checks under test."""
    return Config(
        project_number="123456789012",
        pool_id="github",
        provider_id="iac-gke",
        service_account_email="cluster-ctrl-automation@example.iam.gserviceaccount.com",
        expected_repository_id="1260827836",
        expected_ref="refs/heads/main",
        expected_roles=frozenset({"roles/serviceusage.serviceUsageViewer"}),
        expected_identity_email="cluster-ctrl-automation@example.iam.gserviceaccount.com",
    )


@pytest.fixture
def cluster_config(config: Config) -> Config:
    """A Config with cluster mode enabled (a region + node SA configured)."""
    return dataclasses.replace(
        config,
        region="us-central1",
        environment="dev",
        node_service_account_email="gke-node@example.iam.gserviceaccount.com",
    )


@pytest.fixture
def ha_config(cluster_config: Config) -> Config:
    """A Config with the Milestone-3 high-availability expectations set."""
    return dataclasses.replace(
        cluster_config,
        cluster_name="dev-fop",
        autoscaling_min_per_zone=1,
        autoscaling_max_per_zone=2,
        external_hostnames=("app.dev.arthos.app", "hello.dev.arthos.app"),
        internal_hostnames=("hello.dev.aifabrik.com", "tools.dev.aifabrik.com"),
        internal_zone_domain="dev.aifabrik.com",
        public_zone_domain="dev.arthos.app",
    )
