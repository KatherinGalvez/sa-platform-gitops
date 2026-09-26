#!/usr/bin/env bash
# Sella un Secret con el certificado PUBLICO guardado en Secret Manager.
# No necesita cluster: sirve incluso antes del bootstrap.
#
#   ./sellar.sh <namespace> <nombre> <archivo_salida> clave1=valor1 [clave2=valor2 ...]
#
# Ejemplo:
#   ./sellar.sh datos otro-secreto ../gitops/cargas/datos/06-otro-sealed.yaml clave=valor
source "$(dirname "$0")/lib.sh"

[[ $# -lt 4 ]] && { echo "Uso: $0 <namespace> <nombre> <archivo_salida> clave=valor..."; exit 1; }
NS="$1"; NOMBRE="$2"; SALIDA="$3"; shift 3

CERT=$(mktemp); trap 'rm -f "$CERT"' EXIT
gcloud secrets versions access latest --secret p9-sealed-secrets-crt --project "$PROYECTO" > "$CERT"

ARGS=()
for kv in "$@"; do ARGS+=(--from-literal="$kv"); done

kubectl create secret generic "$NOMBRE" -n "$NS" "${ARGS[@]}" --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" --format yaml > "$SALIDA"
echo "SealedSecret escrito en $SALIDA (seguro para versionar)."
