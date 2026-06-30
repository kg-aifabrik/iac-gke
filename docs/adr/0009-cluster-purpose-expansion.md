# ADR-0009: Cluster purposes expand via a config registry and a generator, not hand-copied roots

- **Status:** Accepted
- **Date:** 2026-06-30
- **Deciders:** SRE
- **References:** [google-cloud-design.md §2–3, §10](../designs/google-cloud-design.md);
  [cluster-purpose-expansion.md (TDR)](../designs/cluster-purpose-expansion.md);
  [milestone-1-cluster-factory.md](../plans/milestone-1-cluster-factory.md); ADR-0006, ADR-0007

## Context

The factory already builds one cluster per `(environment, purpose)`. The
`cluster-stack` module is fully keyed on `environment` + `purpose` (it derives
`cluster_name = "<env>-<purpose>"`, a per-cluster VPC, and labels), and each
cluster is a **thin per-`(env,purpose)` Terraform root** that reads the
per-project foundation's remote state. The design already anticipates growth —
the `fop` root's header says *"adding a purpose is a sibling folder = config, not
new code."*

But today "add a purpose" means hand-copying a ~40-line root folder **and**
hand-editing three GitHub Actions workflows whose root lists are static YAML (a
`choice` input in apply/destroy, a `matrix` in plan). The pipeline is also pinned
to `env=dev`. We need a repeatable, low-error way to add a purpose — and to
deliver `dev-mgmt` as the first one — without widening blast radius or letting the
per-combo roots drift.

## Decision drivers

- Adding a purpose should be **config + one command**, not bespoke folder edits.
- One cluster = **one Terraform state**, isolated — a new purpose must not be able
  to touch another's state.
- Keep the existing thin-root design and the per-project foundation; **no module
  redesign**.
- Per-`(env,purpose)` shape/sizing must be reviewable **as data** and diffable in
  pull requests.
- `env` stays a **fixed set** `{dev, stage, prod}`; `purpose` is the open axis.
- GitHub Actions cannot choose workflow inputs dynamically at dispatch, so the
  input enumerations must be **materialized** somehow.

## Considered options

1. **Single parameterized root + per-`(env,purpose)` `-var-file`.** Rejected:
   collapses the one-folder/one-state model, needs the backend prefix/workspace
   driven by inputs (more pipeline logic and a sharper foot-gun), and is a larger
   refactor of working roots right now.
2. **Hand-copied sibling folders (status quo).** Rejected: error-prone, drifts,
   and still needs manual workflow edits each time — exactly the toil we are
   removing.
3. **A config registry as the single source of truth + a generator that renders
   per-`(env,purpose)` roots from a template and regenerates the workflow
   enumerations; roots are generated-but-committed.** Chosen.

## Decision

- A single registry **`config/clusters.yaml`** holds the data: cross-cutting
  defaults, per-environment settings (the three fixed envs), and per-purpose
  shape/sizing. The effective config for a cluster is the merge
  **defaults → env → purpose → combo-override**.
- A **Python generator** (`tools/cluster-factory/`) renders
  `terraform/envs/<env>/<purpose>/` from a template, sets the backend prefix
  `env/<env>/<purpose>`, and rewrites the root enumerations in the three workflows
  between sentinel markers. Python — not bash + `yq` — because the registry is
  YAML, the merge logic is non-trivial, and it is unit-testable alongside the
  existing pytest verifier.
- **Generated roots are committed** (like lockfiles) and **normalized** (uniform
  across purposes). An **idempotency check** (regenerate → empty `git diff`)
  guards against drift. Migrating an existing cluster regenerates its source into
  the normalized form; the proof that **no infrastructure changes** is a
  `terraform plan` **no-op** (the module inputs are unchanged), verified in CI —
  not byte-identical source. (Byte-identical was the first intent but was dropped:
  `fop`'s hand-written root carried bespoke, partly-stale prose that can't be
  reproduced faithfully across purposes; normalizing is cleaner and the plan-no-op
  is the meaningful guarantee.)
- **Pipeline inputs** become `env` (choice, fixed `dev/stage/prod`) + `purpose`
  (choice = `foundation` + the registry's purposes); `TF_ROOT =
  terraform/envs/<env>/<purpose>`. `foundation` stays a selectable special root.
- An operator wrapper **`bootstrap/add-cluster-purpose.sh`** runs the generator
  idempotently — the "prime the automation" step.
- **Scope: purpose-expansion only.** `env`-expansion (stage/prod projects, their
  GitHub Environments, bootstraps, and prod guardrails) is deliberately out of
  scope here and tracked separately.

## Consequences

- **Good:** adding a purpose is edit-config-then-prime; state stays isolated per
  combo; a PR shows both the data change and the generated root; no module
  changes; `dev-fop`'s module inputs are unchanged, so its migration is a
  `terraform plan` no-op.
- **Bad:** migrating `fop` rewrites its hand-tuned source into the normalized
  form (prose becomes uniform); the plan no-op proves no infra change, but the
  source diff is large at migration time.
- **Good:** the registry is the single source of truth that the docs and the
  pipeline both derive from.
- **Bad:** generated-but-committed roots can drift if someone hand-edits them —
  mitigated by the idempotency check in CI.
- **Bad:** the generator must rewrite workflow YAML between sentinel markers — a
  small bespoke step, forced by GitHub Actions `choice` inputs not being dynamic.
- **Limitation:** `env`-expansion stays manual and unsolved here; the registry
  models all three envs but only `dev` is wired end-to-end.
