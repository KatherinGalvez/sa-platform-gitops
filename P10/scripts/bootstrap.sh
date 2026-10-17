#!/usr/bin/env bash
# =============================================================================
# Bootstrap GitOps del cluster p10-obs.
#   1. Instala ArgoCD (helm, version fija)
#   2. Crea el secreto de administrador de Grafana (no se guarda en Git)
#   3. Aplica la app raiz p10-raiz -> ArgoCD despliega TODO lo demas desde Git:
#        ola -1 repositorio OCI | ola 0 argo-rollouts, kube-prometheus-stack, kyverno
#        ola 1 telemetria (Loki, Tempo, Collector), slo-tablero, politicas
#        ola 2 produccion (pedidos Rollout canary, pagos, inventario, generador)
#   4. Espera a que todas las aplicaciones esten Healthy
#   ./P10/scripts/bootstrap.sh
# =============================================================================
source "$(dirname "$0")/lib.sh"
LOG="$EVIDENCIAS/bootstrap-$(date +%Y%m%d-%H%M%S).log"
credenciales
marca BOOTSTRAP_INICIO
T0=$(epoch)

seccion "1/4 ArgoCD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
correr helm upgrade --install argocd argo/argo-cd --version 10.9.2 \
  --namespace argocd --create-namespace \
  -f "$P10_DIR/gitops/bootstrap/argocd-values.yaml" --wait --timeout 10m

seccion "2/4 Secreto de Grafana"
kubectl create namespace observabilidad --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n observabilidad get secret grafana-admin >/dev/null 2>&1; then
  CLAVE=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
  kubectl -n observabilidad create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$CLAVE" >/dev/null
fi
log "Grafana: usuario admin (la clave se muestra con ./P10/scripts/accesos.sh)"

seccion "3/4 Aplicacion raiz"
correr kubectl apply -f "$P10_DIR/gitops/bootstrap/raiz.yaml"

seccion "4/4 Esperando aplicaciones (hasta 30 min)"
LIMITE=$(( $(epoch) + 1800 )); ULTIMO=0
while :; do
  ESTADO=$(kubectl -n argocd get applications \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.sync.status}{"/"}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  PEND=$(echo "$ESTADO" | grep -vE '=(Synced|OutOfSync)/Healthy$' | grep . || true)
  TOTAL=$(echo "$ESTADO" | grep -c . || true)
  [[ -z "$PEND" && "$TOTAL" -ge 8 ]] && break
  if (( $(epoch) - ULTIMO >= 60 )); then log "Pendientes: $(echo "$PEND" | tr '\n' ' ')"; ULTIMO=$(epoch); fi
  if (( $(epoch) > LIMITE )); then log "TIEMPO AGOTADO"; echo "$ESTADO" | tee -a "$LOG"; exit 1; fi
  sleep 10
done
marca ARGOCD_SINCRONIZADO
correr kubectl -n argocd get applications
correr kubectl -n produccion get rollout,deploy,pods -o wide
correr kubectl -n observabilidad get pods
log "Bootstrap completo en $(duracion "$T0" "$(epoch)")"
log "Espere ~5 min de trafico para que las reglas de SLO tengan datos. Luego: ./P10/scripts/accesos.sh"
