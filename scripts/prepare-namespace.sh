#!/usr/bin/env bash
# Prerequisites this Helm chart cannot create for itself.
#
#   1. The namespace, with Pod Security labels. Helm's --create-namespace makes
#      one with no labels at all, which is the wrong default for OpenBao.
#   2. A copy of the S3 credentials. Secrets are namespaced, so the snapshot
#      agent cannot read storage/garage-s3-credentials from the openbao
#      namespace -- it needs its own copy.
#
# Needs cluster-admin for the namespace labels. On heathernetes that means
# KUBECONFIG=~/.kube/config-admin (platform-admin cannot write RBAC or label
# namespaces).
set -euo pipefail

NS="${NS:-openbao}"
SRC_NS="${SRC_NS:-storage}"
SRC_SECRET="${SRC_SECRET:-garage-s3-credentials}"

echo "==> namespace ${NS}"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# OpenBao runs fine under `restricted`; there is no reason to weaken it.
kubectl label ns "$NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

echo "==> copying ${SRC_NS}/${SRC_SECRET} -> ${NS}/${SRC_SECRET}"
if ! kubectl -n "$SRC_NS" get secret "$SRC_SECRET" >/dev/null 2>&1; then
  echo "    ERROR: ${SRC_NS}/${SRC_SECRET} does not exist." >&2
  echo "    The snapshot agent needs AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY." >&2
  exit 1
fi

# Only the two keys the agent actually reads. The source Secret also carries
# AWS_ENDPOINT_URL and AWS_DEFAULT_REGION, which it has no use for.
AKID="$(kubectl -n "$SRC_NS" get secret "$SRC_SECRET" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
SAK="$(kubectl -n "$SRC_NS" get secret "$SRC_SECRET" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"

kubectl -n "$NS" create secret generic "$SRC_SECRET" \
  --from-literal=AWS_ACCESS_KEY_ID="$AKID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SAK" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> done"
kubectl -n "$NS" get secret "$SRC_SECRET"
