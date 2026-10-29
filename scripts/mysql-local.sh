#!/usr/bin/env bash
# MySQL descartable para el ciclo de prueba de minikube -- NO es la MySQL
# gestionada real (esa vive en DigitalOcean, ver terraform/modules/database/).
# minikube no trae su propia base: mysql-secrets/keycloak-secrets/
# migrations-job necesitan algo real contra qué correr, y este contenedor
# (corrido en el host con `docker run`, no dentro del cluster) es ese algo
# para desarrollo/pruebas local. Mismos valores que
# hsm-service/docker-compose.dev.yml usa para su propio servicio `mysql`
# (imagen, env vars, flag de log-bin) -- no inventados acá.
#
# Uso:
#   scripts/mysql-local.sh up      # crea/arranca el contenedor + espera a que responda + crea el esquema keycloak
#   scripts/mysql-local.sh down    # borra el contenedor y su volumen -- ciclo siguiente arranca con una base vacía
#
# Ver cloud-init/minikube/Guide.md para cómo minikube (driver docker)
# alcanza este contenedor desde dentro del cluster.

set -euo pipefail

CONTAINER="${MYSQL_LOCAL_CONTAINER:-digsigna-mysql-local}"
VOLUME="${MYSQL_LOCAL_VOLUME:-digsigna-mysql-local-data}"
PORT="${MYSQL_LOCAL_PORT:-3306}"
ROOT_PASSWORD="${MYSQL_LOCAL_ROOT_PASSWORD:-root}"
DATABASE="${MYSQL_LOCAL_DATABASE:-digsigna}"
DB_USER="${MYSQL_LOCAL_USER:-digsigna}"
DB_PASSWORD="${MYSQL_LOCAL_PASSWORD:-digsigna}"
# Mismas credenciales que después van al Secret keycloak-secrets vía
# scripts/bootstrap-manual-secrets.sh (KEYCLOAK_DB_USERNAME/KEYCLOAK_DB_PASSWORD)
# -- tienen que coincidir con lo que se crea acá, o Keycloak no puede
# conectarse a su propio esquema.
KEYCLOAK_DB_USERNAME="${KEYCLOAK_DB_USERNAME:-keycloak}"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-keycloak}"
IMAGE="mysql:8.4"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: falta '$1' en el PATH." >&2
    exit 1
  fi
}
require_cmd docker

cmd_up() {
  docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
      echo "== '$CONTAINER' ya está corriendo =="
    else
      docker start "$CONTAINER" >/dev/null
      echo "== '$CONTAINER' ya existía (volumen '$VOLUME' preservado), reiniciado =="
    fi
  else
    docker run -d \
      --name "$CONTAINER" \
      -e MYSQL_ROOT_PASSWORD="$ROOT_PASSWORD" \
      -e MYSQL_DATABASE="$DATABASE" \
      -e MYSQL_USER="$DB_USER" \
      -e MYSQL_PASSWORD="$DB_PASSWORD" \
      -p "$PORT:3306" \
      -v "$VOLUME:/var/lib/mysql" \
      "$IMAGE" --log-bin-trust-function-creators=ON >/dev/null
    echo "== '$CONTAINER' creado (imagen $IMAGE, puerto $PORT, volumen '$VOLUME') =="
  fi

  printf 'Esperando a que MySQL responda'
  attempts=0
  until docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PASSWORD" -e 'SELECT 1' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      echo
      echo "Error: MySQL no respondió tras 5 minutos -- 'docker logs $CONTAINER' para diagnosticar." >&2
      exit 1
    fi
    printf '.'
    sleep 5
  done
  echo ' OK'

  echo "== Creando esquema 'keycloak' + su usuario (pre-requisito de keycloak-secrets, ver k8s/README.md) =="
  docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PASSWORD" -e "
    CREATE DATABASE IF NOT EXISTS keycloak;
    CREATE USER IF NOT EXISTS '$KEYCLOAK_DB_USERNAME'@'%' IDENTIFIED BY '$KEYCLOAK_DB_PASSWORD';
    GRANT ALL PRIVILEGES ON keycloak.* TO '$KEYCLOAK_DB_USERNAME'@'%';
    FLUSH PRIVILEGES;
  "

  echo
  echo "MySQL descartable lista, publicada en el puerto $PORT del host."
  echo "Antes de 'make k8s-bootstrap' (ver cloud-init/minikube/Guide.md para <HOST>):"
  echo "  export MYSQL_CONNECTION_STRING=\"mysql://$DB_USER:$DB_PASSWORD@tcp(<HOST>:$PORT)/$DATABASE?parseTime=true\""
  echo "  export KEYCLOAK_DB_HOST=<HOST>"
  echo "  export KEYCLOAK_DB_USERNAME=$KEYCLOAK_DB_USERNAME"
  echo "  export KEYCLOAK_DB_PASSWORD=$KEYCLOAK_DB_PASSWORD"
}

cmd_down() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  echo "== '$CONTAINER' y el volumen '$VOLUME' eliminados (o ya no existían) =="
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  *)
    echo "Uso: $0 up|down" >&2
    exit 1
    ;;
esac
