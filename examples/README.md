# Examples — end-user validation and reference workloads

Runnable workload test cases that prove a freshly built dev-FOP cluster is
genuinely ready for workloads (requirement **WLD-2**), from an end user's point
of view. They double as **compliant reference deployments**: every workload runs
non-root, with a read-only root filesystem, all Linux capabilities dropped, the
`RuntimeDefault` seccomp profile, and resource requests/limits — copy them as a
starting point.

| # | Example | Proves | End-to-end assertion |
|---|---|---|---|
| 01 | `hello-web` | A non-root web service serves traffic | A client call returns **HTTP 200** with body **"Hello World"** (2 replicas, zone-spread, PDB, priority tier) |
| 02 | `encrypted-pvc` | The CMEK-encrypted StorageClass works | A volume mounts and **data persists** across pod recreation |
| 03 | `artifact-registry` | Images pull from Artifact Registry | A pull through the proxy is **admitted** (Binary Authorization audit) and runs |
| 04 | `workload-identity` | Pods get their own Google identity | A pod **reads a Secret Manager secret** with no keys (Workload Identity) |
| 05 | `external-ingress` | The public gateway serves every hostname | **HTTPS 200** + "Hello World" on **each** external host with its **own** publicly-trusted cert (SNI, ADR-0005) |
| 06 | `internal-ingress` | The internal gateway + private DNS | An in-VPC client resolves **each** internal host **by name** (private zone, ADR-0006) and gets **HTTPS 200** with the multi-SAN **CAS** cert verified to the root |
| 07 | *(drain survival)* | Spread + PDB, over the **internal** gateway | A node hosting a replica **drains with zero failed requests** (measured through the internal gateway, independent of public DNS) |
| 08 | *(rolling deploy)* | Readiness-gated rollouts, over the **internal** gateway | A rolling restart completes with **zero failed requests** through the internal gateway |
| 09 | `regional-pvc` | The regional StorageClass survives a zone | The pod's zone drains; it **reschedules into the other zone with its data** (ADR-0008) |
| 10 | `autoscale` | The cluster autoscaler (ADR-0007) | Scaling to 6×500m makes pods pending; **a node is added** and all replicas run (scale-in is slow by design) |
| 11 | `hpa` | Metric-driven pod scaling | Load drives the Horizontal Pod Autoscaler **past 1 replica** (CPU target 30%) |
| 12 | `preemption` | The platform priority tiers | With the cluster saturated at the default tier, a **workload-high pod still schedules** (preemption) |
| 13 | *(backup→restore)* | Backup for GKE (ADR-0004; runs **last**) | The namespace is **deleted and restored** from an on-demand backup, volume data intact |
| 14 | `multi-subdomain` | One gateway fans several subdomains out to services by URL path | **HTTPS 200** on all **6** host+path combinations (3 subdomains × `/h1`→helloworld1, `/h2`→helloworld2), each response **naming its service and subdomain**, per-host certs (runs right after 05 — same public-edge warm-up) |

## Run

The cluster has no public endpoint, so access is over Connect Gateway. The
script reads its configuration from the `fop` Terraform outputs (override with
`PROJECT_ID` / `REGISTRY_PROXY` / `CLUSTER` env vars if needed).

```bash
# Prereqs: gcloud, kubectl, the gke-gcloud-auth-plugin, and operator-level
# project permissions (example 04 creates throwaway Secret Manager / service-
# account scaffolding).
examples/validate.sh           # deploy, assert, auto-clean on success
examples/validate.sh --keep    # as above, but leave state for inspection
examples/validate.sh --cleanup # standalone teardown (namespace + WI scaffolding)

# Any single case, standalone (names are the summary-table names, e.g.
# hello-web, external-ingress, multi-subdomain, backup-restore):
examples/validate.sh --only multi-subdomain            # run one case, auto-clean
examples/validate.sh --only multi-subdomain --keep     # run one case, keep state
examples/validate.sh --cleanup --only multi-subdomain  # tear down one case
```

On a **FAIL**, state is left behind on purpose so you can inspect with
`kubectl -n examples get pods,svc,pvc`. Run `--cleanup` afterward.

Images are pulled through the Artifact Registry Docker Hub proxy
(`${REGISTRY_PROXY}/...`), so the examples exercise the supply chain on every
pull. The `encrypted-rwo` StorageClass that example 02 uses is a platform
default the pipeline applies after a build (rendered by the cluster stack from
the cluster's CMEK key).

**Ingress + HA cases (05–14)** read their config from the fop outputs
(`external_hostnames`, `internal_hostnames`, gateway IPs, `backup_plan_name`,
`restore_plan_name`); override via the same-named environment variables. Only
the **external** cases (05, 14) depend on the public edge: they use
`curl --resolve` to the gateway IP (so public **DNS propagation** isn't on the
critical path) but need the **managed certs ACTIVE** (NS delegation or per-host
CNAMEs in place). The external hostname list splits by convention: the `sdN.*` entries belong
to case 14 and any remaining entries to case 05 — which SKIPs when there are
none, as on the current dev-fop config (override the case-14 set with
`MULTI_SUBDOMAIN_HOSTNAMES`; see
[11-multi-subdomain/README.md](11-multi-subdomain/README.md) for the full
configuration walk-through and diagrams). The **internal** case (06) and the **drain/rolling** cases
(07/08) run from an in-cluster pod, resolving hostnames **by name through the
private zone** — no IP overrides — and trusting the CAS root via the `cas-root`
ConfigMap; so they validate node drains and rolling deploys over the **internal**
gateway even when public ingress isn't set up. The drain/zone-failover cases
**cordon and drain nodes** (uncordoned afterward, including by `--cleanup` after a
failed run), and the drain probe is pinned **off** the drained node so it
survives; the backup→restore case runs **last** because the restore bounces the
workload namespaces.

## Recording results

Paste the script's summary block into the milestone's verification issue as the
post-build validation evidence (Milestone 1 → #11; later milestones use their own
retrospective/verification issue). The runtime acceptance criteria are checked off
only after this script passes against the real cluster.
