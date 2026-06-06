# Examples — end-user validation and reference workloads

Runnable workload test cases that prove a freshly built dev-FOP cluster is
genuinely ready for workloads (requirement **WLD-2**), from an end user's point
of view. They double as **compliant reference deployments**: every workload runs
non-root, with a read-only root filesystem, all Linux capabilities dropped, the
`RuntimeDefault` seccomp profile, and resource requests/limits — copy them as a
starting point.

| # | Example | Proves | End-to-end assertion |
|---|---|---|---|
| 01 | `hello-web` | A non-root web service serves traffic | A client call returns **HTTP 200** with body **"Hello World"** |
| 02 | `encrypted-pvc` | The CMEK-encrypted StorageClass works | A volume mounts and **data persists** across pod recreation |
| 03 | `artifact-registry` | Images pull from Artifact Registry | A pull through the proxy is **admitted** (Binary Authorization audit) and runs |
| 04 | `workload-identity` | Pods get their own Google identity | A pod **reads a Secret Manager secret** with no keys (Workload Identity) |

## Run

The cluster has no public endpoint, so access is over Connect Gateway. The
script reads its configuration from the `fop` Terraform outputs (override with
`PROJECT_ID` / `REGISTRY_PROXY` / `CLUSTER` env vars if needed).

```bash
# Prereqs: gcloud, kubectl, the gke-gcloud-auth-plugin, and operator-level
# project permissions (example 04 creates throwaway Secret Manager / service-
# account scaffolding).
examples/validate.sh           # deploy all four, assert, print a summary
examples/validate.sh --cleanup # tear down the namespace + the WI scaffolding
```

Images are pulled through the Artifact Registry Docker Hub proxy
(`${REGISTRY_PROXY}/...`), so the examples exercise the supply chain on every
pull. The `encrypted-rwo` StorageClass that example 02 uses is a platform
default the pipeline applies after a build (rendered by the cluster stack from
the cluster's CMEK key).

## Recording results

Paste the script's summary block into the Milestone 1 issue (#11) as the
post-build validation evidence. The runtime acceptance criteria are checked off
only after this script passes against the real cluster.
