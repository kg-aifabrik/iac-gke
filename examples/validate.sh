#!/usr/bin/env bash
#
# Post-build, end-user validation for a freshly built dev-FOP cluster (WLD-2).
#
# Deploys each example over Connect Gateway and asserts the outcome a real user
# would observe — serving over both gateways (every hostname, internal ones by
# NAME through the private zone), persistence, supply chain, Workload Identity,
# and the high-availability behaviors: a node drain and a rolling deploy with
# zero failed requests, node autoscaling, HPA, regional-disk zone failover,
# backup→restore, and priority preemption (Milestone 3, issue #34).
# Run by an operator at milestone bring-up; paste the summary into the issue.
#
# Prereqs: gcloud + kubectl + the gke-gcloud-auth-plugin; operator-level project
# permissions (it creates throwaway Secret Manager / service-account scaffolding
# for the Workload Identity case). Config is read from the fop Terraform outputs
# unless overridden by environment variables.
#
# Usage:
#   ./validate.sh            # deploy + assert + (on success) auto-clean
#   ./validate.sh --keep     # as above, but leave resources behind for inspection
#   ./validate.sh --cleanup  # only tear down (namespace + WI scaffolding)
#
# Note: when an assertion FAILS the script intentionally LEAVES state behind so
# you can poke at it (`kubectl -n examples ...`). Run `./validate.sh --cleanup`
# afterward to remove it.
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

# Retry a command with backoff — IAM operations on freshly-created identities
# can 400/404 until the new principal is visible at the granting endpoint.
retry() {
  local tries=8 delay=5 attempt=1
  until "$@"; do
    if (( attempt >= tries )); then return 1; fi
    printf '  (retry %d/%d in %ds: %s)\n' "${attempt}" "${tries}" "${delay}" "$*" >&2
    sleep "${delay}"; attempt=$((attempt + 1))
  done
}

# Substitute the manifest placeholders without needing gettext/envsubst.
render() {
  sed -e "s|\${REGISTRY_PROXY}|${REGISTRY_PROXY}|g" \
      -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${WI_GSA}|${WI_GSA}|g" \
      -e "s|\${SECRET_NAME}|${SECRET_NAME}|g" \
      -e "s|\${EXTERNAL_HOST_1}|${EXTERNAL_HOSTS[0]:-}|g" \
      -e "s|\${EXTERNAL_HOST_2}|${EXTERNAL_HOSTS[1]:-${EXTERNAL_HOSTS[0]:-}}|g" \
      -e "s|\${INTERNAL_HOST_1}|${INTERNAL_HOSTS[0]:-}|g" \
      -e "s|\${INTERNAL_HOST_2}|${INTERNAL_HOSTS[1]:-${INTERNAL_HOSTS[0]:-}}|g" "$1"
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
  # Hostname lists come comma-joined from the fop outputs (multi-host, ADR-0005).
  IFS=',' read -r -a EXTERNAL_HOSTS <<<"${EXTERNAL_HOSTNAMES:-$(tf_out external_hostnames)}"
  IFS=',' read -r -a INTERNAL_HOSTS <<<"${INTERNAL_HOSTNAMES:-$(tf_out internal_hostnames)}"
  EXTERNAL_IP="${EXTERNAL_IP:-$(tf_out external_gateway_ip)}"
  INTERNAL_IP="${INTERNAL_IP:-$(tf_out internal_gateway_ip)}"
  BACKUP_PLAN="${BACKUP_PLAN:-$(tf_out backup_plan_name)}"
  RESTORE_PLAN="${RESTORE_PLAN:-$(tf_out restore_plan_name)}"
  LOCATION="${LOCATION:-$(tf_out location)}"
  log "Config"
  printf '  project=%s cluster=%s\n  proxy=%s\n  external=%s (%s)\n  internal=%s (%s)\n  backup-plan=%s restore-plan=%s\n' \
    "${PROJECT_ID}" "${CLUSTER}" "${REGISTRY_PROXY}" \
    "${EXTERNAL_HOSTS[*]:-?}" "${EXTERNAL_IP:-?}" "${INTERNAL_HOSTS[*]:-?}" "${INTERNAL_IP:-?}" \
    "${BACKUP_PLAN:-?}" "${RESTORE_PLAN:-?}"
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

  # Least-privilege: the GSA may read only this one secret. Retry — a brand-new
  # SA isn't always visible at the secret-IAM endpoint immediately.
  retry gcloud secrets add-iam-policy-binding "${SECRET_NAME}" --project "${PROJECT_ID}" \
    --member "serviceAccount:${WI_GSA}" --role roles/secretmanager.secretAccessor >/dev/null
  # Bind the KSA to the GSA (Workload Identity). Same propagation lag possible.
  retry gcloud iam service-accounts add-iam-policy-binding "${WI_GSA}" --project "${PROJECT_ID}" \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NS}/${KSA}]" >/dev/null
}

# --- examples --------------------------------------------------------------

ensure_namespace() {
  # A prior --cleanup deletes the namespace asynchronously; if it's still
  # Terminating, wait for it to clear before recreating (otherwise applies fail
  # with "namespace is being terminated").
  local phase
  phase="$(kubectl get namespace "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Terminating" ]]; then
    log "namespace ${NS} is terminating; waiting for it to clear"
    kubectl wait --for=delete "namespace/${NS}" --timeout=180s 2>/dev/null || true
  fi
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
  # The pod retries the read while the WI binding propagates; poll its logs for
  # the secret value until it appears (~5 min).
  local logs=""
  for _ in $(seq 1 30); do
    logs="$(kubectl -n "${NS}" logs wi-secret-reader 2>/dev/null || true)"
    grep -q "${SECRET_VALUE}" <<<"${logs}" && break
    sleep 10
  done
  if grep -q "${SECRET_VALUE}" <<<"${logs}"; then
    record PASS workload-identity "pod read the secret via its own Google identity"
  else
    record FAIL workload-identity "secret value not found in pod logs"
  fi
}

check_external_ingress() {
  log "05 — external ingress (HTTPS 200 over the public gateway)"
  if [[ -z "${EXTERNAL_IP}" ]]; then
    record SKIP external-ingress "EXTERNAL_IP not set (terraform output external_gateway_ip)"
    return
  fi
  render "${SCRIPT_DIR}/05-external-ingress/ingress.yaml" | kubectl apply -f -
  if ! kubectl -n public-services rollout status deploy/hello-web --timeout=180s >/dev/null; then
    record FAIL external-ingress "deployment did not become ready"
    return
  fi
  # --resolve hits the gateway IP directly; each host's own cert still
  # validates by SNI (no -k), so this also proves per-host certificates
  # (ADR-0005). The global load balancer takes minutes to program its HTTPS
  # frontend after the certs go ACTIVE, so retry until every host serves.
  log "  waiting for the external load balancer to program (up to ~6 min)..."
  local host code="" failed="" attempt
  for host in "${EXTERNAL_HOSTS[@]}"; do
    code=""
    for attempt in $(seq 1 18); do
      code="$(curl -sS --max-time 15 --resolve "${host}:443:${EXTERNAL_IP}" \
        -o /tmp/ext_body -w '%{http_code}' "https://${host}/" 2>/tmp/ext_err || true)"
      [[ "${code}" == "200" ]] && break
      sleep 20
    done
    if [[ "${code}" != "200" ]] || ! grep -q "Hello World" /tmp/ext_body 2>/dev/null; then
      failed+="${host}=HTTP'${code}' "
    fi
  done
  if [[ -z "${failed}" ]]; then
    record PASS external-ingress "HTTPS 200 + 'Hello World' with per-host publicly-trusted certs at: ${EXTERNAL_HOSTS[*]}"
  else
    record FAIL external-ingress "${failed}($(tr -d '\n' </tmp/ext_err 2>/dev/null | tail -c 80)); LB programmed? certs ACTIVE?"
  fi
}

check_internal_ingress() {
  log "06 — internal ingress (HTTPS 200 over the internal gateway, CAS cert)"
  if [[ -z "${INTERNAL_IP}" ]]; then
    record SKIP internal-ingress "INTERNAL_IP not set (terraform output internal_gateway_ip)"
    return
  fi
  render "${SCRIPT_DIR}/06-internal-ingress/ingress.yaml" | kubectl apply -f -
  if ! kubectl -n internal-tools rollout status deploy/hello-web --timeout=180s >/dev/null; then
    record FAIL internal-ingress "deployment did not become ready"
    return
  fi
  # The internal VIP is private, so curl from an in-cluster pod, trusting the
  # CAS root that trust-manager distributed (the cas-root ConfigMap). The pod
  # resolves each hostname BY NAME — through the Cloud DNS private zone, the
  # path a real internal client takes (no --resolve, ADR-0006) — and verifies
  # the multi-SAN CAS cert against the root for every host. The internal ALB
  # takes a few minutes to program, so re-run the probe pod until it answers.
  log "  waiting for the internal load balancer to program (up to ~7 min)..."
  local hosts_script="" host logs="" attempt phase
  for host in "${INTERNAL_HOSTS[@]}"; do
    hosts_script+="curl -sS --max-time 15 --cacert /trust/ca.crt -o /tmp/b -w \"${host}:HTTP:%{http_code}\\n\" https://${host}/ && cat /tmp/b; "
  done
  for attempt in $(seq 1 10); do
    kubectl -n internal-tools delete pod ingress-test --ignore-not-found >/dev/null 2>&1 || true
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ingress-test, namespace: internal-tools }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 100, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: curl
      image: ${REGISTRY_PROXY}/curlimages/curl:8.10.1
      command: ["sh", "-c", "${hosts_script}"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts:
        - { name: trust, mountPath: /trust, readOnly: true }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: trust
      configMap: { name: cas-root }
    - name: tmp
      emptyDir: {}
EOF
    phase=""
    for _ in 1 2 3 4 5 6; do
      phase="$(kubectl -n internal-tools get pod ingress-test -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
      sleep 5
    done
    logs="$(kubectl -n internal-tools logs ingress-test 2>/dev/null || true)"
    [[ "$(grep -c ":HTTP:200" <<<"${logs}")" -eq "${#INTERNAL_HOSTS[@]}" ]] && break
    sleep 15
  done
  if [[ "$(grep -c ":HTTP:200" <<<"${logs}")" -eq "${#INTERNAL_HOSTS[@]}" ]] && grep -q "Hello World" <<<"${logs}"; then
    record PASS internal-ingress "HTTPS 200 by NAME via the private zone, CAS cert verified, for: ${INTERNAL_HOSTS[*]}"
  else
    record FAIL internal-ingress "unexpected response: $(tr '\n' ' ' <<<"${logs}" | tail -c 140)"
  fi
}


# --- high-availability checks (Milestone 3, issue #34) ----------------------

# Continuous probe against the first external hostname (1 req/s) — the
# drain/rolling checks assert ZERO non-200s while disruption is in progress.
PROBE_FILE=""
PROBE_PID=""
start_probe() {
  PROBE_FILE="$(mktemp)"
  (
    while :; do
      curl -sS --max-time 5 --resolve "${EXTERNAL_HOSTS[0]}:443:${EXTERNAL_IP}" \
        -o /dev/null -w '%{http_code}\n' "https://${EXTERNAL_HOSTS[0]}/" 2>/dev/null || echo 000
      sleep 1
    done >>"${PROBE_FILE}"
  ) &
  PROBE_PID=$!
}

# Stops the probe and reports "<total> <failures>".
stop_probe() {
  kill "${PROBE_PID}" 2>/dev/null || true
  wait "${PROBE_PID}" 2>/dev/null || true
  local total failures
  total="$(wc -l <"${PROBE_FILE}" | tr -d ' ')"
  failures="$(grep -cv '^200$' "${PROBE_FILE}" || true)"
  rm -f "${PROBE_FILE}"
  echo "${total} ${failures}"
}

DRAINED_NODE=""
check_drain_survival() {
  log "07 — drain survival (zero failed requests while a node drains)"
  if [[ -z "${EXTERNAL_IP}" ]]; then
    record SKIP drain-survival "needs the external gateway serving (run after 05)"; return
  fi
  # Drain the node hosting one hello-web replica; spread + PDB + the gateway's
  # health checks must keep the OTHER replica serving throughout.
  local node
  node="$(kubectl -n public-services get pod -l app=hello-web \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
  if [[ -z "${node}" ]]; then
    record FAIL drain-survival "no hello-web pod found in public-services"; return
  fi
  start_probe
  DRAINED_NODE="${node}"
  if ! kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data \
      --timeout=240s >/dev/null 2>&1; then
    read -r _ _ < <(stop_probe)
    kubectl uncordon "${node}" >/dev/null 2>&1 || true; DRAINED_NODE=""
    record FAIL drain-survival "drain of ${node} did not complete (PDB blocked too long?)"
    return
  fi
  kubectl -n public-services rollout status deploy/hello-web --timeout=180s >/dev/null 2>&1 || true
  sleep 5
  local total failures
  read -r total failures < <(stop_probe)
  kubectl uncordon "${node}" >/dev/null 2>&1 || true
  DRAINED_NODE=""
  if (( total > 0 && failures == 0 )); then
    record PASS drain-survival "node ${node} drained; ${total} requests, 0 failures"
  else
    record FAIL drain-survival "${failures}/${total} requests failed during the drain"
  fi
}

check_rolling_deploy() {
  log "08 — zero-downtime rolling deploy"
  if [[ -z "${EXTERNAL_IP}" ]]; then
    record SKIP rolling-deploy "needs the external gateway serving (run after 05)"; return
  fi
  start_probe
  kubectl -n public-services rollout restart deploy/hello-web >/dev/null
  if ! kubectl -n public-services rollout status deploy/hello-web --timeout=240s >/dev/null; then
    read -r _ _ < <(stop_probe)
    record FAIL rolling-deploy "rollout did not complete"; return
  fi
  sleep 5
  local total failures
  read -r total failures < <(stop_probe)
  if (( total > 0 && failures == 0 )); then
    record PASS rolling-deploy "rolling restart completed; ${total} requests, 0 failures"
  else
    record FAIL rolling-deploy "${failures}/${total} requests failed during the rollout"
  fi
}

check_regional_pvc() {
  log "09 — regional PD zone failover (data survives the zone's nodes draining)"
  render "${SCRIPT_DIR}/07-regional-pvc/pvc.yaml" | kubectl apply -f -
  render "${SCRIPT_DIR}/07-regional-pvc/deployment.yaml" | kubectl apply -f -
  if ! kubectl -n "${NS}" rollout status deploy/regional-writer --timeout=300s >/dev/null; then
    record FAIL regional-pvc "regional-writer did not become ready"; return
  fi
  local pod marker node zone
  pod="$(kubectl -n "${NS}" get pod -l app=regional-writer -o jsonpath='{.items[0].metadata.name}')"
  marker="regional-$(date +%s)"
  kubectl -n "${NS}" exec "${pod}" -- sh -c "echo '${marker}' > /data/marker"
  node="$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
  zone="$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
  # Drain every node in the pod's zone: the replacement pod can only land in
  # another zone, and the regional disk must follow it.
  log "  draining zone ${zone} (node(s) hosting the volume)..."
  local z_nodes n
  z_nodes="$(kubectl get nodes -l "topology.kubernetes.io/zone=${zone}" -o name)"
  for n in ${z_nodes}; do
    kubectl drain "${n#node/}" --ignore-daemonsets --delete-emptydir-data --timeout=300s >/dev/null 2>&1 || true
  done
  local ok=0
  if kubectl -n "${NS}" rollout status deploy/regional-writer --timeout=420s >/dev/null 2>&1; then
    pod="$(kubectl -n "${NS}" get pod -l app=regional-writer --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    local new_zone read_back
    new_zone="$(kubectl get node "$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true)"
    read_back="$(kubectl -n "${NS}" exec "${pod}" -- cat /data/marker 2>/dev/null || true)"
    [[ "${read_back}" == "${marker}" && "${new_zone}" != "${zone}" ]] && ok=1
  fi
  for n in ${z_nodes}; do kubectl uncordon "${n#node/}" >/dev/null 2>&1 || true; done
  if (( ok )); then
    record PASS regional-pvc "pod rescheduled from ${zone} to ${new_zone:-?} with data intact"
  else
    record FAIL regional-pvc "pod did not reschedule cross-zone with its data (zone ${zone})"
  fi
}

check_node_autoscale() {
  log "10 — node autoscaling (pending pods add a node; ADR-0007)"
  local nodes_before
  nodes_before="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
  render "${SCRIPT_DIR}/08-autoscale/deployment.yaml" | kubectl apply -f -
  kubectl -n "${NS}" scale deploy/capacity-demand --replicas=6 >/dev/null
  # Scale-out: CA reacts to the pending pods in ~1 min; a node boots in ~2 min.
  log "  waiting for the autoscaler to add capacity (up to ~8 min)..."
  local ready nodes_after attempt
  for attempt in $(seq 1 32); do
    ready="$(kubectl -n "${NS}" get deploy capacity-demand -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${ready:-0}" == "6" ]] && break
    sleep 15
  done
  nodes_after="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
  kubectl -n "${NS}" scale deploy/capacity-demand --replicas=1 >/dev/null 2>&1 || true
  if [[ "${ready:-0}" == "6" ]] && (( nodes_after > nodes_before )); then
    record PASS node-autoscale "6/6 replicas running; nodes ${nodes_before} -> ${nodes_after} (scale-in is slow by design, ~10 min)"
  else
    record FAIL node-autoscale "ready=${ready:-0}/6, nodes ${nodes_before} -> ${nodes_after}"
  fi
}

check_hpa() {
  log "11 — Horizontal Pod Autoscaler (load scales replicas out)"
  render "${SCRIPT_DIR}/09-hpa/hpa.yaml" | kubectl apply -f -
  if ! kubectl -n "${NS}" rollout status deploy/hpa-web --timeout=180s >/dev/null; then
    record FAIL hpa "hpa-web did not become ready"; return
  fi
  log "  waiting for metrics + scale-out (up to ~6 min)..."
  local replicas attempt
  for attempt in $(seq 1 24); do
    replicas="$(kubectl -n "${NS}" get hpa hpa-web -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo 1)"
    (( ${replicas:-1} > 1 )) && break
    sleep 15
  done
  # Stop the load either way so the cluster quiets down for later checks.
  kubectl -n "${NS}" scale deploy/hpa-load --replicas=0 >/dev/null 2>&1 || true
  if (( ${replicas:-1} > 1 )); then
    record PASS hpa "load drove hpa-web to ${replicas} replicas (target CPU 30%)"
  else
    record FAIL hpa "replicas stayed at ${replicas:-1} under load"
  fi
}

check_preemption() {
  log "12 — priority preemption (workload-high schedules under pressure)"
  render "${SCRIPT_DIR}/10-preemption/filler.yaml" | kubectl apply -f -
  # Let the filler saturate: at the pool maximum some replicas stay Pending by
  # design — that is the pressure the high-tier pod must overcome.
  sleep 45
  render "${SCRIPT_DIR}/10-preemption/critical.yaml" | kubectl apply -f -
  local ok=0
  if kubectl -n "${NS}" wait --for=condition=Ready pod/critical-claim --timeout=300s >/dev/null 2>&1; then
    ok=1
  fi
  local preempted
  preempted="$(kubectl -n "${NS}" get events --field-selector reason=Preempted -o name 2>/dev/null | wc -l | tr -d ' ')"
  kubectl -n "${NS}" delete deploy filler --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS}" delete pod critical-claim --ignore-not-found >/dev/null 2>&1 || true
  if (( ok )); then
    record PASS preemption "workload-high pod scheduled under pressure (${preempted} Preempted event(s))"
  else
    record FAIL preemption "critical-claim did not schedule within 5 min"
  fi
}

CREATED_BACKUP=""
CREATED_RESTORE=""
check_backup_restore() {
  log "13 — backup -> delete -> restore (ADR-0004; runs LAST: the restore bounces the workload namespaces)"
  if [[ -z "${BACKUP_PLAN}" || -z "${RESTORE_PLAN}" ]]; then
    record SKIP backup-restore "backup/restore plan outputs not set"; return
  fi
  # A fresh marker on the encrypted volume is what must come back.
  local marker stamp
  stamp="$(date +%s)"
  marker="backup-${stamp}"
  if ! kubectl -n "${NS}" exec pvc-writer -- sh -c "echo '${marker}' > /data/marker" 2>/dev/null; then
    record FAIL backup-restore "could not write the marker (is pvc-writer running?)"; return
  fi
  CREATED_BACKUP="val-${stamp}"
  log "  creating on-demand backup ${CREATED_BACKUP} (waits for completion)..."
  if ! gcloud backup-restore backups create "${CREATED_BACKUP}" --project "${PROJECT_ID}" \
      --location "${LOCATION}" --backup-plan "${BACKUP_PLAN}" --wait-for-completion --quiet >/dev/null; then
    record FAIL backup-restore "on-demand backup did not complete"; return
  fi
  log "  deleting namespace ${NS}..."
  kubectl delete namespace "${NS}" --wait --timeout=300s >/dev/null
  CREATED_RESTORE="val-${stamp}"
  log "  restoring (waits for completion)..."
  if ! gcloud backup-restore restores create "${CREATED_RESTORE}" --project "${PROJECT_ID}" \
      --location "${LOCATION}" --restore-plan "${RESTORE_PLAN}" \
      --backup "projects/${PROJECT_ID}/locations/${LOCATION}/backupPlans/${BACKUP_PLAN}/backups/${CREATED_BACKUP}" \
      --wait-for-completion --quiet >/dev/null; then
    record FAIL backup-restore "restore did not complete"; return
  fi
  if ! kubectl -n "${NS}" wait --for=condition=Ready pod/pvc-writer --timeout=300s >/dev/null 2>&1; then
    record FAIL backup-restore "pvc-writer not Ready after the restore"; return
  fi
  local read_back
  read_back="$(kubectl -n "${NS}" exec pvc-writer -- cat /data/marker 2>/dev/null || true)"
  if [[ "${read_back}" == "${marker}" ]]; then
    record PASS backup-restore "namespace deleted and restored; volume data intact ('${marker}')"
  else
    record FAIL backup-restore "marker not restored (got '${read_back}')"
  fi
}

# --- teardown --------------------------------------------------------------

# Tear down what setup_wi_prereqs and the examples created. Safe to call when
# config (cluster connection, project) is already resolved, so we can chain it
# inside main() without re-fetching kubeconfig.
do_cleanup() {
  log "Tearing down examples + WI scaffolding"
  # Re-admit any node a failed run left cordoned (drain/zone-failover checks).
  local cordoned n
  cordoned="$(kubectl get nodes --field-selector spec.unschedulable=true -o name 2>/dev/null || true)"
  for n in ${cordoned}; do kubectl uncordon "${n#node/}" >/dev/null 2>&1 || true; done
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
  # Ingress examples live in the platform namespaces — remove the objects, not
  # the namespaces (the cluster stack owns those).
  render "${SCRIPT_DIR}/05-external-ingress/ingress.yaml" | kubectl delete --ignore-not-found -f - 2>/dev/null || true
  render "${SCRIPT_DIR}/06-internal-ingress/ingress.yaml" | kubectl delete --ignore-not-found -f - 2>/dev/null || true
  kubectl -n internal-tools delete pod ingress-test --ignore-not-found 2>/dev/null || true
  gcloud iam service-accounts delete "${WI_GSA}" --project "${PROJECT_ID}" --quiet 2>/dev/null || true
  gcloud secrets delete "${SECRET_NAME}" --project "${PROJECT_ID}" --quiet 2>/dev/null || true
  # On-demand validation backups must not outlive the run (#31 teardown
  # hygiene): delete every val-* restore + backup, not just this run's.
  if [[ -n "${BACKUP_PLAN:-}" ]]; then
    local r b
    for r in $(gcloud backup-restore restores list --project "${PROJECT_ID}" --location "${LOCATION}"         --restore-plan "${RESTORE_PLAN}" --format='value(name)' 2>/dev/null | grep -o 'val-[0-9]*' || true); do
      gcloud backup-restore restores delete "${r}" --project "${PROJECT_ID}" --location "${LOCATION}"         --restore-plan "${RESTORE_PLAN}" --quiet 2>/dev/null || true
    done
    for b in $(gcloud backup-restore backups list --project "${PROJECT_ID}" --location "${LOCATION}"         --backup-plan "${BACKUP_PLAN}" --format='value(name)' 2>/dev/null | grep -o 'val-[0-9]*' || true); do
      gcloud backup-restore backups delete "${b}" --project "${PROJECT_ID}" --location "${LOCATION}"         --backup-plan "${BACKUP_PLAN}" --quiet 2>/dev/null || true
    done
  fi
}

# --cleanup mode: just tear down (resolve + connect, then delete).
cleanup() {
  resolve_config
  connect
  do_cleanup
  log "Done"
}

# Returns 0 if every recorded result is PASS, non-zero otherwise. Side effect:
# prints the summary table.
summary() {
  log "Summary"
  local failed=0
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"${r}"
    printf '  %-5s %-20s %s\n' "${status}" "${name}" "${detail}"
    [[ "${status}" == "FAIL" ]] && failed=1
  done
  return "${failed}"
}

main() {
  # Default: auto-clean on success. --keep leaves state for inspection even on
  # success; --cleanup is the standalone teardown mode (no checks).
  local auto_cleanup=1
  case "${1:-}" in
    --cleanup) cleanup; exit 0 ;;
    --keep)    auto_cleanup=0 ;;
    "")        : ;;
    *) die "unknown flag: $1 (use --keep or --cleanup)" ;;
  esac

  resolve_config
  connect
  ensure_namespace
  setup_wi_prereqs
  check_hello_web
  check_encrypted_pvc
  check_artifact_registry
  check_workload_identity
  check_external_ingress
  check_internal_ingress
  check_drain_survival
  check_rolling_deploy
  check_regional_pvc
  check_node_autoscale
  check_hpa
  check_preemption
  check_backup_restore

  if summary; then
    if (( auto_cleanup )); then
      do_cleanup
      log "All examples passed — the cluster is ready for workloads (WLD-2). State cleaned."
    else
      log "All examples passed — the cluster is ready for workloads (WLD-2). State left for inspection (--keep)."
    fi
    exit 0
  else
    # On failure, leave the state alone so an operator can inspect with
    # `kubectl -n ${NS} ...`. Tell them how to clean up afterward.
    log "One or more examples FAILED — state left behind for inspection."
    log "Inspect with: kubectl -n ${NS} get pods,svc,pvc"
    log "Clean up after with: ${BASH_SOURCE[0]} --cleanup"
    exit 1
  fi
}

main "$@"
