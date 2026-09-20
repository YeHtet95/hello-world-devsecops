# Local cluster lifecycle —

KUBECONFIG_PATH ?= $(HOME)/.kube/assessment.yaml
CLUSTER         ?= hello-world
INGRESS_CHART   ?= 4.15.1
ARGOCD_CHART    ?= 10.9.2

export KUBECONFIG = $(KUBECONFIG_PATH)

.PHONY: cluster-up ingress argocd gitops cluster-down kubeconfig argocd-password

## Create the kind cluster (pinned node image, ingress host ports mapped).
cluster-up:
	kind create cluster --config cluster/kind-config.yaml --kubeconfig $(KUBECONFIG_PATH)
	kubectl wait --for=condition=Ready node --all --timeout=120s

## Install ingress-nginx, pinned chart version.
ingress:
	helm upgrade --install ingress-nginx ingress-nginx \
	  --repo https://kubernetes.github.io/ingress-nginx \
	  --version $(INGRESS_CHART) \
	  --namespace ingress-nginx --create-namespace \
	  --values cluster/ingress-nginx-values.yaml \
	  --wait --timeout 5m

## Install Argo CD, pinned chart version.
argocd:
	helm upgrade --install argocd argo-cd \
	  --repo https://argoproj.github.io/argo-helm \
	  --version $(ARGOCD_CHART) \
	  --namespace argocd --create-namespace \
	  --values cluster/argocd-values.yaml \
	  --wait --timeout 10m

## Register the AppProject and Application. After this, the cluster tracks Git.
gitops:
	kubectl apply -f gitops/appproject.yaml -f gitops/application.yaml

## The generated admin password. Never committed; read from the cluster.
argocd-password:
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

## Tear the whole thing down.
cluster-down:
	kind delete cluster --name $(CLUSTER)

## Reminder of how to point a shell at this cluster and not at anything else.
kubeconfig:
	@echo 'export KUBECONFIG=$(KUBECONFIG_PATH)'
