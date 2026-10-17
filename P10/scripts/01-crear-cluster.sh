#!/usr/bin/env bash
# =============================================================================
# Crea el entorno PROPIO de la Practica 10: cluster GKE "p10-obs" + repositorio
# de imagenes en Artifact Registry. Idempotente (si ya existe, lo reutiliza).
#   ./P10/scripts/01-crear-cluster.sh
# =============================================================================
source "$(dirname "$0")/lib.sh"
LOG="$EVIDENCIAS/crear-cluster-$(date +%Y%m%d-%H%M%S).log"

seccion "Proyecto $PROYECTO"
gcloud config set project "$PROYECTO" >/dev/null
correr gcloud services enable container.googleapis.com artifactregistry.googleapis.com

seccion "Cuota de CPU en $REGION (P9 + P10 deben caber)"
gcloud compute regions describe "$REGION" --format=json \
  | jq -r '.quotas[] | select(.metric=="CPUS") | "CPUs en uso: \(.usage) de \(.limit)"' | tee -a "$LOG"
NECESARIAS=$(( NODOS * $(echo "$TIPO_MAQUINA" | grep -oE '[0-9]+$') ))
log "Este cluster necesita $NECESARIAS vCPU ($NODOS x $TIPO_MAQUINA)."

seccion "Repositorio de imagenes"
if ! gcloud artifacts repositories describe "$REPOSITORIO_IMAGENES" --location "$REGION" >/dev/null 2>&1; then
  correr gcloud artifacts repositories create "$REPOSITORIO_IMAGENES" --repository-format=docker \
    --location "$REGION" --description "Imagenes de la Practica 10"
fi
# Los nodos usan la cuenta de servicio por defecto de Compute: debe poder leer imagenes
NUM=$(gcloud projects describe "$PROYECTO" --format='value(projectNumber)')
correr gcloud artifacts repositories add-iam-policy-binding "$REPOSITORIO_IMAGENES" --location "$REGION" \
  --member "serviceAccount:${NUM}-compute@developer.gserviceaccount.com" \
  --role roles/artifactregistry.reader --condition=None >/dev/null

seccion "Cluster $CLUSTER"
if gcloud container clusters describe "$CLUSTER" --zone "$ZONA" >/dev/null 2>&1; then
  log "El cluster ya existe: se reutiliza."
else
  marca CLUSTER_CREACION_INICIO
  # --logging=SYSTEM: los registros de la app van a Loki, no a Cloud Logging (sin costo extra)
  correr gcloud container clusters create "$CLUSTER" \
    --zone "$ZONA" --num-nodes "$NODOS" --machine-type "$TIPO_MAQUINA" \
    --disk-type pd-balanced --disk-size 40 \
    --release-channel regular \
    --logging=SYSTEM --monitoring=SYSTEM \
    --enable-ip-alias \
    --labels practica=p10
  marca CLUSTER_CREACION_FIN
fi
credenciales
correr kubectl get nodes -o wide
log "Listo. Siguiente paso: ./P10/scripts/02-imagen.sh"
