# setup-doctor

A small Python verifier ("doctor") that confirms the one-time keyless-access
setup for cluster-ctrl is correct and least-privilege — the **FND-2** ("the
setup is verified") requirement.

It runs with one code path in two places:

- **locally**, with an operator's Application Default Credentials (full audit), and
- **in GitHub Actions**, with federated Workload Identity Federation credentials
  (the keyless-connectivity demonstration).

## What it checks

| Check | Verifies | In CI (least-priv SA) |
|---|---|---|
| `active-identity` | Credentials resolve to the expected identity | PASS (asserts it is the automation SA) |
| `required-apis-enabled` | Required APIs are enabled (also the live-API proof) | PASS |
| `wif-provider-scoped` | WIF pool/provider exist; provider pins `repository_id` + `ref` + issuer | SKIP (operator-only read) |
| `service-account-least-privilege` | The SA holds **exactly** the expected roles (flags extra/missing) | SKIP (operator-only read) |

**Cluster-setup checks** — run only in *cluster mode* (when `SETUP_DOCTOR_REGION` is set);
otherwise they SKIP, so a keyless-only run is unchanged:

| Check | Verifies | In CI (least-priv SA) |
|---|---|---|
| `cluster-apis-enabled` | The cluster/supply-chain APIs are enabled | PASS |
| `cmek-grants` | **Both** CMEK grants on the cluster key (GKE→secrets, Compute→disks) | SKIP (operator-only read) |
| `node-sa-least-privilege` | The node SA holds **exactly** its expected project role(s) | SKIP (operator-only read) |
| `connect-gateway-access` | The automation holds the Connect Gateway roles | SKIP (operator-only read) |
| `cas-cas-enabled` | The CAS root + subordinate CAs exist and are ENABLED — the random-suffixed pools are discovered by their `<env>-cas-` prefix (ADR-0002 amendment 3) | SKIP (operator-only read) |
| `external-certs-active` | **Every** external hostname's managed certificate is **ACTIVE** (per-host, ADR-0005) | SKIP (operator-only read) |
| `external-gateway-ip` | The external gateway's global static IP is reserved | SKIP (operator-only read) |

**High-availability checks (Milestone 3)** — cluster mode; each also SKIPs
until its own expectation variables (below) are set:

| Check | Verifies | In CI (least-priv SA) |
|---|---|---|
| `node-pool-autoscaling` | The general pool autoscales between the expected per-zone min/max with `BALANCED` location policy (ADR-0007) | SKIP (operator-only read) |
| `backup-plan` | The cluster's Backup for GKE plan exists and is READY (ADR-0004) | SKIP (operator-only read) |
| `private-dns-zone` | The private zone exists and serves an A record per internal hostname (ADR-0006) | SKIP (operator-only read) |
| `public-dns-zone` | The opt-in public zone exists and serves an A record per external hostname; surfaces the NS set to delegate at the registrar | SKIP (operator-only read) |

A check returns **PASS**, **FAIL** (setup is wrong — fix it), or **SKIP** (the
current identity intentionally lacks the read; not a failure). The process exits
non-zero only on a required FAIL.

## Configuration (environment variables)

| Variable | Required | Meaning |
|---|---|---|
| `SETUP_DOCTOR_PROJECT_NUMBER` | yes | Numeric project number |
| `SETUP_DOCTOR_POOL_ID` | yes | Workload Identity Pool id |
| `SETUP_DOCTOR_PROVIDER_ID` | yes | OIDC provider id |
| `SETUP_DOCTOR_SERVICE_ACCOUNT` | yes | Automation SA email |
| `SETUP_DOCTOR_REPOSITORY_ID` | yes | Immutable GitHub `repository_id` the provider must pin |
| `SETUP_DOCTOR_REF` | yes | Git ref the provider must pin (e.g. `refs/heads/main`) |
| `SETUP_DOCTOR_EXPECTED_ROLES` | no | Comma-separated exact role set for the SA |
| `SETUP_DOCTOR_PROJECT_ID` | no | Alphanumeric id (defaults to the number) |
| `SETUP_DOCTOR_EXPECTED_IDENTITY` | no | If set, the active identity must equal it (CI) |
| `SETUP_DOCTOR_REGION` | no | Cluster region. **Setting it enables the cluster-setup checks** (and locates the `gke-<region>` KMS key) |
| `SETUP_DOCTOR_NODE_SERVICE_ACCOUNT` | no | Node SA email whose project roles are audited (cluster mode) |
| `SETUP_DOCTOR_EXPECTED_NODE_SA_ROLES` | no | Comma-separated exact role set for the node SA (defaults to `roles/container.defaultNodeServiceAccount`) |
| `SETUP_DOCTOR_ENVIRONMENT` | no | Environment name (dev/stage/prod) — the `cas-cas-enabled` check discovers the random-suffixed `<env>-cas-*` pools by prefix (ADR-0002 amendment 3) |
| `SETUP_DOCTOR_CLUSTER` | no | Cluster name (e.g. `dev-fop`) — enables the `node-pool-autoscaling` and `backup-plan` checks |
| `SETUP_DOCTOR_AUTOSCALING_MIN` / `SETUP_DOCTOR_AUTOSCALING_MAX` | no | Expected per-zone autoscaling bounds on the general pool (mirror the fop root) |
| `SETUP_DOCTOR_EXTERNAL_HOSTNAMES` | no | Comma-separated external hostnames — drives `external-certs-active` (one cert per host) and the public-zone record check |
| `SETUP_DOCTOR_INTERNAL_HOSTNAMES` | no | Comma-separated internal hostnames — drives the private-zone record check |
| `SETUP_DOCTOR_INTERNAL_ZONE_DOMAIN` | no | Private zone domain (e.g. `dev.aifabrik.com`) — enables `private-dns-zone` |
| `SETUP_DOCTOR_PUBLIC_ZONE_DOMAIN` | no | Public zone domain — enables `public-dns-zone`; set only while `manage_public_dns` is on |

## Use

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"     # or: pip install -r requirements.lock && pip install -e . --no-deps

setup-doctor          # human-readable table
setup-doctor --json   # machine-readable (used in CI)
```

Run end to end via the runbooks: [`01-keyless-access-setup.md`](../../docs/runbooks/01-keyless-access-setup.md)
(keyless mode) and [`02-cluster-bringup.md` §5](../../docs/runbooks/02-cluster-bringup.md)
(cluster mode, with the full variable set for a built cluster).

## Develop

```bash
pip install -e ".[dev]"
ruff check . && ruff format --check . && mypy && pytest
```

Tests are fully mocked (no network, no real project) and named after the
behavior they prove — they are the executable spec of the setup contract.
Dependencies are pinned in `requirements.lock` for reproducible installs.
