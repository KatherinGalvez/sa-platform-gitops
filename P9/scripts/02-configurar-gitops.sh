#!/usr/bin/env bash
# PASO 2 (una sola vez): rellena los marcadores del repositorio GitOps con los
# valores de p9.env y sella la contrasena de la base de datos.
source "$(dirname "$0")/lib.sh"
LOG="$EVIDENCIAS/02-configurar-gitops.log"

VELERO_GSA="velero-p9@${PROYECTO}.iam.gserviceaccount.com"
GITOPS="$P9_DIR/gitops"

seccion "Reemplazando marcadores"
grep -rl '__[A-Z_]*__' "$GITOPS" | while read -r f; do
  sed -i \
    -e "s#__REPO_URL__#${REPO_URL}#g" \
    -e "s#__REPO_RAMA__#${REPO_RAMA}#g" \
    -e "s#__GITOPS_RUTA__#${GITOPS_RUTA}#g" \
    -e "s#__VELERO_BUCKET__#${BUCKET_VELERO}#g" \
    -e "s#__VELERO_GSA__#${VELERO_GSA}#g" "$f"
  log "  actualizado: ${f#$P9_DIR/}"
done
if grep -rn '__[A-Z_]*__' "$GITOPS"; then log "Quedan marcadores sin reemplazar"; exit 1; fi

seccion "Secreto de la base de datos"
SALIDA="$GITOPS/cargas/datos/05-db-credenciales-sealed.yaml"
if [[ -f "$SALIDA" ]]; then
  log "Ya existe ${SALIDA#$P9_DIR/}; no se vuelve a sellar."
else
  PASS=$(openssl rand -hex 16)
  "$P9_DIR/scripts/sellar.sh" datos db-credenciales "$SALIDA" usuario=app password="$PASS"
  log "Sellado ${SALIDA#$P9_DIR/} (la contrasena en claro no se guarda en ningun archivo)"
fi

log "Ahora haga commit y push de P9/ para que ArgoCD lo pueda leer:"
log "  git add P9 && git commit -m 'P9: GitOps de DR' && git push"
