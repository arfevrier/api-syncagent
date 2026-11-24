#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_command docker
require_command kind
require_command jq
require_command setsid

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but its daemon is not reachable." >&2
  exit 1
fi

if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "Creating Kind cluster $KIND_CLUSTER_NAME..."
  kind_args=(create cluster --name "$KIND_CLUSTER_NAME"
    --kubeconfig "$KUBECONFIG_DIR/kind.kubeconfig")
  if [[ -n "${DEMO_KIND_IMAGE:-}" ]]; then
    kind_args+=(--image "$DEMO_KIND_IMAGE")
  fi
  kind "${kind_args[@]}"
fi
kind get kubeconfig --name "$KIND_CLUSTER_NAME" >"$KUBECONFIG_DIR/kind.kubeconfig"

if [[ -z "$KCP_BIN" ]]; then
  echo "Downloading the repository's configured kcp version..."
  KCP_BIN="$(cd "$REPO_DIR" && UGET_PRINT_PATH=absolute make --no-print-directory install-kcp)"
fi

if [[ -f "$STATE_DIR/kcp.pid" ]] && kill -0 "$(cat "$STATE_DIR/kcp.pid")" 2>/dev/null; then
  echo "Reusing the running kcp server."
else
  echo "Starting kcp..."
  setsid "$KCP_BIN" start \
    --root-directory "$STATE_DIR/kcp" \
    --secure-port "${DEMO_KCP_PORT:-6443}" \
    --embedded-etcd-client-port "${DEMO_ETCD_CLIENT_PORT:-2379}" \
    --embedded-etcd-peer-port "${DEMO_ETCD_PEER_PORT:-2380}" \
    >"$STATE_DIR/kcp.log" 2>&1 &
  echo "$!" >"$STATE_DIR/kcp.pid"
fi

wait_for "the kcp admin kubeconfig" 30 test -s "$STATE_DIR/kcp/admin.kubeconfig"
cp "$STATE_DIR/kcp/admin.kubeconfig" "$KUBECONFIG_DIR/kcp-root.kubeconfig"
wait_for "kcp" 90 kubectl_with "$KUBECONFIG_DIR/kcp-root.kubeconfig" get workspaces

for workspace in application-provider database-provider customer; do
  cat <<EOF | kubectl_with "$KUBECONFIG_DIR/kcp-root.kubeconfig" apply -f -
apiVersion: tenancy.kcp.io/v1alpha1
kind: Workspace
metadata:
  name: $workspace
EOF
  wait_for "workspace $workspace" 60 workspace_is_ready "$workspace"
  create_workspace_kubeconfig "$workspace" "$KUBECONFIG_DIR/$workspace.kubeconfig"
done

echo "Creating the Database provider APIExport..."
kubectl_with "$KUBECONFIG_DIR/database-provider.kubeconfig" apply \
  -f "$DEMO_DIR/manifests/kcp/database-api.yaml" \
  -f "$DEMO_DIR/manifests/kcp/provider-access.yaml"
wait_for "the Database APIExport identity" 60 jsonpath_is_nonempty \
  "$KUBECONFIG_DIR/database-provider.kubeconfig" apiexport databases \
  '.status.identityHash'
echo "Creating the Application provider APIExport and endpoint slice..."
kubectl_with "$KUBECONFIG_DIR/application-provider.kubeconfig" apply \
  -f "$DEMO_DIR/manifests/kcp/application-api.yaml" \
  -f "$DEMO_DIR/manifests/kcp/provider-access.yaml"

echo "Creating the customer APIBindings..."
if ! kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" get apibinding databases \
  >/dev/null 2>&1; then
  kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" create --save-config \
    -f "$DEMO_DIR/manifests/kcp/database-binding.yaml"
fi
if ! kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" get apibinding applications \
  >/dev/null 2>&1; then
  kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" create --save-config \
    -f "$DEMO_DIR/manifests/kcp/application-binding.yaml"
fi
wait_for "the Database APIBinding" 90 condition_is_true \
  "$KUBECONFIG_DIR/customer.kubeconfig" apibinding databases Ready
# Requeue endpoint slices after their first consumer exists. This also avoids a startup race in a
# fresh single-process kcp where the endpoint-slice URL controller can observe the slice first.
requeue_value="$(date +%s)"
kubectl_with "$KUBECONFIG_DIR/database-provider.kubeconfig" annotate \
  apiexportendpointslice databases "demo.kcp.io/requeue=$requeue_value" --overwrite
kubectl_with "$KUBECONFIG_DIR/application-provider.kubeconfig" annotate \
  apiexportendpointslice applications "demo.kcp.io/requeue=$requeue_value" --overwrite
wait_for "the Database virtual workspace" 60 jsonpath_is_nonempty \
  "$KUBECONFIG_DIR/database-provider.kubeconfig" apiexportendpointslice databases \
  '.status.endpoints[0].url'
create_virtual_workspace_kubeconfig \
  "$KUBECONFIG_DIR/database-provider.kubeconfig" databases \
  "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig"
wait_for "the Application virtual workspace" 60 jsonpath_is_nonempty \
  "$KUBECONFIG_DIR/application-provider.kubeconfig" apiexportendpointslice applications \
  '.status.endpoints[0].url'
create_virtual_workspace_kubeconfig \
  "$KUBECONFIG_DIR/application-provider.kubeconfig" applications \
  "$KUBECONFIG_DIR/application-provider-virtual-workspace.kubeconfig"

echo "Installing the service-cluster APIs and PublishedResource..."
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" apply \
  -f "$REPO_DIR/deploy/crd/kcp.io/syncagent.kcp.io_publishedresources.yaml" \
  -f "$DEMO_DIR/manifests/kind/service-apis.yaml"
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" wait --for=condition=Established \
  crd/applications.platform.internal.demo crd/databases.database.internal.demo \
  crd/publishedresources.syncagent.kcp.io --timeout=60s
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" apply \
  -f "$DEMO_DIR/manifests/kind/namespace.yaml"

database_identity="$(kubectl_with "$KUBECONFIG_DIR/database-provider.kubeconfig" \
  get apiexport databases -o jsonpath='{.status.identityHash}')"
sed "s/__DATABASE_IDENTITY_HASH__/$database_identity/g" \
  "$DEMO_DIR/manifests/kind/published-resource.yaml.tpl" \
  | kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" apply -f -

echo
echo "Infrastructure is ready. Start the agent in another terminal with:"
echo "  ./demo/run-agent.sh"
echo
echo "Then load the example with:"
echo "  ./demo/load-scenario.sh"
