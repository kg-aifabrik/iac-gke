"""Builds authenticated Google API clients from Application Default Credentials.

All authentication and network side effects live here, at the edge. The checks
in ``checks.py`` receive these clients (or already-resolved values) as plain
arguments so they stay pure and unit-testable.

The same ``google.auth.default()`` call transparently returns operator user
credentials locally and federated (external_account) credentials inside GitHub
Actions, so one code path serves both environments.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import google.auth
import google_auth_httplib2
import httplib2
from google.auth.transport.requests import AuthorizedSession, Request
from googleapiclient.discovery import build

logger = logging.getLogger(__name__)

CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo"
_HTTP_TIMEOUT_SECONDS = 30


@dataclass
class Clients:
    """The API clients and credentials the checks need."""

    iam: Any
    serviceusage: Any
    resourcemanager: Any
    cloudkms: Any
    privateca: Any
    certificatemanager: Any
    compute: Any
    container: Any
    gkebackup: Any
    dns: Any
    session: AuthorizedSession
    credentials: Any


def _authorized_http(credentials: Any) -> google_auth_httplib2.AuthorizedHttp:
    # Wrap credentials in an http with an explicit timeout so a hung call
    # cannot block the verifier indefinitely (requirement REL-2).
    return google_auth_httplib2.AuthorizedHttp(
        credentials, http=httplib2.Http(timeout=_HTTP_TIMEOUT_SECONDS)
    )


def build_clients() -> Clients:
    """Resolve Application Default Credentials and build the API clients.

    Returns:
        A :class:`Clients` bundle.

    Raises:
        google.auth.exceptions.DefaultCredentialsError: if no credentials resolve.
    """
    credentials, _ = google.auth.default(scopes=[CLOUD_PLATFORM_SCOPE])
    # cache_discovery=False avoids stale discovery docs and a noisy file-cache warning.
    iam = build("iam", "v1", http=_authorized_http(credentials), cache_discovery=False)
    serviceusage = build(
        "serviceusage", "v1", http=_authorized_http(credentials), cache_discovery=False
    )
    resourcemanager = build(
        "cloudresourcemanager", "v3", http=_authorized_http(credentials), cache_discovery=False
    )
    cloudkms = build("cloudkms", "v1", http=_authorized_http(credentials), cache_discovery=False)
    privateca = build("privateca", "v1", http=_authorized_http(credentials), cache_discovery=False)
    certificatemanager = build(
        "certificatemanager", "v1", http=_authorized_http(credentials), cache_discovery=False
    )
    compute = build("compute", "v1", http=_authorized_http(credentials), cache_discovery=False)
    container = build("container", "v1", http=_authorized_http(credentials), cache_discovery=False)
    gkebackup = build("gkebackup", "v1", http=_authorized_http(credentials), cache_discovery=False)
    dns = build("dns", "v1", http=_authorized_http(credentials), cache_discovery=False)
    session = AuthorizedSession(credentials)
    return Clients(
        iam=iam,
        serviceusage=serviceusage,
        resourcemanager=resourcemanager,
        cloudkms=cloudkms,
        privateca=privateca,
        certificatemanager=certificatemanager,
        compute=compute,
        container=container,
        gkebackup=gkebackup,
        dns=dns,
        session=session,
        credentials=credentials,
    )


def resolve_active_identity(clients: Clients) -> str:
    """Return the email of the identity the credentials authenticate as.

    Forces a token refresh first, which proves the Workload Identity token
    exchange (or impersonation) actually succeeds end to end — not merely that
    configuration exists. Falls back to the OAuth2 ``tokeninfo`` endpoint when
    the credential object does not expose a service-account email (the case for
    operator user credentials).

    Returns:
        The identity email, or "" if it cannot be determined.
    """
    clients.credentials.refresh(Request())

    email = getattr(clients.credentials, "service_account_email", None)
    if email and email != "default":
        return str(email)

    response = clients.session.get(
        TOKENINFO_URL,
        params={"access_token": clients.credentials.token},
        timeout=_HTTP_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return str(response.json().get("email", ""))
