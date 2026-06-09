# In-cluster TLS platform add-ons

The controllers that issue and distribute certificates in the cluster, plus the CAS issuer
and the trust bundle that depend on them. The pipeline installs these over Connect Gateway
after the cluster is up (design §8, ADR-0002). Versions are **pinned** for reproducibility —
bump deliberately.

| Add-on | Purpose | Pinned version | Availability |
|---|---|---|---|
| **cert-manager** | issues + renews certificates in-cluster | `v1.16.2` | **HA**: 2 replicas per component + PodDisruptionBudgets, `platform-critical` priority |
| **google-cas-issuer** | cert-manager external issuer backed by Certificate Authority Service | `v0.11.0` | single replica (deliberate — see below) |
| **trust-manager** | distributes the CAS root bundle to namespaces | `v0.13.0` | single replica (deliberate — see below) |

cert-manager runs highly available because a node drain must never stop certificate
issuance (design §5). trust-manager and google-cas-issuer stay single-replica on purpose: a
PodDisruptionBudget on one replica blocks node drains, and a brief pause is tolerable
because certificate renewal and bundle distribution are asynchronous.

*(Confirm/bump exact versions at build.)*

## Install order (run by the pipeline)

```bash
# 1. cert-manager (CRDs + controller)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version v1.16.2 --set crds.enabled=true

# 2. trust-manager (depends on cert-manager)
helm upgrade --install trust-manager jetstack/trust-manager \
  --namespace cert-manager --version v0.13.0

# 3. google-cas-issuer — the Kubernetes service account is annotated for Workload
#    Identity so it impersonates the CAS service account (no keys).
helm upgrade --install google-cas-issuer jetstack/cert-manager-google-cas-issuer \
  --namespace cert-manager --version v0.11.0 \
  --set "serviceAccount.annotations.iam\.gke\.io/gcp-service-account=${CERT_MANAGER_GSA}"
```

## Then apply the config (rendered by the env wiring)

- `cas-issuer.yaml` — the `GoogleCASClusterIssuer` (placeholders substituted from Terraform
  outputs: `PROJECT_ID`, `GCP_REGION`, `CAS_POOL`).
- The **`cas-root-ca` ConfigMap** (in `cert-manager`) — rendered by the env wiring from the
  `private-ca` module's `root_ca_pem` output (key `ca.crt`); it is the **source** for the
  bundle below. Its name must differ from the Bundle's target name.
- `trust-bundle.yaml` — the trust-manager `Bundle` named `cas-root` that fans the root out to
  every namespace as a `cas-root` ConfigMap (the **target**), which workload clients mount to
  trust internal endpoints.

The matching Google-side identity (the CAS service account, its `certificateRequester` grant,
and the Workload-Identity binding to the `cert-manager-google-cas-issuer` KSA) is created by
the `private-ca` Terraform module.
