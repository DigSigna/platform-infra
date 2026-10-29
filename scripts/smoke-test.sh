#!/usr/bin/env bash
# Smoke test end-to-end de verdad contra el gateway ya desplegado (no un
# `kubectl get pods`): recorre el flujo real de negocio completo --
# bootstrap de la plataforma -> login -> crear una Organization con su
# propia CA -> emitir un certificado de firma para un usuario de esa
# Organization -> firmar un PDF -> verificar la firma -- todo vía HTTP
# contra gateway-service, igual que lo haría un cliente real.
#
# Por qué la jerarquía Organization en el medio (no "tenant CA -> firma
# directo"): certificate-service's IssueCertificateUseCase exige
# full_name Y organization_name resueltos desde identification-service
# (IncompleteIdentityError si falta cualquiera de los dos -- ver
# app/application/use_cases/issue_certificate.py) y organization_name
# viene SIEMPRE de la Organization del usuario (get-user-identity.js) --
# nunca del tenant. Un usuario del tenant raíz sin Organization nunca
# puede emitir un certificado de firma, aunque su parent_key_id resuelva
# bien. El camino real exige: CA del tenant (automática en el bootstrap)
# -> CA de una Organization (requiere un usuario con 'organization:manage'
# org-scoped a esa Organization -- el rol 'Organization Manager' que
# seed-default-roles.js ya siembra en todo tenant) -> certificado de firma
# del usuario final de esa Organization.
#
# Uso:
#   GATEWAY_URL=http://$(minikube ip) BOOTSTRAP_SECRET=... ./smoke-test.sh
#
# BOOTSTRAP_SECRET: si no se pasa, se lee de k8s/envs/identification-service.env
# (el mismo valor que ya tiene que existir ahí para que
# apply-service-env-secrets.sh haya podido aplicar el Secret real).
#
# Idempotencia entre corridas: el bootstrap de la plataforma sólo puede
# correr UNA vez por base de datos (identification-service se autodeshabilita
# en cuanto existe un tenant raíz -- ver bootstrap-platform.js). Como
# mysql-secrets casi siempre apunta a una MySQL externa que `make teardown`
# NO borra (sólo borra el nodo de minikube), este script persiste las
# credenciales del admin del primer bootstrap en STATE_FILE y las reusa en
# las corridas siguientes contra la misma base, en vez de fallar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GATEWAY_URL="${GATEWAY_URL:?Falta GATEWAY_URL, ej: GATEWAY_URL=http://\$(minikube ip)}"
ENV_DIR="${ENV_DIR:-$REPO_ROOT/k8s/envs}"
STATE_FILE="${STATE_FILE:-$REPO_ROOT/.smoke-test-state.json}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: falta '$1' en el PATH." >&2
    exit 1
  fi
}
require_cmd curl
require_cmd jq
require_cmd python3
require_cmd openssl

if [ -z "${BOOTSTRAP_SECRET:-}" ]; then
  env_file="$ENV_DIR/identification-service.env"
  if [ -f "$env_file" ]; then
    BOOTSTRAP_SECRET="$(sed -n 's/^BOOTSTRAP_SECRET=//p' "$env_file" | tail -n1)"
  fi
fi
if [ -z "${BOOTSTRAP_SECRET:-}" ]; then
  echo "Error: falta BOOTSTRAP_SECRET (ni env var ni en $ENV_DIR/identification-service.env)." >&2
  exit 1
fi

step() { echo; echo "== $* =="; }
die() { echo "Error: $*" >&2; exit 1; }

# http METHOD PATH DATA [curl-args...]  -- DATA "-" = sin body.
# Deja el resultado en $CODE/$BODY.
http() {
  local method="$1" path="$2" data="$3"
  shift 3
  local tmp
  tmp="$(mktemp)"
  if [ "$data" = "-" ]; then
    CODE="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$GATEWAY_URL$path" \
      -H 'Content-Type: application/json' "$@")"
  else
    CODE="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$GATEWAY_URL$path" \
      -H 'Content-Type: application/json' -d "$data" "$@")"
  fi
  BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

expect() {
  local expected="$1" what="$2"
  if [ "$CODE" != "$expected" ]; then
    die "$what: esperaba HTTP $expected, recibí $CODE -- $BODY"
  fi
}

random_password() { openssl rand -base64 18; }

minimal_pdf_b64() {
  # Mismo PDF mínimo (3 objetos: Catalog/Pages/Page, sin stream) que usan
  # los tests reales del PAdES signer de signing-service
  # (tests/test_pyhanko_pades_signer.py::_minimal_pdf) -- confirmado que
  # pyHanko lo acepta para una incremental update real, no inventado.
  python3 - <<'PY'
import base64

objs = [
    b"<</Type/Catalog/Pages 2 0 R>>",
    b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
    b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>",
]
body = b"%PDF-1.4\n"
offsets = []
for i, obj in enumerate(objs, start=1):
    offsets.append(len(body))
    body += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
xref_offset = len(body)
xref = b"xref\n0 4\n0000000000 65535 f \n"
for off in offsets:
    xref += f"{off:010d} 00000 n \n".encode()
trailer = (
    b"trailer\n<</Size 4/Root 1 0 R>>\nstartxref\n"
    + str(xref_offset).encode()
    + b"\n%%EOF"
)
print(base64.b64encode(body + xref + trailer).decode())
PY
}

step "0. Esperando a que el gateway responda (identification-service /health, publico)"
attempts=0
until [ "$attempts" -ge 20 ]; do
  http GET "/identification/api/v1/health" "-"
  [ "$CODE" = "200" ] && break
  attempts=$((attempts + 1))
  sleep 3
done
[ "$CODE" = "200" ] || die "gateway/identification-service no respondió salud tras 60s (HTTP $CODE): $BODY"
echo "OK -- gateway alcanzable en $GATEWAY_URL"

if [ -f "$STATE_FILE" ]; then
  step "1. Reusando el tenant raiz de una corrida anterior ($STATE_FILE)"
  TENANT_ID="$(jq -r .tenant_id "$STATE_FILE")"
  ADMIN_EMAIL="$(jq -r .admin_email "$STATE_FILE")"
  ADMIN_PASSWORD="$(jq -r .admin_password "$STATE_FILE")"
  echo "tenant_id=$TENANT_ID admin_email=$ADMIN_EMAIL"
else
  step "1. Bootstrap de la plataforma (tenant raiz + admin + CA raiz automatica)"
  ADMIN_EMAIL="smoke-admin@digsigna.local"
  ADMIN_PASSWORD="$(random_password)"
  payload="$(jq -n --arg email "$ADMIN_EMAIL" --arg pw "$ADMIN_PASSWORD" '
    {tenant: {name: "Smoke Test Tenant", contact_email: $email},
     user: {email: $email, password: $pw, first_name: "Smoke", last_name: "Admin"}}')"
  http POST "/identification/api/v1/bootstrap" "$payload" -H "x-bootstrap-secret: $BOOTSTRAP_SECRET"
  if [ "$CODE" = "404" ]; then
    die "bootstrap ya corrió contra esta base en otro momento (404) y no hay $STATE_FILE local con las credenciales de ese admin. Borra la base de datos para una corrida limpia, o crea $STATE_FILE a mano con {tenant_id, admin_email, admin_password}."
  fi
  expect 201 "bootstrap"
  TENANT_ID="$(echo "$BODY" | jq -r .tenant.id)"
  echo "$BODY" | jq -n --arg t "$TENANT_ID" --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" \
    '{tenant_id: $t, admin_email: $e, admin_password: $p}' > "$STATE_FILE"
  echo "OK -- tenant_id=$TENANT_ID (credenciales guardadas en $STATE_FILE)"
fi

step "2. Login del admin del tenant"
http POST "/identification/api/v1/tenants/$TENANT_ID/sessions" \
  "$(jq -n --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email: $e, password: $p}')"
expect 201 "login admin"
ADMIN_TOKEN="$(echo "$BODY" | jq -r .access_token)"
echo "OK"

step "3. Creando una Organization (sera quien tenga su propia CA intermedia)"
ORG_NAME="Smoke Org $(date +%s)"
http POST "/identification/api/v1/tenants/$TENANT_ID/organizations" \
  "$(jq -n --arg name "$ORG_NAME" '{type: "organizacion", name: $name}')" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
expect 201 "crear organization"
ORG_ID="$(echo "$BODY" | jq -r .id)"
echo "OK -- organization_id=$ORG_ID"

step "4. Creando el usuario 'Organization Manager' de esa Organization"
ORGMGR_EMAIL="smoke-orgmgr-$(date +%s)@digsigna.local"
ORGMGR_PASSWORD="$(random_password)"
http POST "/identification/api/v1/tenants/$TENANT_ID/users" \
  "$(jq -n --arg e "$ORGMGR_EMAIL" --arg p "$ORGMGR_PASSWORD" --arg org "$ORG_ID" \
    '{email: $e, password: $p, first_name: "Smoke", last_name: "OrgManager", organization_id: $org}')" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
expect 201 "crear usuario org-manager"
ORGMGR_USER_ID="$(echo "$BODY" | jq -r .id)"
echo "OK -- user_id=$ORGMGR_USER_ID"

step "5. Buscando el rol 'Organization Manager' (sembrado automaticamente en todo tenant)"
http GET "/identification/api/v1/tenants/$TENANT_ID/roles" "-" -H "Authorization: Bearer $ADMIN_TOKEN"
expect 200 "listar roles"
ORGMGR_ROLE_ID="$(echo "$BODY" | jq -r '.data[] | select(.name == "Organization Manager") | .id')"
[ -n "$ORGMGR_ROLE_ID" ] && [ "$ORGMGR_ROLE_ID" != "null" ] || die "no se encontró el rol 'Organization Manager' en el tenant $TENANT_ID"
echo "OK -- role_id=$ORGMGR_ROLE_ID"

step "6. Asignando 'Organization Manager' al usuario, acotado a esa Organization"
http POST "/identification/api/v1/tenants/$TENANT_ID/users/$ORGMGR_USER_ID/roles" \
  "$(jq -n --arg r "$ORGMGR_ROLE_ID" --arg org "$ORG_ID" '{role_id: $r, organization_id: $org}')" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
expect 204 "asignar rol org-manager"
echo "OK"

step "7. Login del Organization Manager (su identidad de certificacion ahora es la Organization)"
http POST "/identification/api/v1/tenants/$TENANT_ID/sessions" \
  "$(jq -n --arg e "$ORGMGR_EMAIL" --arg p "$ORGMGR_PASSWORD" '{email: $e, password: $p}')"
expect 201 "login org-manager"
ORGMGR_TOKEN="$(echo "$BODY" | jq -r .access_token)"
echo "OK"

step "8. Generando la CA de la Organization (firmada por la CA raiz del tenant)"
http POST "/certificate/api/v1/cas" \
  "$(jq -n --arg cn "$ORG_NAME CA" '{common_name: $cn}')" \
  -H "Authorization: Bearer $ORGMGR_TOKEN"
expect 201 "crear CA de la organization"
echo "OK -- $(echo "$BODY" | jq -r '.common_name + " (cert_level=" + (.cert_level|tostring) + ")"')"

step "9. Creando el usuario firmante final, miembro de esa Organization"
SIGNER_EMAIL="smoke-signer-$(date +%s)@digsigna.local"
SIGNER_PASSWORD="$(random_password)"
http POST "/identification/api/v1/tenants/$TENANT_ID/users" \
  "$(jq -n --arg e "$SIGNER_EMAIL" --arg p "$SIGNER_PASSWORD" --arg org "$ORG_ID" \
    '{email: $e, password: $p, first_name: "Smoke", last_name: "Signer", organization_id: $org}')" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
expect 201 "crear usuario firmante"
echo "OK -- user_id=$(echo "$BODY" | jq -r .id)"

step "10. Login del firmante"
http POST "/identification/api/v1/tenants/$TENANT_ID/sessions" \
  "$(jq -n --arg e "$SIGNER_EMAIL" --arg p "$SIGNER_PASSWORD" '{email: $e, password: $p}')"
expect 201 "login firmante"
SIGNER_TOKEN="$(echo "$BODY" | jq -r .access_token)"
echo "OK"

step "11. Emitiendo el certificado de firma del firmante (bajo la CA de la Organization)"
http POST "/certificate/api/v1/certificates" "{}" -H "Authorization: Bearer $SIGNER_TOKEN"
expect 201 "emitir certificado de firma"
CERTIFICATE_ID="$(echo "$BODY" | jq -r .id)"
echo "OK -- certificate_id=$CERTIFICATE_ID"

step "12. Fijando el signing PIN del certificado"
SIGNING_PIN="193042"
http POST "/certificate/api/v1/certificates/$CERTIFICATE_ID/signing-pin" \
  "$(jq -n --arg pin "$SIGNING_PIN" '{pin: $pin}')" \
  -H "Authorization: Bearer $SIGNER_TOKEN"
expect 200 "fijar signing PIN"
echo "OK"

step "13. Firmando un PDF de prueba (PAdES, via signing-service)"
DOCUMENT_B64="$(minimal_pdf_b64)"
http POST "/signing/api/v1/sign" \
  "$(jq -n --arg cid "$CERTIFICATE_ID" --arg doc "$DOCUMENT_B64" --arg pin "$SIGNING_PIN" \
    '{certificate_id: $cid, document_b64: $doc, document_name: "smoke-test.pdf", pin: $pin}')" \
  -H "Authorization: Bearer $SIGNER_TOKEN"
expect 201 "firmar documento"
SIGNED_DOCUMENT_B64="$(echo "$BODY" | jq -r .signed_document_b64)"
echo "OK -- signature_format=$(echo "$BODY" | jq -r .signature_format) tsa_provider=$(echo "$BODY" | jq -r .tsa_provider)"

step "14. Verificando la firma (publico, sin JWT, via verification-service)"
http POST "/verification/api/v1/verify" \
  "$(jq -n --arg doc "$SIGNED_DOCUMENT_B64" '{document_b64: $doc, document_name: "smoke-test.pdf"}')"
expect 200 "verificar firma"
ALL_VALID="$(echo "$BODY" | jq -r .all_valid)"
[ "$ALL_VALID" = "true" ] || die "verificación devolvió all_valid=false: $BODY"
echo "OK -- $(echo "$BODY" | jq -c '{total_signatures, valid_signatures, all_valid}')"

step "Smoke test OK de punta a punta: login -> CA -> certificado -> firma -> verificación"
