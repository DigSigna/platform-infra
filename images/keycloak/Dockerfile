# La distribución Quarkus de quay.io/keycloak/keycloak:22.0.0 (la misma
# imagen que usa hsm-service/docker-compose.dev.yml) NO empaqueta el driver
# JDBC de MySQL -- solo bundlea H2 (dev), Postgres y MSSQL, porque el
# connector de MySQL es GPL y Keycloak no puede redistribuirlo. Sin este
# jar, `kc.sh build --db=mysql`/`kc.sh start --db=mysql` fallan al no
# encontrar ningún driver para "mysql". Ver
# https://www.keycloak.org/server/db#_mysql_mariadb.
#
# Build + push (manual hoy, sin pipeline de CI en este repo -- igual
# criterio que ghcr-creds, ver k8s/README.md):
#   docker build -t ghcr.io/digsigna/keycloak:22.0.0-mysql images/keycloak
#   docker push ghcr.io/digsigna/keycloak:22.0.0-mysql
#
# k8s/deployments/keycloak.yaml referencia ese tag exacto -- bump acá y ahí
# juntos si se actualiza la versión base de Keycloak.
FROM quay.io/keycloak/keycloak:22.0.0

ADD --chown=keycloak:root --chmod=644 https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.1.0/mysql-connector-j-8.1.0.jar /opt/keycloak/providers/mysql-connector-j-8.1.0.jar

RUN /opt/keycloak/bin/kc.sh build --db=mysql
