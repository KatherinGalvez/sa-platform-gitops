#!/usr/bin/env bash
# Muestra el estado de los respaldos (para capturas y para el requisito
# "existe al menos un respaldo completado").
#   ./respaldos.sh           -> lista schedule, ubicacion y respaldos
#   ./respaldos.sh --ahora   -> fuerza un respaldo inmediato desde el schedule
source "$(dirname "$0")/lib.sh"
credenciales_cluster
if [[ "${1:-}" == "--ahora" ]]; then
  velero backup create --from-schedule velero-horario --wait
fi
echo "== Ubicacion de respaldos (fuera del cluster) =="; velero backup-location get
echo; echo "== Schedule =="; velero schedule get
kubectl -n velero get schedule velero-horario -o jsonpath='calendario={.spec.schedule}  retencion(ttl)={.spec.template.ttl}  namespaces={.spec.template.includedNamespaces}  fs-backup={.spec.template.defaultVolumesToFsBackup}{"\n"}'
echo; echo "== Respaldos =="; velero backup get
echo; echo "== Objetos en el bucket gs://$BUCKET_VELERO =="
gcloud storage ls "gs://$BUCKET_VELERO/backups/" 2>/dev/null | tail -5
