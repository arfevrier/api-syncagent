#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "Building the local api-syncagent binary..."
make -C "$REPO_DIR" -B api-syncagent BUILD_DEST="$(dirname "$AGENT_BINARY")"

exec "$AGENT_BINARY" \
  --agent-name application-provider \
  --apiexportendpointslice-ref applications \
  --enable-leader-election=false \
  --enable-server-side-apply="${DEMO_SERVER_SIDE_APPLY:-false}" \
  --health-address "$HEALTH_ADDRESS" \
  --kcp-kubeconfig "$KUBECONFIG_DIR/application-provider.kubeconfig" \
  --kubeconfig "$KUBECONFIG_DIR/kind.kubeconfig" \
  --log-debug=true \
  --log-format=Console \
  --metrics-address "$METRICS_ADDRESS" \
  --namespace api-syncagent-demo
