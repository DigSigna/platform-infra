# Windows y macOS/Linux necesitan un SHELL distinto -- $(OS) es una env var
# que Windows pone sola (Windows_NT) y que make hereda; en macOS/Linux no
# existe, así que cae al bloque else.
#
# Windows: NO `/usr/bin/env bash` ni `bash` a secas.
#   - `/usr/bin/env bash` sólo resuelve si `make` corre dentro de un shell
#     con traducción MSYS (Git Bash). Si corrés `make` directo desde
#     PowerShell/cmd.exe con un make nativo de Windows (ej. GnuWin32),
#     `/usr/bin/env` no existe como ruta real y make cae en silencio a
#     cmd.exe para las recetas -- por eso errores tipo "VAR=valor" no se
#     reconoce como un comando" al usar sintaxis bash (`VAR=valor comando`).
#   - `bash` a secas tampoco alcanza: en Windows 10+, `C:\Windows\System32\bash.exe`
#     (el shim de WSL) suele aparecer en el PATH antes que el bash.exe de Git,
#     así que make puede terminar invocando WSL -- donde `kubectl`/`minikube`/
#     `docker` nativos de Windows no están en el PATH de esa VM.
#   La ruta de abajo es la instalación estándar de Git for Windows; si la
#   tuya vive en otro lado, sobreescribí con `make GIT_BASH=<ruta> ...`.
#
# macOS/Linux: `/bin/bash` existe siempre (en macOS es la 3.2 de Apple,
# vieja pero suficiente -- los scripts de este repo evitan a propósito
# features de bash 4+ como `declare -A`, ver scripts/*.sh).
ifeq ($(OS),Windows_NT)
GIT_BASH ?= C:/Program Files/Git/bin/bash.exe
SHELL := $(GIT_BASH)
else
SHELL := /bin/bash
endif
.SHELLFLAGS := -eu -o pipefail -c

NAMESPACE ?= digsigna
KUBECTL ?= kubectl
MINIKUBE ?= minikube

MINIKUBE_MEMORY ?= 4g
MINIKUBE_CPUS ?= 2
MINIKUBE_DISK ?= 20g
MINIKUBE_DRIVER ?= docker
MINIKUBE_K8S_VERSION ?= v1.37.0
MINIKUBE_ADDONS ?= ingress,metrics-server

GATEWAY_URL ?= http://$(shell $(MINIKUBE) ip 2>/dev/null)

# MySQL descartable del ciclo de prueba (NO la gestionada real de DO) -- ver
# scripts/mysql-local.sh y cloud-init/minikube/Guide.md.
MYSQL_LOCAL_CONTAINER ?= digsigna-mysql-local
MYSQL_LOCAL_VOLUME ?= digsigna-mysql-local-data
MYSQL_LOCAL_PORT ?= 3306

.PHONY: help minikube-up mysql-local-up mysql-local-down k8s-bootstrap k8s-deploy smoke-test teardown

help:
	@echo "Targets:"
	@echo "  minikube-up     - Levanta el nodo de minikube (ver cloud-init/minikube/Guide.md)"
	@echo "  mysql-local-up  - Levanta una MySQL descartable en el host + esquema keycloak (ver cloud-init/minikube/Guide.md)"
	@echo "  mysql-local-down - Borra ese contenedor y su volumen"
	@echo "  k8s-bootstrap   - namespace + secrets + migrations + service-keys + JWT PVC + env-secrets + RBAC/hsm (k8s/README.md, pasos 1-8)"
	@echo "  k8s-deploy      - Deployments en el orden acordado + Ingress (k8s/README.md, pasos 9-11)"
	@echo "  smoke-test      - curl real contra el gateway: login -> CA/certificado -> firmar -> verificar"
	@echo "  teardown        - minikube delete + mysql-local-down, para repetir el ciclo completo limpio"

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
# mysql-local-up/down -- MySQL descartable para el ciclo de prueba (minikube
# no trae la suya). Corre en el host vía `docker run`, no dentro del
# cluster -- ver scripts/mysql-local.sh y cloud-init/minikube/Guide.md para
# cómo minikube la alcanza y qué exportar antes de k8s-bootstrap.
# ---------------------------------------------------------------------------
mysql-local-up:
	MYSQL_LOCAL_CONTAINER=$(MYSQL_LOCAL_CONTAINER) MYSQL_LOCAL_VOLUME=$(MYSQL_LOCAL_VOLUME) MYSQL_LOCAL_PORT=$(MYSQL_LOCAL_PORT) scripts/mysql-local.sh up

mysql-local-down:
	MYSQL_LOCAL_CONTAINER=$(MYSQL_LOCAL_CONTAINER) MYSQL_LOCAL_VOLUME=$(MYSQL_LOCAL_VOLUME) scripts/mysql-local.sh down

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
	$(KUBECTL) rollout status deployment/keycloak -n $(NAMESPACE)
	@echo "== identification-service =="
	$(KUBECTL) apply -f k8s/deployments/identification-service.yaml
	$(KUBECTL) rollout status deployment/identification-service -n $(NAMESPACE)
	@echo "== hsm-service (recién ahora se confirma su rollout -- ver k8s/README.md, 'Orden para aplicar todo desde cero', pasos 9-10: hace fetch SÍNCRONO de JWKS contra identification-service al arrancar, sin fallback, así que hace CrashLoopBackOff normal/esperado hasta este punto, no un fallo) =="
	$(KUBECTL) rollout status deployment/hsm-service -n $(NAMESPACE)
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
# teardown -- borra el nodo de minikube Y la MySQL descartable (mysql-local-down),
# para que el ciclo completo (minikube-up -> mysql-local-up -> k8s-bootstrap
# -> k8s-deploy -> smoke-test -> teardown) se pueda repetir desde cero las
# veces que haga falta. Contra la MySQL gestionada real (DOKS), este target
# no aplica -- esa base no es de este repo y no se borra desde acá.
# ---------------------------------------------------------------------------
teardown: mysql-local-down
	$(MINIKUBE) delete
