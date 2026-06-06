#!/usr/bin/env bash
#
# Post-build, end-user validation for a freshly built dev-FOP cluster (WLD-2).
#
# Deploys each example over Connect Gateway and asserts the outcome a real user
# would observe — a client call returns HTTP 200 with the expected body, the
# encrypted volume mounts and persists across pods, an Artifact Registry pull
# is admitted, and a pod reads a Secret Manager secret via Workload Identity.
# Run by an operator at milestone bring-up; paste the summary into the issue.
#
# Prereqs: gcloud + kubectl + the gke-gcloud-auth-plugin; operator-level project
# permissions (it creates throwaway Secret Manager / service-account scaffolding
# for the Workload Identity case). Config is read from the fop Terraform outputs
# unless overridden by environment variables.
#
# Usage:
#   ./validate.sh            # deploy + assert, print a summary
#   ./validate.sh --cleanup  # tear everything down (namespace + WI scaffolding)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly TF_FOP="${REPO_ROOT}/terraform/envs/dev/fop"
readonly NS="examples"
readonly KSA="wi-demo"
readonly SECRET_NAME="${SECRET_NAME:-cluster-ctrl-example}"
readonly SECRET_VALUE="hello-from-secret-manager"
export USE_GKE_GCLOUD_AUTH_PLUGIN="True"

# --- helpers ---------------------------------------------------------------

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

tf_out() { terraform -chdir="${TF_FOP}" output -raw "$1" 2>/dev/null || true; }

RESULTS=()
record() { RESULTS+=("$1|$2|$3"); printf '  [%s] %s — %s\n' "$1" "$2" "$3"; }

# Substitute the manifest placeholders without needing gettext/envsubst.
render() {
  sed -e "s|\${REGISTRY_PROXY}|${REGISTRY_PROXY}|g" \
      -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${WI_GSA}|${WI_GSA}|g" \
      -e "s|\${SECRET_NAME}|${SECRET_NAME}|g" "$1"
}

resolve_config() {
  PROJECT_ID="${PROJECT_ID:-}"
  REGISTRY_PROXY="${REGISTRY_PROXY:-$(tf_out proxy_repository_url)}"
  CLUSTER="${CLUSTER:-$(tf_out cluster_name)}"
  [[ -n "${REGISTRY_PROXY}" ]] || die "could not resolve REGISTRY_PROXY (run 'terraform apply' in ${TF_FOP} or set it)"
  [[ -n "${CLUSTER}" ]] || die "could not resolve CLUSTER (cluster_name output)"
  # Derive project id from the registry path: <region>-docker.pkg.dev/<project>/<repo>
  [[ -n "${PROJECT_ID}" ]] || PROJECT_ID="$(printf '%s' "${REGISTRY_PROXY}" | cut -d/ -f2)"
  [[ -n "${PROJECT_ID}" ]] || die "could not resolve PROJECT_ID"
  WI_GSA="${KSA}@${PROJECT_ID}.iam.gserviceaccount.com"
  log "Config"
  printf '  project=%s cluster=%s\n  proxy=%s\n' "${PROJECT_ID}" "${CLUSTER}" "${REGISTRY_PROXY}"
}

connect() {
  log "Connecting to ${CLUSTER} over Connect Gateway"
  gcloud container fleet memberships get-credentials "${CLUSTER}" --project "${PROJECT_ID}"
  kubectl get nodes >/dev/null || die "cannot reach the cluster over Connect Gateway"
}

# --- Workload Identity scaffolding (throwaway) -----------------------------

setup_wi_prereqs() {
  log "Setting up Workload Identity scaffolding (service account + secret)"
  gcloud iam service-accounts describe "${WI_GSA}" --project "${PROJECT_ID}" >/dev/null 2>&1 ||
    gcloud iam service-accounts create "${KSA}" --project "${PROJECT_ID}" \
      --display-name "cluster-ctrl example (throwaway)"

  gcloud secrets describe "${SECRET_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1 ||
    gcloud secrets create "${SECRET_NAME}" --project "${PROJECT_ID}" --replication-policy=automatic
  # Ensure a current version with the known value exists.
  if ! gcloud secrets versions access latest --secret "${SECRET_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    printf '%s' "${SECRET_VALUE}" | gcloud secrets versions add "${SECRET_NAME}" --project "${PROJECT_ID}" --data-file=-
  fi

  # Least-privilege: the GSA may read only this one secret.
  gcloud secrets add-iam-policy-binding "${SECRET_NAME}" --project "${PROJECT_ID}" \
    --member "serviceAccount:${WI_GSA}" --role roles/secretmanager.secretAccessor >/dev/null
  # Bind the KSA to the GSA (Workload Identity).
  gcloud iam service-accounts add-iam-policy-binding "${WI_GSA}" --project "${PROJECT_ID}" \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NS}/${KSA}]" >/dev/null
}

# --- examples --------------------------------------------------------------

ensure_namespace() {
  kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"
}

check_hello_web() {
  log "01 — hello-web (HTTP 200 + body)"
  render "${SCRIPT_DIR}/01-hello-web/configmap.yaml" | kubectl apply -f -
  render "${SCRIPT_DIR}/01-hello-web/deployment.yaml" | kubectl apply -f -
  render "${SCRIPT_DIR}/01-hello-web/service.yaml" | kubectl apply -f -
  if ! kubectl -n "${NS}" rollout status deploy/hello-web --timeout=180s; then
    record FAIL hello-web "deployment did not become ready"; return
  fi
  local out
  # The curl runs INSIDE the curl-test pod, so $(...) and %{...} must NOT expand
  # in this shell — the single quotes are intentional.
  # shellcheck disable=SC2016
  out="$(kubectl -n "${NS}" run curl-test --rm -i --restart=Never --quiet \
    --image="${REGISTRY_PROXY}/curlimages/curl:8.10.1" --command -- \
    sh -c 'printf "HTTP:%s\n" "$(curl -s -o /tmp/b -w "%{http_code}" http://hello-web)"; cat /tmp/b' 2>/dev/null || true)"
  if grep -q "HTTP:200" <<<"${out}" && grep -q "Hello World" <<<"${out}"; then
    record PASS hello-web "client got HTTP 200 with body 'Hello World'"
  else
    record FAIL hello-web "unexpected response: $(tr '\n' ' ' <<<"${out}")"
  fi
}

check_encrypted_pvc() {
  log "02 — encrypted PVC (mount + persist)"
  render "${SCRIPT_DIR}/02-encrypted-pvc/pvc.yaml" | kubectl apply -f -
  render "${SCRIPT_DIR}/02-encrypted-pvc/pod.yaml" | kubectl apply -f -
  if ! kubectl -n "${NS}" wait --for=condition=Ready pod/pvc-writer --timeout=180s; then
    record FAIL encrypted-pvc "pod with the encrypted volume did not become ready"; return
  fi
  local marker
  marker="persist-$(kubectl -n "${NS}" get pod pvc-writer -o jsonpath='{.metadata.uid}')"
  kubectl -n "${NS}" exec pvc-writer -- sh -c "echo '${marker}' > /data/marker"
  # Recreate the pod and read the marker back — proves the volume persists.
  kubectl -n "${NS}" delete pod pvc-writer --wait=true >/dev/null
  render "${SCRIPT_DIR}/02-encrypted-pvc/pod.yaml" | kubectl apply -f -
  kubectl -n "${NS}" wait --for=condition=Ready pod/pvc-writer --timeout=180s >/dev/null
  local read_back
  read_back="$(kubectl -n "${NS}" exec pvc-writer -- cat /data/marker 2>/dev/null || true)"
  if [[ "${read_back}" == "${marker}" ]]; then
    record PASS encrypted-pvc "data persisted on the encrypted volume across pod recreation"
  else
    record FAIL encrypted-pvc "marker not persisted (got '${read_back}')"
  fi
}

check_artifact_registry() {
  log "03 — Artifact Registry pull (admitted by Binary Authorization audit)"
  render "${SCRIPT_DIR}/03-artifact-registry/job.yaml" | kubectl apply -f -
  if kubectl -n "${NS}" wait --for=condition=complete job/registry-pull --timeout=180s 2>/dev/null; then
    record PASS artifact-registry "image pulled through the proxy and ran to completion"
  else
    record FAIL artifact-registry "job did not complete (pull blocked or image error)"
  fi
}

check_workload_identity() {
  log "04 — Workload Identity reads a Secret Manager secret"
  render "${SCRIPT_DIR}/04-workload-identity/serviceaccount.yaml" | kubectl apply -f -
  render "${SCRIPT_DIR}/04-workload-identity/pod.yaml" | kubectl apply -f -
  if ! kubectl -n "${NS}" wait --for=condition=Ready pod/wi-secret-reader --timeout=180s; then
    record FAIL workload-identity "pod did not become ready"; return
  fi
  # The pod prints the secret on startup; give it a moment, then read the logs.
  sleep 5
  local logs
  logs="$(kubectl -n "${NS}" logs wi-secret-reader 2>/dev/null || true)"
  if grep -q "${SECRET_VALUE}" <<<"${logs}"; then
    record PASS workload-identity "pod read the secret via its own Google identity"
  else
    record FAIL workload-identity "secret value not found in pod logs"
  fi
}

# --- teardown --------------------------------------------------------------

cleanup() {
  resolve_config
  connect
  log "Tearing down"
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
  gcloud iam service-accounts delete "${WI_GSA}" --project "${PROJECT_ID}" --quiet 2>/dev/null || true
  gcloud secrets delete "${SECRET_NAME}" --project "${PROJECT_ID}" --quiet 2>/dev/null || true
  log "Done"
}

summary() {
  log "Summary"
  local failed=0
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"${r}"
    printf '  %-5s %-20s %s\n' "${status}" "${name}" "${detail}"
    [[ "${status}" == "FAIL" ]] && failed=1
  done
  if [[ "${failed}" -eq 0 ]]; then
    log "All examples passed — the cluster is ready for workloads (WLD-2)."
  else
    die "one or more examples failed"
  fi
}

main() {
  if [[ "${1:-}" == "--cleanup" ]]; then cleanup; exit 0; fi
  resolve_config
  connect
  ensure_namespace
  setup_wi_prereqs
  check_hello_web
  check_encrypted_pvc
  check_artifact_registry
  check_workload_identity
  summary
}

main "$@"
