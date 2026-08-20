#!/usr/bin/env bash
# Unseal every OpenBao replica from the init-keys Secret.
#
# WHY THIS EXISTS
#   Under Shamir (no auto-unseal), ANY pod restart seals the node — a node
#   reboot, an eviction, a `kubectl delete pod` to pick up a config change.
#   Nothing in the cluster unseals it again: the bootstrap Job only runs on
#   `helm upgrade`, so a restart outside an upgrade leaves the cluster sealed
#   until a human intervenes. That is inherent to Shamir, not a chart bug.
#
#   The real fix is auto-unseal (see docs/SEAL.md). Until then, this.
#
# THIS READS THE UNSEAL KEYS FROM THE CLUSTER. It only works while the
# init-keys Secret still exists. Once you have moved the keys off-cluster and
# deleted that Secret — which you should — pass them in instead:
#
#   UNSEAL_KEYS="key1 key2 key3" ./scripts/unseal.sh
set -euo pipefail

NS="${NS:-openbao}"
RELEASE="${RELEASE:-openbao}"
SECRET="${SECRET:-${RELEASE}-init-keys}"
THRESHOLD="${THRESHOLD:-3}"

keys=()
if [[ -n "${UNSEAL_KEYS:-}" ]]; then
  read -ra keys <<< "$UNSEAL_KEYS"
  echo "==> using keys from \$UNSEAL_KEYS"
else
  if ! kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
    echo "ERROR: Secret ${NS}/${SECRET} does not exist." >&2
    echo "       That is the correct state once the keys have been moved off-cluster." >&2
    echo "       Re-run with: UNSEAL_KEYS=\"k1 k2 k3\" $0" >&2
    exit 1
  fi
  echo "==> reading unseal keys from ${NS}/${SECRET}"
  for i in $(seq 1 "$THRESHOLD"); do
    k="$(kubectl -n "$NS" get secret "$SECRET" -o "jsonpath={.data.unseal-key-$i}" 2>/dev/null | base64 -d || true)"
    [[ -n "$k" ]] && keys+=("$k")
  done
fi

if (( ${#keys[@]} < THRESHOLD )); then
  echo "ERROR: found ${#keys[@]} keys, need ${THRESHOLD}." >&2
  exit 1
fi

pods="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=openbao,component=server" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

for pod in $pods; do
  sealed="$(kubectl -n "$NS" exec "$pod" -c openbao -- sh -c 'bao status -tls-skip-verify' 2>/dev/null \
            | awk '/^Sealed/{print $2}' || true)"
  if [[ "$sealed" != "true" ]]; then
    echo "==> ${pod}: already unsealed"
    continue
  fi
  echo "==> ${pod}: unsealing"
  for k in "${keys[@]}"; do
    kubectl -n "$NS" exec "$pod" -c openbao -- sh -c "bao operator unseal -tls-skip-verify '$k'" >/dev/null
  done
  kubectl -n "$NS" exec "$pod" -c openbao -- sh -c 'bao status -tls-skip-verify' 2>/dev/null \
    | grep -E '^(Sealed|HA Mode)' | sed 's/^/    /'
done
echo "==> done"
