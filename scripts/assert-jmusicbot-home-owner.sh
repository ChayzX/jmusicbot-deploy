#!/usr/bin/env bash
set -euo pipefail

# The JMusicBot readiness probe is ownership-aware: a site that does not hold
# the jmusicbot witness lease must remain NotReady.  Refuse routine home
# mutations unless the current Deployment has a Ready replica.  This is a
# fail-closed preflight; it does not acquire, renew, or transfer ownership.
kubectl_bin=${KUBECTL_BIN:-kubectl}
namespace=${JMUSICBOT_NAMESPACE:-jmusicbot}
deployment=${JMUSICBOT_DEPLOYMENT:-jmusicbot}

status="$($kubectl_bin -n "$namespace" get deployment "$deployment" -o json)"
replicas=$(jq -r '.spec.replicas // 0' <<<"$status")
ready=$(jq -r '.status.readyReplicas // 0' <<<"$status")
available=$(jq -r '.status.availableReplicas // 0' <<<"$status")

if [[ "$replicas" =~ ^[0-9]+$ && "$ready" == "$replicas" && "$available" == "$replicas" && "$replicas" -gt 0 ]]; then
  echo "jmusicbot_home_owner=ready replicas=$replicas"
  exit 0
fi

echo "refusing mutation: home JMusicBot is not Ready/ownership-gated (replicas=$replicas ready=$ready available=$available)" >&2
exit 3
