# Local cluster lifecycle —

KUBECONFIG_PATH ?= $(HOME)/.kube/assessment.yaml
CLUSTER         ?= hello-world
INGRESS_CHART   ?= 4.15.1

export KUBECONFIG = $(KUBECONFIG_PATH)

.PHONY: cluster-up ingress cluster-down kubeconfig

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

## Tear the whole thing down.
cluster-down:
	kind delete cluster --name $(CLUSTER)

## Reminder of how to point a shell at this cluster and not at anything else.
kubeconfig:
	@echo 'export KUBECONFIG=$(KUBECONFIG_PATH)'
