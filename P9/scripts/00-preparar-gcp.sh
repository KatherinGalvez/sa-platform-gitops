#!/usr/bin/env bash
# PASO 0 (una sola vez): prepara el proyecto de Google Cloud.
#   - instala velero y kubeseal en Cloud Shell
#   - habilita las APIs
#   - crea el bucket del ESTADO REMOTO de Terraform (versionado, bloqueo nativo)
#   - aplica la capa persistente (bucket de Velero, SA, Secret Manager)
source "$(dirname "$0")/lib.sh"
LOG="$EVIDENCIAS/00-preparacion.log"

seccion "Herramientas"
mkdir -p "$HOME/.local/bin"
if ! command -v velero >/dev/null; then
  log "Instalando velero v1.18.2"
  curl -fsSL https://github.com/vmware-tanzu/velero/releases/download/v1.18.2/velero-v1.18.2-linux-amd64.tar.gz \
    | tar -xz -C /tmp && mv /tmp/velero-v1.18.2-linux-amd64/velero "$HOME/.local/bin/"
fi
if ! command -v kubeseal >/dev/null; then
  log "Instalando kubeseal 0.40.0"
  curl -fsSL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/kubeseal-0.40.0-linux-amd64.tar.gz \
    | tar -xz -C "$HOME/.local/bin" kubeseal
fi
grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
for h in gcloud terraform kubectl helm velero kubeseal openssl; do
  printf '  %-10s %s\n' "$h" "$(command -v $h || echo 'NO ENCONTRADO')" | tee -a "$LOG"
done

seccion "Proyecto"
gcloud config set project "$PROYECTO" >/dev/null
correr gcloud services enable container.googleapis.com compute.googleapis.com \
  secretmanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com \
  storage.googleapis.com cloudresourcemanager.googleapis.com

seccion "Bucket del estado remoto de Terraform"
if gcloud storage buckets describe "gs://$BUCKET_ESTADO" >/dev/null 2>&1; then
  log "Ya existe gs://$BUCKET_ESTADO"
else
  correr gcloud storage buckets create "gs://$BUCKET_ESTADO" --location=US \
    --uniform-bucket-level-access --public-access-prevention
fi
correr gcloud storage buckets update "gs://$BUCKET_ESTADO" --versioning

seccion "Capa persistente (terraform/persistente)"
tf_init persistente
correr terraform -chdir="$P9_DIR/terraform/persistente" apply -input=false -auto-approve \
  -var="project_id=$PROYECTO" -var="region=$REGION" -var="velero_bucket=$BUCKET_VELERO"
terraform -chdir="$P9_DIR/terraform/persistente" output | tee -a "$LOG"

log "Listo. Siguiente paso: scripts/01-llave-sealed-secrets.sh"
