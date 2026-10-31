# Everyday commands - shortcuts around the kubectl/minikube calls.
PROFILE  ?= canopy
NS       ?= canopy
OVERLAY  ?= overlays/dev
SERVER   ?= ../Canopy-server
CLIENT   ?= ../Canopy-client
API_URL  ?= http://canopy.local

.PHONY: help cluster images secrets deploy status logs tunnel argocd clean diff

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

cluster: ## Create the minikube cluster (with ingress + metrics-server)
	minikube start -p $(PROFILE) --driver=docker --container-runtime=containerd \
	  --cpus=4 --memory=6144 --disk-size=25g --addons=ingress,metrics-server

images: ## Build both images and side-load them into the cluster
	docker build -t canopy-server:dev $(SERVER)
	docker build -t canopy-client:dev --build-arg VITE_SERVER=$(API_URL) $(CLIENT)
	minikube -p $(PROFILE) image load canopy-server:dev
	minikube -p $(PROFILE) image load canopy-client:dev

secrets: ## Create the Secrets from .env (never committed to Git)
	./scripts/create-secrets.sh

deploy: ## Apply the overlay and wait for the rollout
	kubectl apply -k $(OVERLAY)
	kubectl rollout status deploy/canopy-client -n $(NS) --timeout=180s
	kubectl rollout status deploy/canopy-server -n $(NS) --timeout=180s

diff: ## Show what differs between the cluster and Git
	kubectl diff -k $(OVERLAY) || true

status: ## Everything at a glance
	@kubectl get deploy,sts,svc,ingress,hpa,pdb,pvc -n $(NS)
	@echo; kubectl get pods -n $(NS) -o wide

logs: ## Follow the server logs
	kubectl logs -n $(NS) deploy/canopy-server -c server -f --tail=50

tunnel: ## Make canopy.local reachable (needs root, must keep running)
	minikube tunnel -p $(PROFILE)

argocd: ## Install Argo CD and apply the Application
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side -f \
	  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	kubectl wait --for=condition=Available deploy --all -n argocd --timeout=600s
	kubectl apply -f argocd/ingress.yaml
	kubectl apply -f argocd/application-dev.yaml

clean: ## Delete the canopy namespace (including PVCs - data is lost)
	kubectl delete -k $(OVERLAY) --ignore-not-found
	kubectl delete pvc -n $(NS) --all --ignore-not-found
