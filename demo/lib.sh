#!/usr/bin/env bash

set -euo pipefail
umask 077

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$DEMO_DIR/.." && pwd)"
STATE_DIR="${DEMO_STATE_DIR:-$DEMO_DIR/.state}"
KUBECONFIG_DIR="${DEMO_KUBECONFIG_DIR:-$DEMO_DIR/kubeconfigs}"
KIND_CLUSTER_NAME="${DEMO_KIND_CLUSTER_NAME:-api-syncagent-demo}"
AGENT_BINARY="${DEMO_AGENT_BINARY:-$REPO_DIR/_build/api-syncagent}"
HEALTH_ADDRESS="${DEMO_HEALTH_ADDRESS:-127.0.0.1:8086}"
METRICS_ADDRESS="${DEMO_METRICS_ADDRESS:-127.0.0.1:8085}"

mkdir -p "$STATE_DIR" "$KUBECONFIG_DIR"

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL_BIN="$(command -v kubectl)"
elif [[ -x "$REPO_DIR/_tools/kubectl-v1.34.2" ]]; then
  KUBECTL_BIN="$REPO_DIR/_tools/kubectl-v1.34.2"
else
  echo "kubectl is required." >&2
  exit 1
fi

if [[ -x "$REPO_DIR/_tools/kcp-0.32.0" ]]; then
  KCP_BIN="$REPO_DIR/_tools/kcp-0.32.0"
else
  KCP_BIN=""
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required." >&2
    exit 1
  fi
}

kubectl_with() {
  local kubeconfig="$1"
  shift
  "$KUBECTL_BIN" --kubeconfig "$kubeconfig" "$@"
}

wait_for() {
  local description="$1"
  local attempts="$2"
  shift 2

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Timed out waiting for $description." >&2
  return 1
}

workspace_is_ready() {
  local name="$1"
  [[ "$(kubectl_with "$KUBECONFIG_DIR/kcp-root.kubeconfig" \
    get workspace "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]
}

create_workspace_kubeconfig() {
  local workspace="$1"
  local output="$2"
  local cluster_name server base_url target_url

  cluster_name="$(kubectl_with "$KUBECONFIG_DIR/kcp-root.kubeconfig" \
    get workspace "$workspace" -o jsonpath='{.spec.cluster}')"
  server="$(kubectl_with "$KUBECONFIG_DIR/kcp-root.kubeconfig" \
    config view --minify --raw -o json | jq -r '.clusters[0].cluster.server')"
  base_url="${server%%/clusters/*}"
  target_url="$base_url/clusters/$cluster_name"

  kubectl_with "$KUBECONFIG_DIR/kcp-root.kubeconfig" config view --minify --raw -o json \
    | jq --arg server "$target_url" '.clusters[0].cluster.server = $server' >"$output"
}

create_virtual_workspace_kubeconfig() {
  local source_kubeconfig="$1"
  local endpoint_slice_name="$2"
  local output="$3"
  local customer_cluster url

  url="$(kubectl_with "$source_kubeconfig" get apiexportendpointslice \
    "$endpoint_slice_name" -o jsonpath='{.status.endpoints[0].url}')"
  customer_cluster="$(kubectl_with "$KUBECONFIG_DIR/kcp-root.kubeconfig" \
    get workspace customer -o jsonpath='{.spec.cluster}')"
  url="$url/clusters/$customer_cluster"
  kubectl_with "$source_kubeconfig" config view --minify --raw -o json \
    | jq --arg server "$url" '.clusters[0].cluster.server = $server' >"$output"
}

condition_is_true() {
  local kubeconfig="$1"
  local resource="$2"
  local name="$3"
  local condition="$4"

  [[ "$(kubectl_with "$kubeconfig" get "$resource" "$name" -o json \
    | jq -r --arg condition "$condition" \
      '.status.conditions[]? | select(.type == $condition) | .status' | head -1)" == "True" ]]
}

jsonpath_is_nonempty() {
  local kubeconfig="$1"
  local resource="$2"
  local name="$3"
  local jsonpath="$4"

  [[ -n "$(kubectl_with "$kubeconfig" get "$resource" "$name" \
    -o "jsonpath={$jsonpath}" 2>/dev/null)" ]]
}
