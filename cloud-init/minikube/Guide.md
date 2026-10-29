# Guide: minikube para el ciclo de prueba local

Referencia para el target `minikube-up` del `Makefile` de este repo (y para
el resto del ciclo: `mysql-local-up` → `k8s-bootstrap` → `k8s-deploy` →
`smoke-test` → `teardown`). No sustituye `k8s/README.md` (que documenta el
orden real de aplicación contra cualquier cluster, minikube o DOKS) --
esto es específico de correr ese mismo flujo en minikube, en el host local.

## Prerequisito en Windows: `make` necesita el `bash.exe` correcto

(Esto es específico de Windows -- en macOS/Linux `make` ya usa `/bin/bash`
sin este problema, ver el `Makefile` raíz.)

El `Makefile` fija el `SHELL` de la receta a la ruta de Git for Windows
(`C:/Program Files/Git/bin/bash.exe`, override con `make GIT_BASH=<ruta>
...` si tu instalación vive en otro lado) en vez de depender del PATH,
porque dos cosas pueden salir mal si se deja que el PATH decida:

- Si corrés `make` desde PowerShell/cmd.exe con un `make` nativo de Windows
  (ej. GnuWin32) y ese `bash.exe` no está en el PATH en absoluto, `make` cae
  en silencio a `cmd.exe` para ejecutar las recetas -- señal: errores tipo
  `"VAR=valor" no se reconoce como un comando interno o externo` en vez de
  que el target corra.
- Si está en el PATH pero `C:\Windows\System32\bash.exe` (el shim de WSL)
  aparece antes, `make` puede terminar invocando WSL en vez de Git Bash --
  donde los binarios nativos de Windows (`kubectl`/`minikube`/`docker`) no
  están en el PATH de esa VM.

Si pese a la ruta fija algo falla, confirmar `& "C:\Program Files\Git\bin\bash.exe" --version`
desde esa misma consola, o correr `make` directo desde Git Bash.

## Init node

```bash
minikube start \
  --memory=4g \
  --cpus=2 \
  --disk-size=20g \
  --driver=docker \
  --kubernetes-version=v1.39.0 \
  --addons=ingress,metrics-server

# Verificar
minikube status
kubectl get nodes
```

`--kubernetes-version` tiene que coincidir con la que ya use un cluster
`minikube` existente en la máquina -- minikube no permite "bajar" la
versión de un cluster ya creado (`K8S_DOWNGRADE_UNSUPPORTED`). Si da ese
error, o `minikube start --kubernetes-version=v1.39.0` (versión vieja,
probada al escribir esto) contra un cluster existente, el mensaje de error
mismo imprime la versión real del cluster -- usar esa.

## Por qué minikube necesita una MySQL aparte

minikube no trae su propia base de datos. `k8s/shared-secrets/mysql-secrets.secret.yaml`,
`k8s/shared-secrets/keycloak-secrets.secret.yaml` y `k8s/jobs/migrations-job.yaml`
asumen una MySQL real alcanzable por DSN -- en DOKS (producción) es la
managed de DigitalOcean (`terraform/modules/database/`); para probar el
ciclo completo en minikube hace falta una descartable.

`make mysql-local-up` (que corre `scripts/mysql-local.sh up`) levanta un
contenedor `mysql:8.4` **en el host, con `docker run` -- no dentro del
cluster de minikube**, con las mismas credenciales que
`hsm-service/docker-compose.dev.yml` ya usa para desarrollo
(`MYSQL_DATABASE=digsigna`, `MYSQL_USER=digsigna`,
`MYSQL_PASSWORD=digsigna`), en un volumen nombrado (`digsigna-mysql-local-data`
por default) para que sobreviva si el contenedor se reinicia dentro del
mismo ciclo. Como parte del mismo paso crea también el esquema `keycloak` +
su usuario (pre-requisito que ya señala el comentario de cabecera de
`keycloak-secrets.secret.yaml`) -- contra la managed real esto se hace a
mano una sola vez; contra la descartable hay que rehacerlo cada vez que se
recrea, así que el script lo deja automatizado.

`make mysql-local-down` (`scripts/mysql-local.sh down`) borra el contenedor
**y el volumen** -- a propósito, para que cada ciclo completo
(`teardown` lo incluye) arranque con una base vacía de verdad, sin arrastrar
datos de la corrida anterior.

## Cómo minikube alcanza la MySQL del host (confirmado, no asumido)

Driver `docker` en Windows + Docker Desktop, probado el 2026-10-29 contra
minikube v1.37.0 / Docker Desktop 4.51.0:

```bash
$ minikube ssh -- getent hosts host.minikube.internal
192.168.65.254  host.minikube.internal

$ minikube ssh -- nc -zv -w 3 host.minikube.internal 3307
Connection to host.minikube.internal (192.168.65.254) 3307 port [tcp/*] succeeded!
```

(`3307` era el puerto de prueba usado al confirmar esto, no el default real
-- ver `MYSQL_LOCAL_PORT` abajo.)

**`host.minikube.internal` resuelve y es alcanzable desde dentro del
cluster** -- soportado desde minikube ≥1.26 con el driver `docker` (Docker
Desktop expone el host en esa IP dentro de su VM, y el `docker run -p
<puerto>:3306` de `mysql-local-up` publica el contenedor ahí). No hizo
falta la alternativa.

**macOS**: lo de arriba se probó a mano sólo en Windows -- no hay máquina
macOS disponible para repetir el mismo `minikube ssh -- getent hosts ...`
acá. minikube documenta `host.minikube.internal` para el driver `docker`
como una feature propia de minikube (inyecta el hostname resolviendo el
gateway de la red docker, no algo que dependa de una feature exclusiva de
Docker Desktop en Windows), por lo que en teoría aplica igual en macOS --
pero es lo que minikube documenta, no algo confirmado a mano en este repo.
Antes de asumirlo en macOS, repetir el mismo `getent hosts`/`nc -zv` de
arriba y anotar el resultado real acá, como se hizo para Windows.

**Si en otro setup (otro driver, otro SO, otra versión de Docker Desktop)
`host.minikube.internal` no resuelve**, la alternativa documentada por
minikube es la IP de la ruta default dentro del propio nodo:

```bash
minikube ssh -- ip route show | grep default
# default via 192.168.49.1 dev eth0  <- esa IP (ejemplo) es la del host
```

Usar esa IP en lugar de `host.minikube.internal` en las variables de abajo
si el primer método no resuelve en tu setup -- y documentar acá cuál
aplicó, como se hizo arriba, en vez de dejarlo asumido para la próxima
persona.

## Qué exportar antes de `make k8s-bootstrap`

Con la MySQL descartable arriba (`make mysql-local-up` imprime esto mismo
al final, con el host real resuelto):

```bash
export MYSQL_CONNECTION_STRING="mysql://digsigna:digsigna@tcp(host.minikube.internal:3306)/digsigna?parseTime=true"
export KEYCLOAK_DB_HOST=host.minikube.internal
export KEYCLOAK_DB_USERNAME=keycloak
export KEYCLOAK_DB_PASSWORD=keycloak
```

Más las variables que `scripts/bootstrap-manual-secrets.sh` sigue
necesitando y que ninguna MySQL resuelve por sí sola -- `GHCR_USERNAME`/
`GHCR_TOKEN`/`GHCR_EMAIL` (pull de ghcr.io) y `HSM_PIN`/`HSM_MASTER_AES_KEY_V1`/
`KEYCLOAK_ADMIN_PASSWORD` (decisiones operativas, no derivadas de la base).
Ver `k8s/README.md` y `scripts/bootstrap-manual-secrets.sh --help` (su
propio mensaje de error cuando falta una) para el detalle de cada una.

**Contra el DOKS real (no minikube)**: estas mismas cuatro variables
(`MYSQL_CONNECTION_STRING`, `KEYCLOAK_DB_HOST`, `KEYCLOAK_DB_USERNAME`,
`KEYCLOAK_DB_PASSWORD`) siguen siendo las que hay que exportar antes de
`make k8s-bootstrap` -- la diferencia es que ahí apuntan a la MySQL
gestionada real de DigitalOcean (host/usuario/password que salen de
`terraform/modules/database/`, nunca a este contenedor local ni a sus
credenciales de desarrollo). El mecanismo (`bootstrap-manual-secrets.sh`)
es el mismo en los dos casos; lo único que cambia es a qué MySQL apuntan
los valores.

## Ciclo completo

```bash
make minikube-up
make mysql-local-up
make k8s-bootstrap
make k8s-deploy
make smoke-test
make teardown   # minikube delete + mysql-local-down -- deja todo limpio para repetir
```
