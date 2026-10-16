#!/usr/bin/env bash
# LIMPIEZA FINAL (despues de la calificacion): elimina TODO lo creado en la nube
# para que no siga generando costo. Tambien borra respaldos, estado y la llave.
source "$(dirname "$0")/lib.sh"
read -r -p "Se borrara TODO (cluster, respaldos, estado, llave). Escriba BORRAR-TODO: " R
[[ "$R" == "BORRAR-TODO" ]] || { echo "Cancelado."; exit 1; }

"$P9_DIR/scripts/destruir.sh" --si || true
gcloud storage rm -r "gs://$BUCKET_VELERO" --quiet || true
gcloud secrets delete p9-sealed-secrets-crt --project "$PROYECTO" --quiet || true
gcloud secrets delete p9-sealed-secrets-key --project "$PROYECTO" --quiet || true
gcloud iam service-accounts delete "velero-p9@$PROYECTO.iam.gserviceaccount.com" --project "$PROYECTO" --quiet || true
gcloud storage rm -r "gs://$BUCKET_ESTADO" --quiet || true
gcloud compute disks list --project "$PROYECTO"
echo "Listo. Revise la facturacion en la consola para confirmar que no queda nada activo."
