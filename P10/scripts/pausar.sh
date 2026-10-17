#!/usr/bin/env bash
# Pausa (0 nodos, ~sin costo de computo) o reanuda el cluster p10-obs.
#   ./P10/scripts/pausar.sh            # 0 nodos
#   ./P10/scripts/pausar.sh reanudar   # vuelve a NODOS nodos; ArgoCD se recupera solo
# Al reanudar, Prometheus/Loki/Tempo empiezan vacios (almacenamiento efimero):
# espere 5-10 min de trafico antes de calificar. Los AnalysisRun (etcd) se conservan.
source "$(dirname "$0")/lib.sh"
gcloud config set project "$PROYECTO" >/dev/null
if [[ "${1:-}" == "reanudar" ]]; then
  gcloud container clusters resize "$CLUSTER" --node-pool default-pool --num-nodes "$NODOS" --zone "$ZONA" --quiet || true
  credenciales
  kubectl get nodes
  echo "Esperando pods..."
  kubectl -n produccion wait --for=condition=Healthy rollout/pedidos --timeout=15m || true
  kubectl -n argocd get applications
else
  gcloud container clusters resize "$CLUSTER" --node-pool default-pool --num-nodes 0 --zone "$ZONA" --quiet || true
  echo "Si el comando expiro, la operacion sigue en Google Cloud. Revise con:"
  echo "  gcloud container operations list --zone $ZONA --filter='status!=DONE'"
fi
