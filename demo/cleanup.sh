#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [[ -f "$STATE_DIR/kcp.pid" ]] && kill -0 "$(cat "$STATE_DIR/kcp.pid")" 2>/dev/null; then
  kill "$(cat "$STATE_DIR/kcp.pid")"
  for _ in {1..30}; do
    if ! kill -0 "$(cat "$STATE_DIR/kcp.pid")" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
fi

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  kind delete cluster --name "$KIND_CLUSTER_NAME" \
    --kubeconfig "$KUBECONFIG_DIR/kind.kubeconfig"
fi

echo "The Kind cluster and kcp process have been stopped."
echo "Generated state remains in demo/.state and demo/kubeconfigs for inspection."
