#!/usr/bin/env bash
# PASO 1 (una sola vez): guarda la llave de Sealed Secrets FUERA del cluster,
# en Google Secret Manager.
#
#   ./01-llave-sealed-secrets.sh                 -> genera una llave nueva
#   ./01-llave-sealed-secrets.sh llave-p8.yaml   -> importa la llave de su cluster P8
#
# Para exportar la llave del cluster de la Practica 8 (si aun existe):
#   kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > llave-p8.yaml
source "$(dirname "$0")/lib.sh"
LOG="$EVIDENCIAS/01-llave-sealed-secrets.log"

CRT_SECRET="p9-sealed-secrets-crt"
KEY_SECRET="p9-sealed-secrets-key"

if gcloud secrets versions list "$KEY_SECRET" --project "$PROYECTO" --filter="state=ENABLED" --format="value(name)" 2>/dev/null | grep -q .; then
  log "La llave ya esta en Secret Manager; no se sobrescribe."
  gcloud secrets versions access latest --secret "$CRT_SECRET" --project "$PROYECTO" \
    | openssl x509 -noout -subject -enddate -fingerprint -sha256 | tee -a "$LOG"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [[ $# -ge 1 ]]; then
  log "Importando llave existente desde $1"
  N=$(grep -c 'tls.key:' "$1" || true)
  [[ "$N" -gt 1 ]] && log "AVISO: el archivo trae $N llaves; se importa la ULTIMA. Si algun SealedSecret no descifra, vuelva a sellarlo con scripts/sellar.sh"
  grep 'tls.crt:' "$1" | tail -1 | awk '{print $2}' | base64 -d > "$TMP/tls.crt"
  grep 'tls.key:' "$1" | tail -1 | awk '{print $2}' | base64 -d > "$TMP/tls.key"
else
  log "Generando llave nueva RSA 4096 (valida 10 anios)"
  openssl req -x509 -days 3650 -nodes -newkey rsa:4096 \
    -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
    -subj "/CN=sealed-secret/O=sealed-secret" 2>/dev/null
fi

openssl x509 -in "$TMP/tls.crt" -noout >/dev/null || { log "Certificado invalido"; exit 1; }

correr gcloud secrets versions add "$CRT_SECRET" --project "$PROYECTO" --data-file="$TMP/tls.crt"
correr gcloud secrets versions add "$KEY_SECRET" --project "$PROYECTO" --data-file="$TMP/tls.key"
openssl x509 -in "$TMP/tls.crt" -noout -subject -enddate -fingerprint -sha256 | tee -a "$LOG"
log "Llave guardada. La privada solo existe en Secret Manager (el archivo temporal se borro)."
log "Siguiente paso: scripts/02-configurar-gitops.sh"
