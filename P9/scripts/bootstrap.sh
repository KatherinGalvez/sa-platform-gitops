#!/usr/bin/env bash
# =============================================================================
# PUNTO DE ENTRADA UNICO DEL BOOTSTRAP DE DIA CERO
#
#   ./P9/scripts/bootstrap.sh
#
# Reconstruye TODO el sistema desde cero, sin pasos manuales intermedios:
#   1. Terraform (capa persistente, idempotente)   -> bucket, SA, Secret Manager
#   2. Terraform (capa cluster)                     -> GKE, llave Sealed Secrets, ArgoCD, app raiz
#   3. ArgoCD app-of-apps (p9-raiz) por olas:
#        ola 0 sealed-secrets, velero, argo-rollouts, kyverno
#        ola 1 politicas (Kyverno) + restauracion-dr (restaura datos si hay respaldo)
#        ola 2 datos  (PostgreSQL + API como Rollout canary + PDB)
#   4. Verificaciones: aplicaciones Synced/Healthy, secretos descifrados,
#      contenido de la base de datos y API respondiendo.
# Cada fase deja una MARCA con fecha/hora en evidencias/ para calcular el RTO.
# =============================================================================
source "$(dirname "$0")/lib.sh"
[[ "${LOG_HEREDADO:-}" == "1" ]] || LOG="$EVIDENCIAS/bootstrap-$(date +%Y%m%d-%H%M%S).log"
export LOG

seccion "BOOTSTRAP P9  proyecto=$PROYECTO cluster=$CLUSTER zona=$ZONA"
marca BOOTSTRAP_INICIO
T_INICIO=$(epoch)

# ---- 1. Capa persistente ----------------------------------------------------
seccion "1/4 Terraform: capa persistente"
tf_init persistente
correr terraform -chdir="$P9_DIR/terraform/persistente" apply -input=false -auto-approve \
  -var="project_id=$PROYECTO" -var="region=$REGION" -var="velero_bucket=$BUCKET_VELERO"
marca PERSISTENTE_OK

# ---- 2. Capa cluster --------------------------------------------------------
seccion "2/4 Terraform: cluster + ArgoCD + app raiz"
tf_init cluster
correr terraform -chdir="$P9_DIR/terraform/cluster" apply -input=false -auto-approve "${TF_VARS_CLUSTER[@]}"
marca TERRAFORM_OK
credenciales_cluster
correr kubectl get nodes -o wide

# ---- 3. GitOps --------------------------------------------------------------
seccion "3/4 ArgoCD app-of-apps"
until kubectl -n argocd get application p9-raiz >/dev/null 2>&1; do sleep 5; done
LIMITE=$(( $(epoch) + 2400 ))
ULTIMO_REPORTE=0
while :; do
  ESTADO=$(kubectl -n argocd get applications \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.sync.status}{"/"}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  PENDIENTES=$(echo "$ESTADO" | grep -v '=Synced/Healthy$' | grep . || true)
  TOTAL=$(echo "$ESTADO" | grep -c . || true)
  if [[ -z "$PENDIENTES" && "$TOTAL" -ge 8 ]]; then break; fi
  if (( $(epoch) - ULTIMO_REPORTE >= 60 )); then
    log "Esperando aplicaciones: $(echo "$PENDIENTES" | tr '\n' ' ')"
    ULTIMO_REPORTE=$(epoch)
  fi
  if (( $(epoch) > LIMITE )); then
    log "TIEMPO AGOTADO (40 min). Estado actual:"; echo "$ESTADO" | tee -a "$LOG"; exit 1
  fi
  sleep 10
done
correr kubectl -n argocd get applications
marca ARGOCD_TODO_SINCRONIZADO

seccion "Registro de la restauracion automatica (ola 1)"
kubectl -n velero logs job/restauracion-dr 2>&1 | tee -a "$LOG" || true
kubectl -n velero get restores 2>/dev/null | tee -a "$LOG" || true

# ---- 4. Verificaciones ------------------------------------------------------
seccion "4/4 Verificaciones"
kubectl -n datos rollout status statefulset/postgres --timeout=10m | tee -a "$LOG"
kubectl -n datos wait --for=condition=Healthy rollout/servicio-datos --timeout=10m | tee -a "$LOG"

log "Secretos: SealedSecret -> Secret"
kubectl -n datos get sealedsecret,secret db-credenciales 2>&1 | tee -a "$LOG"

log "Contenido de la base de datos:"
huella_datos datos | tee -a "$LOG"

log "Esperando respuesta HTTP de la API..."
until servicio_responde; do sleep 3; done
kubectl get --raw "/api/v1/namespaces/datos/services/servicio-datos:3000/proxy/pedidos?select=id,cliente,total&order=id&limit=3" | tee -a "$LOG"; echo | tee -a "$LOG"
marca SERVICIO_RESPONDE
T_FIN=$(epoch)

seccion "RESUMEN"
log "Duracion total del bootstrap: $(duracion "$T_INICIO" "$T_FIN")"
log "Registro completo: ${LOG#$P9_DIR/}"
echo "$T_FIN" > "$EVIDENCIAS/.ultimo_servicio_ok"
