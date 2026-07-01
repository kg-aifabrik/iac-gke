# cluster-factory

Generates the per-`(env,purpose)` Terraform roots and the pipeline's `env`/`purpose`
input lists from the cluster registry [`config/clusters.yaml`](../../config/clusters.yaml),
so adding a cluster **purpose** is a config edit plus one command — not hand-copied
folders. See [ADR-0009](../../docs/adr/0009-cluster-purpose-expansion.md) and the
[TDR](../../docs/designs/cluster-purpose-expansion.md).

## Layout

```
src/cluster_factory/
  registry.py   load + validate + merge the registry
  render.py     registry -> Terraform roots
  workflows.py  registry -> workflow input enumerations
  doctor.py     registry -> SETUP_DOCTOR_* env for the verify step
  cli.py        the `cluster-factory` command (generate, doctor-env)
tests/          behavioural tests, one per rule it proves
```

## Develop / test

```bash
cd tools/cluster-factory
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.lock && pip install -e .
pip install pytest && pytest -q
```

The registry is the single source of truth; the generated roots are committed
(like lockfiles) and an idempotency check guards them against drift.
