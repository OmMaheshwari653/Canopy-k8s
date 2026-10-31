#!/usr/bin/env bash
# Converts the live Kubernetes Secrets into SealedSecrets that are safe to commit.
#
# A SealedSecret is encrypted with the controller's PUBLIC key, so only the
# controller running in this cluster can decrypt it. That means the encrypted
# file can live in a public Git repo: the private key never leaves the cluster.
#
# This closes the last gap in the GitOps story. Without it, Git alone cannot
# rebuild the application - someone has to run create-secrets.sh by hand.
#
# This script never prints a secret value.
set -euo pipefail

NS=canopy
CONTROLLER_NAME=sealed-secrets-controller
CONTROLLER_NS=kube-system
# SealedSecrets are sealed against name AND namespace, so they belong to one
# environment only - hence the overlay directory, not base/.
OUT_DIR=overlays/dev

for NAME in canopy-mongo canopy-server-secrets; do
  if ! kubectl get secret "$NAME" -n "$NS" >/dev/null 2>&1; then
    echo "ERROR: secret $NAME not found in namespace $NS. Run create-secrets.sh first." >&2
    exit 1
  fi

  # Strip the live-object metadata before sealing.
  #
  # This matters for more than tidiness: because the Secrets were created with
  # `kubectl apply`, their metadata carries a
  # kubectl.kubernetes.io/last-applied-configuration annotation that contains
  # the values themselves. kubeseal copies annotations into the SealedSecret
  # template, so leaving it in would write the plaintext straight into a file
  # meant to be committed.
  kubectl get secret "$NAME" -n "$NS" -o json \
    | python3 -c '
import json, sys
s = json.load(sys.stdin)
json.dump({
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": s["metadata"]["name"], "namespace": s["metadata"]["namespace"]},
    "type": s.get("type", "Opaque"),
    "data": s["data"],
}, sys.stdout)
' \
    | kubeseal \
        --controller-name "$CONTROLLER_NAME" \
        --controller-namespace "$CONTROLLER_NS" \
        --format yaml \
    > "$OUT_DIR/sealedsecret-${NAME}.yaml"

  echo "-> $OUT_DIR/sealedsecret-${NAME}.yaml"
done

echo
echo "These files are encrypted and safe to commit."
echo "They are referenced from overlays/dev/kustomization.yaml."
