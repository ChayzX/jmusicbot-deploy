#!/usr/bin/env bash
set -euo pipefail

site=${1:-}
case "$site" in
  home) expected_node=${EXPECTED_KUBE_NODE:-minecraftmachine} ;;
  oracle) expected_node=${EXPECTED_KUBE_NODE:-pantry-bot-oracle} ;;
  *) echo "usage: $0 home|oracle" >&2; exit 2 ;;
esac

kubectl_bin=${KUBECTL_BIN:-kubectl}
if nodes_json=$("$kubectl_bin" get nodes -o json 2>/dev/null); then
  if ! jq -e --arg expected "$expected_node" '
    any(.items[]?; .metadata.name == $expected and
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ' <<<"$nodes_json" >/dev/null; then
    echo "refusing mutation: Kubernetes target is not a Ready $site cluster ($expected_node)" >&2
    exit 1
  fi
  echo "kube_target=$site node=$expected_node"
  exit 0
fi

# Namespaced ci-deploy identities intentionally cannot list cluster-scoped
# Nodes. In that case, prove that the scoped context reaches a live workload
# instead of widening RBAC just for this guard.
deployments_json=$("$kubectl_bin" get deployments -o json 2>/dev/null) || {
  echo "refusing mutation: cannot inspect target cluster or scoped deployments" >&2
  exit 1
}
if ! jq -e 'any(.items[]?; (.metadata.name // "") != "")' <<<"$deployments_json" >/dev/null; then
  echo "refusing mutation: scoped target has no Deployment identity" >&2
  exit 1
fi
echo "kube_target=$site scoped_deployment=present"
