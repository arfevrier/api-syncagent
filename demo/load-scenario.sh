#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

export_has_schema() {
  [[ "$(kubectl_with "$KUBECONFIG_DIR/application-provider.kubeconfig" \
    get apiexport applications -o json \
    | jq '(.spec.resources // .spec.latestResourceSchemas // []) | length')" -gt 0 ]]
}

echo "Waiting for api-syncagent to publish the Application API..."
wait_for "the Application APIResourceSchema" 120 export_has_schema

echo "Accepting the Application APIExport permission claims..."
claims="$(kubectl_with "$KUBECONFIG_DIR/application-provider.kubeconfig" \
  get apiexport applications -o json | jq -c \
  '[.spec.permissionClaims[]? | . + {state: "Accepted", selector: {matchAll: true}}]')"

jq -n --argjson claims "$claims" '{
  apiVersion: "apis.kcp.io/v1alpha2",
  kind: "APIBinding",
  metadata: {name: "applications"},
  spec: {
    reference: {export: {path: "root:application-provider", name: "applications"}},
    permissionClaims: $claims
  }
}' | kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" apply -f -

wait_for "the Application APIBinding" 120 condition_is_true \
  "$KUBECONFIG_DIR/customer.kubeconfig" apibinding applications Ready

echo "Creating the customer Application..."
kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" apply \
  -f "$DEMO_DIR/manifests/kcp/application.yaml"

echo "Waiting for its service-cluster copy..."
wait_for "the service Application" 120 kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" \
  -n demo get applications.platform.internal.demo customer-portal

echo "Creating the provider-side Database..."
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" apply \
  -f "$DEMO_DIR/manifests/kind/database.yaml"

echo "Making the Database owned by the service-side Application..."
application_uid="$(kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo \
  get applications.platform.internal.demo customer-portal -o jsonpath='{.metadata.uid}')"
owner_reference="$(jq -nc --arg uid "$application_uid" '{
  metadata: {
    ownerReferences: [{
      apiVersion: "platform.internal.demo/v1alpha1",
      kind: "Application",
      name: "customer-portal",
      uid: $uid
    }]
  }
}')"
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo patch \
  databases.database.internal.demo customer-portal-db --type=merge -p "$owner_reference"

echo "Waiting for Database.spec to reach kcp..."
wait_for "the kcp Database" 120 kubectl_with \
  "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" \
  -n default get databases.databases.demo.kcp.io customer-portal-db

kcp_owner_count="$(kubectl_with \
  "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" -n default \
  get databases.databases.demo.kcp.io customer-portal-db -o json \
  | jq '.metadata.ownerReferences // [] | length')"
if [[ "$kcp_owner_count" -ne 0 ]]; then
  echo "Unexpected owner reference on the kcp Database copy." >&2
  exit 1
fi

echo "Adding the kcp-local Application owner reference manually..."
kcp_application_uid="$(kubectl_with \
  "$KUBECONFIG_DIR/application-provider-virtual-workspace.kubeconfig" -n default \
  get applications.applications.demo.kcp.io customer-portal \
  -o jsonpath='{.metadata.uid}')"
kcp_owner_reference="$(jq -nc --arg uid "$kcp_application_uid" '{
  metadata: {
    ownerReferences: [{
      apiVersion: "applications.demo.kcp.io/v1alpha1",
      kind: "Application",
      name: "customer-portal",
      uid: $uid
    }]
  }
}')"
kubectl_with "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" \
  -n default patch databases.databases.demo.kcp.io customer-portal-db \
  --type=merge -p "$kcp_owner_reference"

echo "Simulating the Database provider publishing observed state in status..."
kubectl_with "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" \
  -n default patch databases.databases.demo.kcp.io customer-portal-db \
  --subresource=status --type=merge \
  -p '{"status":{"phase":"Ready","endpoint":"customer-portal-db.demo.svc:5432"}}'

status_is_synced() {
  [[ "$(kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo \
    get databases.database.internal.demo customer-portal-db \
    -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]
}
wait_for "Database.status to return to Kind" 120 status_is_synced

echo
echo "Observed the expected byOwner behavior:"
echo "  - Database.spec flowed from Kind to kcp using the local owner reference;"
echo "  - the generated kcp copy initially had no owner reference;"
echo "  - after adding its kcp-local owner, Database.status flowed back to Kind."
echo "Run ./demo/show.sh to inspect both sides."
