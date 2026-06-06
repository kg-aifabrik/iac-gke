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

1. Run [`bootstrap/setup-keyless-access.sh`](bootstrap/setup-keyless-access.sh) — it
   prompts for inputs, performs the one-time setup idempotently, publishes the
   repository variables, and runs [`setup-doctor`](bootstrap/verifier/) to verify.
   (See [`docs/runbooks/01-keyless-access-setup.md`](docs/runbooks/01-keyless-access-setup.md)
   for the manual steps and the rationale.)
2. The **Verify keyless access** workflow then demonstrates keyless auth in CI —
   a green run is the deliverable.
