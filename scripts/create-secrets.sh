#!/usr/bin/env bash
# Creates the Kubernetes Secrets for Canopy.
# Values come from Canopy-server/.env, plus a Mongo password generated here.
# This script never prints any secret value.
set -euo pipefail

NS=canopy
ENV_FILE="${1:-../Canopy-server/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at: $ENV_FILE" >&2
  exit 1
fi

# Read one key from .env (everything after the first '=', quotes stripped)
get() {
  local v
  v="$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  v="${v#"${v%%[![:space:]]*}"}"   # strip leading whitespace
  v="${v%"${v##*[![:space:]]}"}"   # strip trailing whitespace
  v="${v%\"}"; v="${v#\"}"          # strip quotes
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

MONGO_USER=canopy

# Idempotent: reuse the existing password if the Secret is already there,
# otherwise generate one. Otherwise every run would change the password while
# the user stored on Mongo's disk stays the same -> authentication failures.
if kubectl get secret canopy-mongo -n "$NS" >/dev/null 2>&1; then
  MONGO_PASS="$(kubectl get secret canopy-mongo -n "$NS" -o jsonpath='{.data.MONGO_ROOT_PASSWORD}' | base64 -d)"
  echo "-> Reusing the existing Mongo password"
else
  # Note: `tr </dev/urandom | head -c 32` does NOT work here - head closes the
  # pipe, tr gets SIGPIPE, and `set -o pipefail` kills the script.
  MONGO_PASS="$(openssl rand -hex 16)"
  echo "-> Generated a new Mongo password"
fi

# The server connects to the in-cluster Mongo, not to Atlas.
# 'mongo' is the headless Service name, resolved by CoreDNS.
# authSource=admin is required because the root user lives in the admin db.
MONGO_URI="mongodb://${MONGO_USER}:${MONGO_PASS}@mongo:27017/Canopy?authSource=admin"

# `--dry-run=client -o yaml | kubectl apply` is the standard 'upsert' trick.
# Running plain `kubectl create secret` twice fails with "already exists".
kubectl create secret generic canopy-mongo -n "$NS" \
  --from-literal=MONGO_ROOT_USERNAME="$MONGO_USER" \
  --from-literal=MONGO_ROOT_PASSWORD="$MONGO_PASS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret generic canopy-server-secrets -n "$NS" \
  --from-literal=MONGO_URI="$MONGO_URI" \
  --from-literal=JWT_SECRET="$(get JWT_SECRET)" \
  --from-literal=ADMIN_SECRET_KEY="$(get ADMIN_SECRET_KEY)" \
  --from-literal=CLOUDINARY_CLOUD_NAME="$(get CLOUDINARY_CLOUD_NAME)" \
  --from-literal=CLOUDINARY_API_KEY="$(get CLOUDINARY_API_KEY)" \
  --from-literal=CLOUDINARY_API_SECRET="$(get CLOUDINARY_API_SECRET)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "-> Secrets ready (no values printed):"
kubectl get secret canopy-mongo canopy-server-secrets -n "$NS"
