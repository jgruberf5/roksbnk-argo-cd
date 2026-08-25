SHELL := /bin/bash
CHART := charts/bnk-workspace
OVERLAYS := kind-stub bnkconn bnkdisco sm-cli
RENDER := .rendered
REPO_MOUNT ?= $(HOME)/.cache/roksbnk-argo-cd/kind-repo
K8S_VERSION ?= 1.31.0

.PHONY: lint template validate bootstrap-render kind-up kind-publish kind-demo kind-down clean

lint: ## helm lint every overlay
	@for o in $(OVERLAYS); do echo "== $$o"; helm lint $(CHART) -f apps/overlays/$$o/values.yaml; done
	@echo "== lifecycle=down"; helm lint $(CHART) -f apps/overlays/bnkconn/values.yaml --set lifecycle=down
	@echo "== line=2.3 (cwc-guard)"; helm lint $(CHART) -f apps/overlays/bnkconn/values.yaml --set line=2.3

template: ## render every overlay into $(RENDER)/<overlay>.yaml
	@mkdir -p $(RENDER)
	@for o in $(OVERLAYS); do helm template bnk-$$o $(CHART) -f apps/overlays/$$o/values.yaml > $(RENDER)/$$o.yaml; echo "rendered $(RENDER)/$$o.yaml"; done
	@helm template bnk-down $(CHART) -f apps/overlays/bnkconn/values.yaml --set lifecycle=down > $(RENDER)/bnkconn-down.yaml
	@helm template bnk-23 $(CHART) -f apps/overlays/bnkconn/values.yaml --set line=2.3 > $(RENDER)/bnkconn-23.yaml

validate: template ## kubeconform against the Kubernetes schemas (+ Argo CD / ESO CRDs)
	@kubeconform -strict -summary -kubernetes-version $(K8S_VERSION) \
	  -schema-location default \
	  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
	  $(RENDER)/*.yaml apps/*.yaml bootstrap/appproject-bnk.yaml bootstrap/upstream/*.yaml

bootstrap-render: ## re-embed bootstrap/health/bnk-status.lua into the argocd-cm and ArgoCD CR files
	@python3 hack/embed-lua.py

kind-up: ## local Argo CD + git server + stub runner on kind
	@REPO_MOUNT=$(REPO_MOUNT) hack/kind/up.sh

kind-publish: ## push HEAD to the in-cluster git server
	@REPO_MOUNT=$(REPO_MOUNT) hack/kind/publish.sh

kind-demo: kind-publish ## create + sync the stub Application and wait for bnk up
	@hack/kind/demo.sh create && hack/kind/demo.sh sync && hack/kind/demo.sh wait

kind-down:
	@kind delete cluster --name bnk-argocd

clean:
	@rm -rf $(RENDER)

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-18s %s\n", $$1, $$2}'
