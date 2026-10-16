#!/usr/bin/env bash
# DESASTRE SIMULADO: perdida total del cluster.
#   - El cluster GKE y TODOS sus discos (incluidos los volumenes de la BD) desaparecen.
#   - Sobrevive solo la capa persistente: bucket de estado, bucket de Velero,
#     Secret Manager. Nada se "limpia" con cuidado: los recursos de Helm/K8s se
#     sacan del estado para simular que el cluster simplemente dejo de existir.
source "$(dirname "$0")/lib.sh"
[[ "${LOG_HEREDADO:-}" == "1" ]] || LOG="$EVIDENCIAS/destruccion-$(date +%Y%m%d-%H%M%S).log"
export LOG

if [[ "${1:-}" != "--si" ]]; then
  read -r -p "Esto DESTRUYE el cluster $CLUSTER y sus volumenes. Escriba DESTRUIR para continuar: " R
  [[ "$R" == "DESTRUIR" ]] || { echo "Cancelado."; exit 1; }
fi

seccion "DESTRUCCION DEL ENTORNO"
marca DESTRUCCION_INICIO

# Discos de los PVC antes de destruir (para borrarlos despues: perdida real del volumen)
DISCOS=$(gcloud compute disks list --project "$PROYECTO" --filter="zone~$ZONA AND name~^pvc-" --format="value(name)" || true)
log "Volumenes persistentes que se perderan: ${DISCOS:-ninguno}"

# Leccion de la primera prueba de DR (15/10/2026): al borrar el node pool, GKE
# vacia cada nodo RESPETANDO los PodDisruptionBudgets; como todos los nodos se
# borran a la vez, los pods no tienen a donde ir y el PDB bloquea el desalojo
# hasta 1 hora por nodo. Ademas el webhook de Kyverno queda registrado sin pods.
# Se retiran esos bloqueos y se borra el CLUSTER directamente (sin vaciar nodos).
if credenciales_cluster && kubectl get ns >/dev/null 2>&1; then
  log "Retirando bloqueos de la destruccion (ArgoCD, PDB, webhooks de Kyverno)"
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null 2>&1 || true
  kubectl delete pdb --all -A --wait=false 2>&1 | tee -a "$LOG" || true
  kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
    -l webhook.kyverno.io/managed-by=kyverno --wait=false 2>&1 | tee -a "$LOG" || true
fi

tf_init cluster
cd "$P9_DIR/terraform/cluster"
for r in google_container_node_pool.principal helm_release.raiz helm_release.argocd kubernetes_secret_v1.sealed_secrets_llave; do
  terraform state rm "$r" >/dev/null 2>&1 && log "estado: $r retirado (el cluster se pierde con el)" || true
done
correr terraform destroy -input=false -auto-approve "${TF_VARS_CLUSTER[@]}"
cd - >/dev/null

seccion "Borrado de los discos de datos"
for d in $DISCOS; do
  correr gcloud compute disks delete "$d" --zone "$ZONA" --project "$PROYECTO" --quiet || true
done

correr gcloud container clusters list --project "$PROYECTO"
marca DESTRUCCION_FIN
