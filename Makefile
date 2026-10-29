SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

NAMESPACE ?= digsigna
KUBECTL ?= kubectl
MINIKUBE ?= minikube

MINIKUBE_MEMORY ?= 4g
MINIKUBE_CPUS ?= 2
MINIKUBE_DISK ?= 20g
MINIKUBE_DRIVER ?= docker
MINIKUBE_K8S_VERSION ?= v1.28.0
MINIKUBE_ADDONS ?= ingress,metrics-server

GATEWAY_URL ?= http://$(shell $(MINIKUBE) ip 2>/dev/null)

.PHONY: help minikube-up k8s-bootstrap k8s-deploy smoke-test teardown

help:
	@echo "Targets:"
	@echo "  minikube-up     - Levanta el nodo de minikube (ver cloud-init/minikube/Guide.md)"
	@echo "  k8s-bootstrap   - namespace + secrets + migrations + service-keys + JWT PVC + env-secrets + RBAC/hsm (k8s/README.md, pasos 1-8)"
	@echo "  k8s-deploy      - Deployments en el orden acordado + Ingress (k8s/README.md, pasos 9-11)"
	@echo "  smoke-test      - curl real contra el gateway: login -> CA/certificado -> firmar -> verificar"
	@echo "  teardown        - minikube delete, para repetir el ciclo completo limpio"

# ---------------------------------------------------------------------------
# minikube-up -- ver cloud-init/minikube/Guide.md, sección "Init node".
# ---------------------------------------------------------------------------
minikube-up:
	$(MINIKUBE) start \
		--memory=$(MINIKUBE_MEMORY) \
		--cpus=$(MINIKUBE_CPUS) \
		--disk-size=$(MINIKUBE_DISK) \
		--driver=$(MINIKUBE_DRIVER) \
		--kubernetes-version=$(MINIKUBE_K8S_VERSION) \
		--addons=$(MINIKUBE_ADDONS)
	$(MINIKUBE) status
	$(KUBECTL) get nodes

# ---------------------------------------------------------------------------
# k8s-bootstrap -- k8s/README.md, "Orden para aplicar todo desde cero",
# pasos 1-8 (namespace -> ghcr-creds -> mysql/hsm/keycloak-secrets a mano ->
# migrations-job -> generate-service-keys.sh + audit-service-producer-keys
# a mano -> JWT PVC -> apply-service-env-secrets.sh -> RBAC/ConfigMaps/PVC
# de hsm). Los Deployments/Ingress (pasos 9-11) son k8s-deploy, no esto.
# ---------------------------------------------------------------------------
k8s-bootstrap:
	@echo "== 1/8: namespace =="
	$(KUBECTL) apply -f k8s/namespace.yaml
	@echo "== 2-3/8: ghcr-creds, mysql-secrets, hsm-secrets, keycloak-secrets (mecanismo 3, ver k8s/README.md) =="
	NAMESPACE=$(NAMESPACE) scripts/bootstrap-manual-secrets.sh
	@echo "== 4/8: migrations-job =="
	$(KUBECTL) delete job migrations-job -n $(NAMESPACE) --ignore-not-found
	$(KUBECTL) apply -f k8s/jobs/migrations-job.yaml
	$(KUBECTL) wait --for=condition=complete --timeout=180s job/migrations-job -n $(NAMESPACE)
	@echo "== 5/8: generate-service-keys.sh (audit-service-producer-keys se aplica a mano, ver k8s/README.md) =="
	NAMESPACE=$(NAMESPACE) scripts/generate-service-keys.sh
	@echo "== 6/8: PVC de JWT keys de identification-service =="
	$(KUBECTL) apply -f k8s/storage/identification-service-jwt-keys-pvc.yaml
	@echo "== 7/8: apply-service-env-secrets.sh (los 7 servicios) =="
	NAMESPACE=$(NAMESPACE) scripts/apply-service-env-secrets.sh
	@echo "== 8/8: RBAC + ConfigMaps + PVC de hsm-service =="
	$(KUBECTL) apply -f k8s/rbac/hsm-service-rbac.yaml -f k8s/configmaps/ -f k8s/storage/softhsm-pvc.yaml

# ---------------------------------------------------------------------------
# k8s-deploy -- k8s/README.md, pasos 9-11: Keycloak -> hsm-service/redis ->
# identification-service -> certificate-service/audit-service ->
# signing-service/verification-service -> gateway-service -> Ingress.
# ---------------------------------------------------------------------------
k8s-deploy:
	@echo "== Keycloak + hsm-service + redis =="
	$(KUBECTL) apply -f k8s/deployments/redis-gateway.yaml -f k8s/deployments/hsm-service.yaml -f k8s/deployments/keycloak.yaml
	$(KUBECTL) rollout status deployment/redis-gateway -n $(NAMESPACE)
	$(KUBECTL) rollout status deployment/hsm-service -n $(NAMESPACE)
	$(KUBECTL) rollout status deployment/keycloak -n $(NAMESPACE)
	@echo "== identification-service =="
	$(KUBECTL) apply -f k8s/deployments/identification-service.yaml
	$(KUBECTL) rollout status deployment/identification-service -n $(NAMESPACE)
	@echo "== certificate-service + audit-service =="
	$(KUBECTL) apply -f k8s/deployments/certificate-service.yaml -f k8s/deployments/audit-service.yaml
	$(KUBECTL) rollout status deployment/certificate-service -n $(NAMESPACE)
	$(KUBECTL) rollout status deployment/audit-service -n $(NAMESPACE)
	@echo "== signing-service + verification-service =="
	$(KUBECTL) apply -f k8s/deployments/signing-service.yaml -f k8s/deployments/verification-service.yaml
	$(KUBECTL) rollout status deployment/signing-service -n $(NAMESPACE)
	$(KUBECTL) rollout status deployment/verification-service -n $(NAMESPACE)
	@echo "== gateway-service =="
	$(KUBECTL) apply -f k8s/deployments/gateway-service.yaml
	$(KUBECTL) rollout status deployment/gateway-service -n $(NAMESPACE)
	@echo "== Ingress (requiere ingress-nginx -- ya viene del addon de minikube-up) =="
	$(KUBECTL) apply -f k8s/ingress/gateway-ingress.yaml

# ---------------------------------------------------------------------------
# smoke-test -- curl real: login -> CA/certificado -> firmar -> verificar.
# Ver scripts/smoke-test.sh para el detalle del flujo y por qué pasa por una
# Organization en el medio.
# ---------------------------------------------------------------------------
smoke-test:
	GATEWAY_URL=$(GATEWAY_URL) scripts/smoke-test.sh

# ---------------------------------------------------------------------------
# teardown -- borra el nodo de minikube para repetir el ciclo completo.
# No borra la MySQL externa que mysql-secrets referencia (no es de este
# repo) -- ver scripts/smoke-test.sh para cómo maneja repetir el bootstrap
# contra la misma base entre ciclos.
# ---------------------------------------------------------------------------
teardown:
	$(MINIKUBE) delete
