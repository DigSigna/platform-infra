platform-infra/
  README.md                      # qué vive aquí y por qué (la discusión que tuvimos sobre softhsm acumulando responsabilidades ajenas)
  k8s/
    migrations-job.yaml          # migrado de softhsm/k8s/
    hsm-secrets.yaml             # migrado de softhsm/k8s/
    service-keys/                # nuevo (punto 3) — manifiestos de Secret por servicio, sin valores reales commiteados
      hsm-service.secret.yaml
      certificate-service.secret.yaml
      signing-service.secret.yaml
      identification-service.secret.yaml
      audit-service.secret.yaml  # el consumidor, no un productor — ver instrucción abajo
  scripts/
    generate-service-keys.sh     # (o .py) — genera las keys reales y las aplica al cluster, nunca las escribe en el repo
  docs/
    service-key-map.md           # el mapa: qué servicio tiene qué key (por nombre/fingerprint, nunca el valor crudo), quién la consume
    ADR-001-infra-repo-scope.md  # opcional — por qué este repo existe y qué NO le corresponde (eso sigue viviendo en cada servicio o en migrations)