# Canopy — Kubernetes Deployment

Production-style Kubernetes deployment of **Canopy**, a MERN real-time chat app
(Express + Socket.IO + MongoDB + React), running on minikube with a
GitOps delivery pipeline.

- App code: [Canopy-server](https://github.com/OmMaheshwari653/Canopy-server) · [Canopy-client](https://github.com/OmMaheshwari653/Canopy-client)
- This repo: Kubernetes manifests (Kustomize) + Argo CD config — the single source of truth for what runs in the cluster.

---

## Runtime architecture

```
                            ┌──────────────┐
            browser ───────▶│  /etc/hosts  │  canopy.local → 127.0.0.1
                            └──────┬───────┘
                                   │  minikube tunnel (macOS: node IP is not
                                   │  routable from the host)
┌──────────────────────────────────┼──────────────────────────────────────────┐
│ minikube cluster "canopy"        ▼                        containerd · CNI  │
│                     ┌─────────────────────────┐                            │
│                     │  ingress-nginx          │  Host: canopy.local        │
│                     │  (Ingress Controller)   │  longest-prefix routing    │
│                     └───┬────────┬────────┬───┘                            │
│          /api  ─────────┘        │        └───────── /  (catch-all)        │
│          /socket.io ─────────────┘                        │                │
│                   │                                       │                │
│  ┌────────────────▼──────────────────┐   ┌────────────────▼──────────────┐  │
│  │ Service  canopy-server :3000      │   │ Service  canopy-client :80    │  │
│  │ ClusterIP                         │   │ ClusterIP                     │  │
│  └────────────────┬──────────────────┘   └────────────────┬──────────────┘  │
│                   │                                       │                │
│  ┌────────────────▼──────────────────┐   ┌────────────────▼──────────────┐  │
│  │ Deployment  canopy-server         │   │ Deployment  canopy-client     │  │
│  │  replicas 1  (see note below)     │   │  replicas 1–6 via HPA         │  │
│  │  initContainer: wait-for-mongo    │   │  nginx-unprivileged, uid 101  │  │
│  │  startup + readiness + liveness   │   │  readiness + liveness probes  │  │
│  │  runAsNonRoot, RO rootfs, drop ALL│   │  RO rootfs, drop ALL          │  │
│  │  envFrom: ConfigMap + Secret      │   │  PodDisruptionBudget          │  │
│  └────────────────┬──────────────────┘   └───────────────────────────────┘  │
│                   │ mongodb://mongo:27017                                  │
│  ┌────────────────▼──────────────────┐                                     │
│  │ Service  mongo  (headless)        │  clusterIP: None                    │
│  │   → mongo-0.mongo.canopy.svc...   │  stable per-pod DNS                 │
│  └────────────────┬──────────────────┘                                     │
│  ┌────────────────▼──────────────────┐                                     │
│  │ StatefulSet  mongo                │  ordered, stable identity           │
│  │   volumeClaimTemplates            │                                     │
│  │        └─ PVC data-mongo-0 (2Gi)  │  survives pod deletion              │
│  └───────────────────────────────────┘                                     │
│                                                                            │
│  ┌───────────────────────────────────┐   ┌──────────────────────────────┐   │
│  │ ConfigMap canopy-server-config    │   │ Argo CD  (namespace argocd)  │   │
│  │ Secret    canopy-server-secrets   │   │  watches this repo → syncs   │   │
│  │ Secret    canopy-mongo            │   │  prune + selfHeal enabled    │   │
│  └───────────────────────────────────┘   └──────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘
```

## Delivery pipeline

```
  git push (app repo)
        │
        ▼
  ┌─────────────────── GitHub Actions ───────────────────┐
  │ 1. test        server: boots against a real Mongo    │
  │                service container, asserts /healthz   │
  │                and /readyz                           │
  │                client: eslint + vite build           │
  │ 2. build-push  buildx → ghcr.io, tag = main-<sha>    │
  │                GHA layer cache, Trivy CRITICAL/HIGH  │
  │ 3. bump        kustomize edit set image → commit to  │
  │                THIS repo                             │
  └──────────────────────────┬───────────────────────────┘
                             │ git commit (no cluster access needed)
                             ▼
                   ┌──────────────────────┐
                   │  Canopy-k8s (git)    │  ← single source of truth
                   └──────────┬───────────┘
                              │ Argo CD pulls (inside the cluster)
                              ▼
                        cluster converges
```

**Why pull-based:** GitHub never gets credentials to the cluster. The Argo CD
controller runs *inside* the cluster and pulls from Git. That is why this works
against a laptop minikube with no inbound access — and the same reason real
clusters behind a firewall use it.

---

## Repo layout

```
base/                    environment-agnostic manifests
  namespace.yaml
  configmap.yaml
  secret.example.yaml    placeholders only — never real values
  mongo.yaml             headless Service + StatefulSet + PVC template
  server.yaml            Deployment + Service
  client.yaml            Deployment + Service + PDB + HPA
  ingress.yaml
  kustomization.yaml
overlays/
  dev/                   minikube: local image tags, 1 replica, HPA removed,
                         COOKIE_SECURE=false (plain HTTP)
  prod/                  GHCR images pinned by SHA, 3 replicas, TLS via
                         cert-manager, topology spread, COOKIE_SECURE=true
argocd/
  application-dev.yaml   Argo CD Application (auto-sync, prune, selfHeal)
  ingress.yaml           Argo CD UI at argocd.local
scripts/
  create-secrets.sh      builds real Secrets from Canopy-server/.env
```

---

## Engineering decisions worth calling out

**Socket.IO caps horizontal scaling.** `app.js` keeps `userSocketIDs` and
`onlineUsers` as in-process `Map`/`Set`. With two replicas, a user on pod A
cannot reach a user on pod B. So `canopy-server` is pinned to `replicas: 1`
and has **no HPA** — autoscaling it would be a bug, not a feature. The fix is
`@socket.io/redis-adapter`, not more pods. Only the stateless frontend
autoscales.

**Vite bakes the API URL at build time.** `import.meta.env.VITE_SERVER` is
substituted by the bundler, so it cannot come from a ConfigMap. It is a Docker
`ARG`, set per environment in CI. The default points at the Ingress host, which
makes the frontend and API same-origin — removing CORS and cross-site cookie
problems entirely.

**Liveness must not check the database.** `/healthz` (liveness) deliberately
omits the Mongo check; `/readyz` (readiness) includes it. If liveness checked
Mongo, a brief database blip would restart every API pod — turning a
30-second degradation into a much longer outage. Readiness pulls the pod out of
the Service instead, and it rejoins on its own.

**`startupProbe` removes the slow-start dilemma.** Without it you must either
set a long `livenessProbe.initialDelaySeconds` (slow to detect real crashes) or
a short one (restart loops on slow boots). The startup probe gives 60s to boot,
then hands over to the steady-state probes.

**Images are pinned by commit SHA, never `latest`.** With a mutable tag,
"which commit is running?" has no answer and rollback is impossible. CI tags
`main-<short-sha>` and writes that tag into `overlays/prod`, so the Git history
of this repo *is* the deployment history.

**Containers are non-root with a read-only root filesystem.** The official
`nginx` image runs its master process as root, so the frontend uses
`nginx-unprivileged` (uid 101, port 8080). Both containers drop all
capabilities and mount `emptyDir` volumes for the few paths that need writes.
`readOnlyRootFilesystem` is safe on the API because multer uses
`MemoryStorage` — verified, not assumed.

**Secrets are not in Git.** Only `base/secret.example.yaml` with placeholders is
committed; `scripts/create-secrets.sh` builds the real ones. Kubernetes Secrets
are base64, which is encoding, not encryption. For a fully declarative GitOps
flow the next step is Sealed Secrets or External Secrets Operator.

---

## Running it locally

```bash
# 1. cluster
minikube start -p canopy --driver=docker --container-runtime=containerd \
  --cpus=4 --memory=6144 --disk-size=25g --addons=ingress,metrics-server

# 2. images (containerd ignores the Docker image store, so `minikube
#    docker-env` does NOT work — load explicitly)
docker build -t canopy-server:dev ../Canopy-server
docker build -t canopy-client:dev --build-arg VITE_SERVER=http://canopy.local ../Canopy-client
minikube -p canopy image load canopy-server:dev
minikube -p canopy image load canopy-client:dev

# 3. secrets (not in Git)
./scripts/create-secrets.sh

# 4. deploy
kubectl apply -k overlays/dev

# 5. reach it (macOS: the node IP is not routable from the host)
echo "127.0.0.1  canopy.local argocd.local" | sudo tee -a /etc/hosts
minikube tunnel -p canopy          # keep running

open http://canopy.local
```

### GitOps mode

```bash
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side                                  # CRD exceeds the 256KB
                                                 # last-applied annotation limit
kubectl apply -f argocd/ingress.yaml
kubectl apply -f argocd/application-dev.yaml

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d     # admin password
open http://argocd.local                         # user: admin
```

Then prove self-healing:

```bash
kubectl scale deploy/canopy-client -n canopy --replicas=5
kubectl get pods -n canopy -w    # Argo CD reverts it to the Git-declared count
```
