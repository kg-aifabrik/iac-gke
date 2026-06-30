# TDR: Cluster purpose-expansion — registry + generator

- **Status:** Accepted
- **Date:** 2026-06-30
- **Related:** [ADR-0009](../adr/0009-cluster-purpose-expansion.md);
  [google-cloud-design.md](google-cloud-design.md) (the living design)

## Goal and scope

Make adding a cluster **purpose** a config-plus-command operation, and use it to
deliver the **`dev-mgmt`** cluster (same shape as `dev-fop`: external + internal
gateways, public DNS, backup). In scope: the registry, the generator, the
rewired pipeline, the prime script, and the `dev-mgmt` build. **Out of scope:**
`env`-expansion to stage/prod (separate, infra-heavy effort).

The `cluster-stack` module is unchanged — it already takes `environment` +
`purpose` and the full shape/sizing surface. This work only changes how the thin
roots and the pipeline enumerations are **produced**.

## Design overview

```
config/clusters.yaml ──► tools/cluster-factory (Python) ──► terraform/envs/<env>/<purpose>/   (generated, committed)
   (single source        │  load + validate                └► sentinel-marked regions in
    of truth)            │  merge defaults→env→purpose→combo    .github/workflows/terraform-{apply,plan,destroy}.yml
                         └► render template
bootstrap/add-cluster-purpose.sh  ── wraps the generator (idempotent, --dry-run) = "prime the automation"
```

The generator is the one place that turns registry data into both the Terraform
roots and the workflow input lists, so the two never disagree.

## Registry schema (`config/clusters.yaml`)

Three layers plus the list of active clusters; the effective config is the
ordered merge **defaults → environments[env] → purposes[purpose] →
clusters[].overrides**.

```yaml
defaults:                     # cross-cutting; rarely changed
  region: us-central1
  enable_backup: true

environments:                 # the THREE fixed envs; env-level posture
  dev:
    cas_tier: DEVOPS          # ENTERPRISE for stage/prod
    deletion_protection: false
    release_channel: REGULAR
    manage_public_dns: true
    enable_cloud_nat: true
    maintenance_recurring_window:
      start_time: "2026-01-03T09:00:00Z"
      end_time:   "2026-01-03T17:00:00Z"
      recurrence: "FREQ=WEEKLY;BYDAY=SA,SU"
  stage: { ... }              # modeled but not wired end-to-end yet
  prod:  { ... }

purposes:                     # the OPEN axis; per-purpose shape/sizing
  fop:
    general_machine_type: e2-medium
    general_autoscaling: { min_per_zone: 1, max_per_zone: 2 }
  mgmt:
    general_machine_type: e2-medium
    general_autoscaling: { min_per_zone: 1, max_per_zone: 2 }

clusters:                     # which (env,purpose) combos are active
  - { env: dev, purpose: fop,  external_hostnames: [app.dev.arthos.app, hello.dev.arthos.app],
      internal_hostnames: [hello.dev.aifabrik.com, tools.dev.aifabrik.com],
      internal_zone_domain: dev.aifabrik.com, public_zone_domain: dev.arthos.app }
  - { env: dev, purpose: mgmt, external_hostnames: [app.mgmt.dev.arthos.app],
      internal_hostnames: [tools.mgmt.dev.aifabrik.com],
      internal_zone_domain: mgmt.dev.aifabrik.com, public_zone_domain: mgmt.dev.arthos.app }
```

Every `cluster-stack` shape input is expressible through these layers. Per-cluster
hostnames and DNS domains live on the `clusters[]` entry (they are inherently
per-`(env,purpose)`). The `dev-fop` entry is chosen to reproduce today's pinned
module **inputs** exactly, so regenerating it is a `terraform plan` no-op (the
generated source is normalized, not byte-identical to the hand-written root).

Validation rules the loader enforces: `env ∈ {dev,stage,prod}`; `purpose` exists
in `purposes`; no duplicate `(env,purpose)`; required shape fields resolved after
merge.

## Data flow and interfaces

**Generator CLI** (`python -m cluster_factory` or `tools/cluster-factory/generate.py`):

- `generate` — render every active cluster's root + rewrite the workflow regions.
- `--check` — render to a temp dir and fail if it differs from the committed tree
  (the CI drift guard).
- `--dry-run` — print what would change, write nothing.

**Rendered root** (per combo, mirrors today's `fop` layout): `backend.tf`
(`prefix = env/<env>/<purpose>`), `main.tf` (reads foundation remote state, calls
`cluster-stack` with the merged values), `variables.tf`, `providers.tf`,
`outputs.tf`, `versions.tf`, `terraform.tfvars.example`. A `# GENERATED — edit
config/clusters.yaml` header marks each file.

**Workflow regions** — each of `terraform-{apply,plan,destroy}.yml` gets sentinel
markers (`# >>> cluster-factory:purposes` … `# <<<`) around the `purpose` choice
list / plan `matrix`. The generator rewrites only between markers. Inputs become
`env` (fixed choice) + `purpose` (`foundation` + registry purposes);
`TF_ROOT = terraform/envs/${env}/${purpose}`; concurrency keyed on
`${env}-${purpose}`.

**Prime script** (`bootstrap/add-cluster-purpose.sh`): thin bash wrapper matching
the other bootstrap scripts (`info/ok/warn/die`, `--dry-run`, `--help`); runs the
generator and prints next steps (PR the diff, then dispatch the build).

## Testing strategy

- **No-op migration:** regenerating `dev-fop` keeps the cluster-stack module
  inputs unchanged, so `terraform plan` shows no changes (verified in CI, since
  `plan` needs cloud state).
- **Validity:** generated roots pass `terraform fmt -check` + `validate`.
- **Idempotency:** `generate` run twice → empty diff; `--check` passes on a clean
  tree and fails on a hand-edited root.
- **Schema:** malformed registry (bad env, missing field, duplicate combo) →
  loader error with a clear message.
- **Workflow:** after `generate`, the three workflows parse as valid YAML and
  their `purpose` lists equal `[foundation] + purposes`.
- **Live (M2):** `setup-doctor` cluster-mode green for `dev-mgmt`;
  `examples/validate.sh` green against mgmt hostnames; teardown leaves only
  foundation singletons; `fop` untouched throughout.

## Alternatives considered

See [ADR-0009](../adr/0009-cluster-purpose-expansion.md): single parameterized
root + `-var-file` (rejected — loses one-folder/one-state, bigger refactor);
hand-copied folders (rejected — toil, drift); bash + `yq` generator (rejected —
YAML + non-trivial merge + testability favour Python).

## Risks and open questions

- **Generated-root drift** if someone hand-edits a root — mitigated by `--check`
  in CI on every PR.
- **Workflow-YAML rewriting** is bespoke (sentinel markers); keep the rewritten
  region minimal and assert YAML validity in tests.
- **`dev-mgmt` public DNS:** as an external, customer-facing cluster it needs its
  own delegated public subdomain (same one-time registrar NS delegation as `fop`,
  per ADR-0006) — an M2 build step, not a code step.
- **`env`-expansion** (stage/prod) remains manual: per-env projects, GitHub
  Environments + approval gates, per-env variables and state, prod guardrails
  (`deletion_protection=true`, held release channel). The registry models the
  envs; wiring them is future work.

## Related ADRs

[ADR-0009](../adr/0009-cluster-purpose-expansion.md) (this model);
ADR-0006 (DNS), ADR-0007 (autoscaling) for the shape knobs the registry sets.
