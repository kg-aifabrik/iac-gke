# iac-gke

Infrastructure, policy, and automation for **cluster-ctrl** — how we build and
run hardened Google Kubernetes Engine (GKE) clusters on Google Cloud. The
design and requirements live in the companion repo
[`cluster-ctrl`](https://github.com/kg-aifabrik/cluster-ctrl) (`docs/`).

This is the repository whose GitHub Actions automation is trusted to talk to
Google Cloud (keylessly, via Workload Identity Federation). It is **private** by
design.

## Layout

```
bootstrap/
  verifier/        setup-doctor — verifies the keyless-access setup (FND-2)
docs/
  runbooks/        one-time, human-run setup procedures
.github/workflows/
  verify-access.yml  Milestone 0 demo: keyless auth + setup-doctor
```

## Milestone 0 — Verified keyless access

The first slice: prove this repo's automation can reach the dev project with no
stored credentials, and verify the setup is correct and least-privilege.

1. Follow [`docs/runbooks/01-keyless-access-setup.md`](docs/runbooks/01-keyless-access-setup.md)
   to perform the one-time setup and publish the repository variables.
2. Run [`setup-doctor`](bootstrap/verifier/) locally for the full audit.
3. The **Verify keyless access** workflow demonstrates keyless auth in CI — a
   green run is the deliverable.
