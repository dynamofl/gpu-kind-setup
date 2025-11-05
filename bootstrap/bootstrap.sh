#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME=${CLUSTER_NAME:-kind-gpu}
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

NVKIND_DIR=${NVKIND_DIR:-${SCRIPT_DIR}/../nvkind}
TEMPLATE_PATH=${TEMPLATE_PATH:-${SCRIPT_DIR}/nvkind-ingress.yaml}

DELETE_EXISTING=${DELETE_EXISTING:-true}
CONFIGURE_TOOLKIT=${CONFIGURE_TOOLKIT:-false}
SKIP_SMOKE_TEST=${SKIP_SMOKE_TEST:-false}

DEVICE_PLUGIN_RELEASE=${DEVICE_PLUGIN_RELEASE:-nvidia-device-plugin}
DEVICE_PLUGIN_NAMESPACE=${DEVICE_PLUGIN_NAMESPACE:-nvidia}
SMOKE_NAMESPACE=${SMOKE_NAMESPACE:-gpu-smoke}
SMOKE_IMAGE=${SMOKE_IMAGE:-nvidia/cuda:12.4.1-runtime-ubuntu22.04}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

run() {
  log "\$ $*"
  "$@"
}

require_cmd() {
  local cmd=$1
  command -v "${cmd}" >/dev/null 2>&1 || {
    log "ERROR: required command '${cmd}' not found in PATH"
    exit 1
  }
}

ensure_nvkind() {
  if command -v nvkind >/dev/null 2>&1; then
    NVKIND_BIN=$(command -v nvkind)
    log "Using nvkind binary at ${NVKIND_BIN}"
    return
  fi

  if [[ -x "${NVKIND_DIR}/nvkind" ]]; then
    NVKIND_BIN="${NVKIND_DIR}/nvkind"
    log "Using nvkind binary at ${NVKIND_BIN}"
    return
  fi

  log "ERROR: nvkind binary not found. Install nvkind or set NVKIND_DIR"
  exit 1
}

add_trust_store() {
  log "Updating CA trust store"
  run sudo update-ca-certificates
}

configure_toolkit() {
  require_cmd nvidia-ctk
  log "Configuring NVIDIA container toolkit for Docker"
  run sudo nvidia-ctk runtime configure --runtime=docker --set-as-default --cdi.enabled
  run sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
  run sudo systemctl daemon-reload
  run sudo systemctl restart docker
}

delete_existing_cluster() {
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    if [[ "${DELETE_EXISTING}" == "true" ]]; then
      log "Deleting existing kind cluster '${CLUSTER_NAME}'"
      run kind delete cluster --name "${CLUSTER_NAME}"
    else
      log "ERROR: cluster '${CLUSTER_NAME}' already exists (set DELETE_EXISTING=true to replace)"
      exit 1
    fi
  fi
}

apply_runtimeclass() {
  cat <<EOF | kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
}

label_gpu_nodes() {
  log "Labeling worker nodes with nvidia.com/gpu.present=true"
  mapfile -t WORKERS < <(kubectl --context "${KUBE_CONTEXT}" get nodes \
    --selector='!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  for node in "${WORKERS[@]}"; do
    [[ -n "${node}" ]] && run kubectl --context "${KUBE_CONTEXT}" label node "${node}" nvidia.com/gpu.present=true --overwrite
  done
}

install_device_plugin() {
  log "Ensuring NVIDIA device plugin Helm repo is configured"
  run helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update >/dev/null

  log "Installing NVIDIA device plugin release '${DEVICE_PLUGIN_RELEASE}'"
  run helm upgrade --install "${DEVICE_PLUGIN_RELEASE}" nvdp/nvidia-device-plugin \
    --namespace "${DEVICE_PLUGIN_NAMESPACE}" \
    --create-namespace \
    --kube-context "${KUBE_CONTEXT}" \
    --set runtimeClassName=nvidia

  kubectl --context "${KUBE_CONTEXT}" -n "${DEVICE_PLUGIN_NAMESPACE}" wait \
    --for=condition=Ready \
    pod -l app.kubernetes.io/name=nvidia-device-plugin \
    --timeout=180s >/dev/null || \
    log "WARN: device plugin pods did not all report Ready"
}

wait_for_gpu_resources() {
  log "Waiting for GPU resources to become allocatable"
  for attempt in {1..24}; do
    local gpu_nodes
    gpu_nodes=$(kubectl --context "${KUBE_CONTEXT}" get nodes -o json | jq '[.items[] | select(.status.allocatable."nvidia.com/gpu" != null and (.status.allocatable."nvidia.com/gpu" | tonumber) > 0)] | length')
    if [[ "${gpu_nodes}" -gt 0 ]]; then
      log "Detected ${gpu_nodes} node(s) with GPU resources"
      return
    fi
    sleep 5
  done

  log "ERROR: No nodes report allocatable GPUs after waiting. Device plugin logs follow:"
  kubectl --context "${KUBE_CONTEXT}" -n "${DEVICE_PLUGIN_NAMESPACE}" logs \
    -l app.kubernetes.io/name=nvidia-device-plugin --tail=200 || true
  exit 1
}

run_smoke_test() {
  [[ "${SKIP_SMOKE_TEST}" == "true" ]] && return

  log "Running GPU smoke-test pod"
  kubectl --context "${KUBE_CONTEXT}" create namespace "${SMOKE_NAMESPACE}" >/dev/null 2>&1 || true

  cat <<EOF | kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke-test
spec:
  runtimeClassName: nvidia
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.present: "true"
  containers:
    - name: cuda-smi
      image: ${SMOKE_IMAGE}
      command: ["bash","-lc","nvidia-smi -L"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

  run kubectl --context "${KUBE_CONTEXT}" wait --for=condition=Ready pod/gpu-smoke-test --timeout=180s
  run kubectl --context "${KUBE_CONTEXT}" logs gpu-smoke-test
  run kubectl --context "${KUBE_CONTEXT}" delete pod/gpu-smoke-test --ignore-not-found
}

main() {
  for cmd in docker kind kubectl helm git jq; do
    require_cmd "${cmd}"
  done

  ensure_nvkind
  [[ "${CONFIGURE_TOOLKIT}" == "true" ]] && configure_toolkit

  [[ -f "${TEMPLATE_PATH}" ]] || {
    log "ERROR: cluster template not found at ${TEMPLATE_PATH}"
    exit 1
  }

  delete_existing_cluster

  log "Creating GPU-enabled kind cluster '${CLUSTER_NAME}' via nvkind"
  run "${NVKIND_BIN}" cluster create \
    --name "${CLUSTER_NAME}" \
    --config-template "${TEMPLATE_PATH}"

  log "Setting kubectl context to ${KUBE_CONTEXT}"
  run kubectl config use-context "${KUBE_CONTEXT}"

  log "Adding CA certificates to trust store"
  add_trust_store
  log "Applying RuntimeClass"
  apply_runtimeclass
  log "Labeling GPU nodes"
  label_gpu_nodes
  log "Installing NVIDIA device plugin"
  install_device_plugin
  log "Waiting for GPU resources"
  wait_for_gpu_resources
  log "Running smoke test"
  run_smoke_test

  log "Cluster '${CLUSTER_NAME}' is ready for GPU workloads."
}

main "$@"
