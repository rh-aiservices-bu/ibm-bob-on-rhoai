#!/usr/bin/env bash
set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
DEFAULT_MODEL="hf://Qwen/Qwen3.5-4B"
DEFAULT_PVC_SIZE="20Gi"
DEFAULT_IMAGE="registry.access.redhat.com/ubi9/python-311"

# ── helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Load a HuggingFace model into an OpenShift PVC.

Required:
  -n, --namespace       OpenShift namespace/project
  -p, --pvc-name        Name for the PVC

Optional:
  -m, --model           HuggingFace model URL          (default: ${DEFAULT_MODEL})
  -s, --pvc-size        PVC capacity                   (default: ${DEFAULT_PVC_SIZE})
  -c, --storage-class   StorageClass name              (default: cluster default)
  -i, --image           Container image for downloader (default: ${DEFAULT_IMAGE})
  -t, --token           HuggingFace API token          (or set \$HF_TOKEN)
  -N, --node            Node name to schedule the loader pod on
  -g, --gpu-toleration  Add toleration for nvidia.com/gpu:NoSchedule tainted nodes
  -h, --help            Show this help

If no token is provided, the model must be publicly accessible.
The token is stored in a temporary OpenShift secret and cleaned up on exit.
EOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "--> $*"; }

# ── argument parsing ──────────────────────────────────────────────────────────
NAMESPACE=""
PVC_NAME=""
MODEL="${DEFAULT_MODEL}"
PVC_SIZE="${DEFAULT_PVC_SIZE}"
STORAGE_CLASS=""
IMAGE="${DEFAULT_IMAGE}"
HF_TOKEN_ARG=""
NODE_NAME=""
GPU_TOLERATION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)       NAMESPACE="$2";     shift 2 ;;
    -p|--pvc-name)        PVC_NAME="$2";      shift 2 ;;
    -m|--model)           MODEL="$2";         shift 2 ;;
    -s|--pvc-size)        PVC_SIZE="$2";      shift 2 ;;
    -c|--storage-class)   STORAGE_CLASS="$2"; shift 2 ;;
    -i|--image)           IMAGE="$2";         shift 2 ;;
    -t|--token)           HF_TOKEN_ARG="$2";  shift 2 ;;
    -N|--node)            NODE_NAME="$2";     shift 2 ;;
    -g|--gpu-toleration)  GPU_TOLERATION=true; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) die "Unknown option: '$1'. Use --help for usage." ;;
  esac
done

# ── validation ────────────────────────────────────────────────────────────────
command -v oc &>/dev/null || die "'oc' not found in PATH. Install the OpenShift CLI first."

[[ -n "$NAMESPACE" ]] || die "--namespace / -n is required"
[[ -n "$PVC_NAME"  ]] || die "--pvc-name / -p is required"

# --token takes priority over the $HF_TOKEN env var
HF_TOKEN="${HF_TOKEN_ARG:-${HF_TOKEN:-}}"

if [[ -z "$HF_TOKEN" ]]; then
  echo "WARNING: No HuggingFace token provided. Model must be publicly accessible."
fi

# Strip optional hf:// scheme to get the bare repo ID
MODEL_REPO="${MODEL#hf://}"

# Derive DNS-safe names from the PVC name
POD_NAME="$(echo "${PVC_NAME}-loader" | tr '[:upper:]_' '[:lower:]-' | tr -s '-' | sed 's/^-//;s/-$//')"
SECRET_NAME="${POD_NAME}-hf-token"

# Look up the namespace's supplemental-groups range so we can set fsGroup,
# which causes Kubernetes to chown the PVC mount to that GID — required for
# a non-root pod to write to a freshly provisioned volume.
SUPP_GROUPS="$(oc get namespace "${NAMESPACE}" \
  -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}' \
  2>/dev/null || true)"
FS_GROUP="${SUPP_GROUPS%%/*}"  # take just the range start, e.g. 1000560000

# ── summary ───────────────────────────────────────────────────────────────────
echo "┌──────────────────────────────────────────────"
echo "│  Namespace    : ${NAMESPACE}"
echo "│  PVC          : ${PVC_NAME} (${PVC_SIZE})"
[[ -n "$STORAGE_CLASS" ]] && \
echo "│  StorageClass : ${STORAGE_CLASS}"
echo "│  Model        : ${MODEL_REPO}"
echo "│  Image        : ${IMAGE}"
if [[ -n "$HF_TOKEN" ]]; then
  echo "│  HF token     : provided (will create secret '${SECRET_NAME}')"
else
  echo "│  HF token     : none (public model assumed)"
fi
if [[ -n "$FS_GROUP" ]]; then
  echo "│  fsGroup      : ${FS_GROUP}"
else
  echo "│  fsGroup      : not set (namespace annotation not found)"
fi
[[ -n "$NODE_NAME" ]] && \
echo "│  Node         : ${NODE_NAME}"
[[ "$GPU_TOLERATION" == true ]] && \
echo "│  GPU toleration: enabled (nvidia.com/gpu:NoSchedule)"
echo "└──────────────────────────────────────────────"

# ── cleanup trap ──────────────────────────────────────────────────────────────
SECRET_CREATED=false

cleanup() {
  if [[ "$SECRET_CREATED" == true ]]; then
    info "Deleting token secret '${SECRET_NAME}'..."
    oc delete secret "${SECRET_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
  fi
}
trap cleanup EXIT

# ── PVC manifest ──────────────────────────────────────────────────────────────
pvc_manifest() {
  printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  accessModes:\n    - ReadWriteOnce\n' \
    "${PVC_NAME}" "${NAMESPACE}"
  [[ -n "$STORAGE_CLASS" ]] && printf '  storageClassName: %s\n' "${STORAGE_CLASS}"
  printf '  resources:\n    requests:\n      storage: %s\n' "${PVC_SIZE}"
}

# ── Pod manifest ──────────────────────────────────────────────────────────────
pod_manifest() {
  local token_env=""
  if [[ -n "$HF_TOKEN" ]]; then
    token_env="        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: HF_TOKEN
"
  fi

  local fs_group_line=""
  [[ -n "$FS_GROUP" ]] && fs_group_line="    fsGroup: ${FS_GROUP}"

  local node_selector_block=""
  [[ -n "$NODE_NAME" ]] && node_selector_block="  nodeSelector:
    kubernetes.io/hostname: ${NODE_NAME}"

  local tolerations_block=""
  [[ "$GPU_TOLERATION" == true ]] && tolerations_block="  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule"

  cat <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: model-loader
    pvc: ${PVC_NAME}
spec:
  restartPolicy: Never
${node_selector_block}
${tolerations_block}
  securityContext:
    runAsNonRoot: true
${fs_group_line}
  containers:
    - name: downloader
      image: ${IMAGE}
      resources:
        limits:
          cpu: 750m
          memory: 6Gi
        requests:
          cpu: 50m
          memory: 256Mi
      command:
        - /bin/sh
        - -c
        - |
          set -e
          pip install --quiet huggingface_hub
          hf download ${MODEL_REPO} --local-dir /mnt/model
      env:
        - name: HF_HOME
          value: /tmp/hf-cache
${token_env}      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: model-storage
          mountPath: /mnt/model
  volumes:
    - name: model-storage
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
MANIFEST
}

# ── create HF token secret ────────────────────────────────────────────────────
if [[ -n "$HF_TOKEN" ]]; then
  info "Creating token secret '${SECRET_NAME}'..."
  oc create secret generic "${SECRET_NAME}" \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f -
  SECRET_CREATED=true
fi

# ── create PVC ────────────────────────────────────────────────────────────────
info "Creating PVC '${PVC_NAME}'..."
pvc_manifest | oc apply -f -

# ── remove any pre-existing loader pod ───────────────────────────────────────
if oc get pod "${POD_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  info "Removing existing pod '${POD_NAME}'..."
  oc delete pod "${POD_NAME}" -n "${NAMESPACE}" --wait=true
fi

# ── launch loader pod ─────────────────────────────────────────────────────────
info "Launching loader pod '${POD_NAME}'..."
pod_manifest | oc apply -f -

# ── wait until pod leaves Pending ────────────────────────────────────────────
info "Waiting for pod to start..."
while true; do
  PHASE="$(oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
  case "$PHASE" in
    Pending)          sleep 5 ;;
    Running|Succeeded) break ;;
    Failed) die "Pod failed before streaming logs. Inspect with: oc describe pod ${POD_NAME} -n ${NAMESPACE}" ;;
    *)                sleep 3 ;;
  esac
done

# ── stream logs ───────────────────────────────────────────────────────────────
info "Streaming logs (pod: ${POD_NAME})..."
oc logs -f "${POD_NAME}" -n "${NAMESPACE}" --pod-running-timeout=5m || true

# ── wait for terminal phase (log stream exits before phase updates) ───────────
info "Waiting for pod to reach terminal phase..."
while true; do
  FINAL_PHASE="$(oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
  case "$FINAL_PHASE" in
    Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

# ── check final status ────────────────────────────────────────────────────────
if [[ "$FINAL_PHASE" == "Succeeded" ]]; then
  info "Model '${MODEL_REPO}' loaded successfully into PVC '${PVC_NAME}'."
else
  die "Loader pod ended in phase '${FINAL_PHASE}'. Inspect with: oc logs ${POD_NAME} -n ${NAMESPACE}"
fi

# ── clean up loader pod ───────────────────────────────────────────────────────
info "Cleaning up loader pod..."
oc delete pod "${POD_NAME}" -n "${NAMESPACE}"
# Secret is deleted by the EXIT trap

```
