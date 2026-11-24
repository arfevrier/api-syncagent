#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "== Customer view in kcp =="
kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" get apibindings
kubectl_with "$KUBECONFIG_DIR/customer.kubeconfig" get -A \
  applications.applications.demo.kcp.io,databases.databases.demo.kcp.io

echo
echo "== Application provider virtual workspace =="
kubectl_with "$KUBECONFIG_DIR/application-provider-virtual-workspace.kubeconfig" \
  get applications --all-namespaces

echo
echo "== Database provider virtual workspace =="
kubectl_with "$KUBECONFIG_DIR/database-provider-virtual-workspace.kubeconfig" \
  get databases --all-namespaces

echo
echo "== Kind service cluster =="
kubectl_with "$KUBECONFIG_DIR/kind.kubeconfig" -n demo get applications,databases -o yaml
