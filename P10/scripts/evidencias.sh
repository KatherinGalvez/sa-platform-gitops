#!/usr/bin/env bash
# Guarda en evidencias/ una foto del estado (texto) para la documentacion:
# aplicaciones, Rollout, AnalysisRuns, reglas, valores de SLI y un registro JSON.
#   ./P10/scripts/evidencias.sh
source "$(dirname "$0")/lib.sh"
credenciales
SAL="$EVIDENCIAS/estado-$(date +%Y%m%d-%H%M%S).txt"
LOG="$SAL"
reenviar observabilidad prometheus-operated 19090:9090
{
  seccion "Aplicaciones ArgoCD";      kubectl -n argocd get applications
  seccion "Rollout y AnalysisRuns";   kubectl -n produccion get rollout,analysisrun,analysistemplate
  seccion "Pods produccion";          kubectl -n produccion get pods -L rollouts-pod-template-hash
  seccion "Pods observabilidad";      kubectl -n observabilidad get pods
  seccion "PodMonitor y reglas";      kubectl get podmonitor,prometheusrule -A
  seccion "Politicas de admision";    kubectl get clusterpolicy
  seccion "Indicadores (PromQL)"
  for q in pedidos_creados_total sli:disponibilidad:ratio_rate5m sli:latencia:ratio_rate5m \
           slo:disponibilidad:burn_rate1h slo:latencia:burn_rate1h \
           slo:disponibilidad:presupuesto_restante:ratio30d slo:latencia:presupuesto_restante:ratio30d \
           'sum by (motivo) (pagos_rechazados_total)' 'ALERTS'; do
    echo "$q => $(promql "$q" | jq -c '[.data.result[] | {m: (.metric | del(.__name__)), v: .value[1]}]')"
  done
  seccion "Registro JSON de pedidos (con trace_id)"
  kubectl -n produccion logs "$(kubectl -n produccion get pods -o name | grep pedidos | head -1)" --tail=200 | grep '^{' | tail -3
} 2>&1 | tee "$SAL"
echo "Guardado en ${SAL#$P10_DIR/}"
