#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if pgrep -f "$REPO_DIR/_build/api-syncagent" >/dev/null 2>&1; then
  echo "Stop the running api-syncagent before starting this test." >&2
  exit 1
fi

database_identity="$(kubectl_with "$KUBECONFIG_DIR/database-provider.kubeconfig" \
  get apiexport databases -o jsonpath='{.status.identityHash}')"

published_resource() {
  local name="$1"
  local watch="${2:-}"

  cat <<EOF
apiVersion: syncagent.kcp.io/v1alpha1
kind: PublishedResource
metadata:
  name: $name
spec:
  resource:
    apiGroup: platform.internal.demo
    versions:
      - v1alpha1
    kind: Application
  naming:
    name: "{{ .Object.metadata.name }}"
    namespace: demo
  projection:
    group: applications.demo.kcp.io
  related:
    - identifier: database
      origin: kcp
      group: databases.demo.kcp.io
      version: v1alpha1
      resource: databases
      identityHash: $database_identity
      projection:
        group: database.internal.demo
      object:
        reference:
          path: spec.databaseName
      syncStatus: true
      syncStatusOrigin: kcp
$watch
EOF
}

echo "Checking that a literal watch: {} is rejected..."
if validation_error="$(published_resource invalid-empty-watch '      watch: {}' \
  | kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" apply --dry-run=server -f - 2>&1)"; then
  echo "Expected watch: {} to be rejected, but validation accepted it." >&2
  exit 1
fi
echo "$validation_error" | grep -q "exactly one of byOwner or bySelector must be set"

echo "Installing the equivalent configuration with watch omitted..."
published_resource applications \
  | kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" apply -f -

echo "Resetting the Application and Database objects..."
kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" -n default delete \
  applications.applications.demo.kcp.io customer-portal --ignore-not-found --wait=false
kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" -n default delete \
  databases.databases.demo.kcp.io customer-portal-db --ignore-not-found --wait=false
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo delete \
  applications.platform.internal.demo customer-portal --ignore-not-found --wait=true
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo delete \
  databases.database.internal.demo customer-portal-db --ignore-not-found --wait=true

echo "Starting api-syncagent..."
make -C "$REPO_DIR" -B api-syncagent BUILD_DEST="$(dirname "$AGENT_BINARY")"
setsid "$AGENT_BINARY" \
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
  --namespace api-syncagent-demo \
  >"$STATE_DIR/agent-kcp-origin-no-watch.log" 2>&1 &
agent_pid="$!"
echo "$agent_pid" >"$STATE_DIR/agent.pid"
cleanup_agent() {
  if kill -0 "$agent_pid" 2>/dev/null; then
    kill "$agent_pid"
    wait "$agent_pid" 2>/dev/null || true
  fi
}
trap cleanup_agent EXIT

agent_is_ready() {
  curl --silent "http://$HEALTH_ADDRESS/readyz" >/dev/null
}
wait_for "api-syncagent" 180 agent_is_ready

kcp_application_is_absent() {
  ! kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" -n default get \
    applications.applications.demo.kcp.io customer-portal >/dev/null 2>&1
}
kcp_database_is_absent() {
  ! kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" -n default get \
    databases.databases.demo.kcp.io customer-portal-db >/dev/null 2>&1
}
wait_for "the previous kcp Application deletion" 120 kcp_application_is_absent
wait_for "the previous kcp Database deletion" 120 kcp_database_is_absent

echo "Creating the kcp Database without status, then its primary Application..."
cat <<'EOF' | kubectl_with \
  "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" apply -f -
apiVersion: databases.demo.kcp.io/v1alpha1
kind: Database
metadata:
  name: customer-portal-db
  namespace: default
spec:
  engine: PostgreSQL
  storageGiB: 20
EOF
kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" apply \
  -f "$DEMO_DIR/manifests/kcp/application.yaml"

wait_for "the service Application" 120 kubectl_with \
  "$KUBECONFIG_DIR/kind.kubeconfig" -n demo get \
  applications.platform.internal.demo customer-portal
wait_for "the service Database" 120 kubectl_with \
  "$KUBECONFIG_DIR/kind.kubeconfig" -n demo get \
  databases.database.internal.demo customer-portal-db

initial_phase="$(kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo get \
  databases.database.internal.demo customer-portal-db -o jsonpath='{.status.phase}')"
if [[ -n "$initial_phase" ]]; then
  echo "The service Database unexpectedly had status before the test update." >&2
  exit 1
fi

echo "Updating only the kcp Database status..."
kubectl_with "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" \
  -n default patch databases.databases.demo.kcp.io customer-portal-db \
  --subresource=status --type=merge \
  -p '{"status":{"phase":"Ready","endpoint":"customer-portal-db.demo.svc:5432"}}'

sleep 10

kcp_phase="$(kubectl_with "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" \
  -n default get databases.databases.demo.kcp.io customer-portal-db \
  -o jsonpath='{.status.phase}')"
service_phase="$(kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo get \
  databases.database.internal.demo customer-portal-db -o jsonpath='{.status.phase}')"

if [[ "$kcp_phase" != "Ready" ]]; then
  echo "The kcp status update was not stored." >&2
  exit 1
fi
if [[ -n "$service_phase" ]]; then
  echo "Database.status was unexpectedly synchronized to the service cluster." >&2
  exit 1
fi

echo "Triggering a primary reconciliation to prove that the pending status can be synchronized..."
kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" -n default annotate \
  applications.applications.demo.kcp.io customer-portal \
  "demo.kcp.io/reconcile=$(date +%s)" --overwrite

status_is_synced() {
  [[ "$(kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo get \
    databases.database.internal.demo customer-portal-db \
    -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]
}
wait_for "the pending Database status after primary reconciliation" 120 status_is_synced

echo
echo "PASS: the kcp status changed, but no related watch enqueued the primary."
echo "It reached the service cluster only after an Application event triggered reconciliation."
