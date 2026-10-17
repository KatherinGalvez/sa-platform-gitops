#!/usr/bin/env bash
# =============================================================================
# DEMOSTRACION: canary gobernado por metricas con reversion automatica.
#
#   ./P10/scripts/demo-canary.sh            # publica la version v2 defectuosa y mide
#   ./P10/scripts/demo-canary.sh revertir   # devuelve Git a v1 (limpieza GitOps)
#
# Fallo inducido (distinto al de la Practica 8): REGRESION DE LATENCIA.
#   La version v2 de pedidos agrega 700 ms a cada pedido (LATENCIA_EXTRA_MS).
#   No hay errores: solo el p95 medido en Prometheus sobre los pods del canary
#   puede detectarlo. El AnalysisRun falla y Argo Rollouts aborta el despliegue,
#   devolviendo el 100 % del trafico a v1 SIN intervencion humana.
# =============================================================================
source "$(dirname "$0")/lib.sh"
ARCHIVO="$P10_DIR/gitops/produccion/pedidos-rollout.yaml"
credenciales

if [[ "${1:-}" == "revertir" ]]; then
  LOG="$EVIDENCIAS/canary-revertir-$(date +%Y%m%d-%H%M%S).log"
  sed -i -e 's/- { name: VERSION, value: "v2" }/- { name: VERSION, value: "v1" }/' \
         -e 's/- { name: LATENCIA_EXTRA_MS, value: "700" }/- { name: LATENCIA_EXTRA_MS, value: "0" }/' "$ARCHIVO"
  publicar_cambio "P10: revertir pedidos a v1 tras reversion automatica del canary" "$ARCHIVO"
  kubectl -n produccion wait --for=condition=Healthy rollout/pedidos --timeout=5m | tee -a "$LOG"
  correr kubectl -n produccion get rollout pedidos
  exit 0
fi

LOG="$EVIDENCIAS/canary-$(date +%Y%m%d-%H%M%S).log"
seccion "Estado inicial"
correr kubectl -n produccion get rollout pedidos -o wide
ESTABLE=$(kubectl -n produccion get rollout pedidos -o jsonpath='{.status.stableRS}')
log "Hash estable (v1): $ESTABLE"

seccion "Publicar v2 (latencia +700 ms) en Git"
sed -i -e 's/- { name: VERSION, value: "v1" }/- { name: VERSION, value: "v2" }/' \
       -e 's/- { name: LATENCIA_EXTRA_MS, value: "0" }/- { name: LATENCIA_EXTRA_MS, value: "700" }/' "$ARCHIVO"
git -C "$REPO_DIR" diff --stat
marca FALLO_PUBLICADO
T0=$(epoch)
publicar_cambio "P10: pedidos v2 (regresion de latencia inducida para la demo del canary)" "$ARCHIVO"

seccion "Siguiendo el Rollout (hasta 12 min)"
reenviar observabilidad prometheus-operated 19090:9090
CANARY=""; T_CANARY=""; T_ANALISIS=""
LIMITE=$(( $(epoch) + 720 ))
while (( $(epoch) < LIMITE )); do
  J=$(kubectl -n produccion get rollout pedidos -o json)
  FASE=$(echo "$J" | jq -r '.status.phase // "-"')
  ABORT=$(echo "$J" | jq -r '.status.abort // false')
  PASO=$(echo "$J" | jq -r '.status.currentStepIndex // "-"')
  NUEVO=$(echo "$J" | jq -r '.status.currentPodHash // ""')
  if [[ -z "$CANARY" && -n "$NUEVO" && "$NUEVO" != "$ESTABLE" ]]; then
    CANARY="$NUEVO"; T_CANARY=$(epoch); marca CANARY_CREADO; log "Hash canary (v2): $CANARY"
  fi
  P95="-"
  [[ -n "$CANARY" ]] && P95=$(promql_valor "histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace=\"produccion\",service=\"pedidos\",route=\"/pedidos\",rollouts_pod_template_hash=\"$CANARY\"}[1m])))")
  RUNS=$(kubectl -n produccion get analysisrun -o json | jq -r --arg h "$CANARY" \
    '[.items[] | select(.metadata.labels["rollouts-pod-template-hash"]==$h or ($h!="" and (.metadata.name|contains($h))))] | map("\(.metadata.name)=\(.status.phase // "Pending")") | join(" ")')
  [[ -n "$RUNS" && -z "$T_ANALISIS" ]] && { T_ANALISIS=$(epoch); marca ANALISIS_INICIO; }
  log "fase=$FASE paso=$PASO abortado=$ABORT p95_canary=${P95}s analisis=[$RUNS]"
  if [[ "$ABORT" == "true" ]]; then marca ROLLOUT_ABORTADO; break; fi
  sleep 10
done
T_ABORT=$(epoch)

seccion "Resultado"
correr kubectl -n produccion get rollout pedidos -o wide
correr kubectl -n produccion get analysisrun
FALLIDO=$(kubectl -n produccion get analysisrun -o json | jq -r '[.items[] | select(.status.phase=="Failed" or .status.phase=="Error")] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // ""')
if [[ -n "$FALLIDO" ]]; then
  kubectl -n produccion get analysisrun "$FALLIDO" -o yaml > "$EVIDENCIAS/analysisrun-fallido-$FALLIDO.yaml"
  kubectl -n produccion get analysisrun "$FALLIDO" -o json | jq -r '.status.metricResults[] | "  metrica=\(.name) fase=\(.phase) fallos=\(.failed // 0) valores=\([.measurements[]?.value] | join(","))"' | tee -a "$LOG"
fi
sleep 20
correr kubectl -n produccion get pods -l app=pedidos -L rollouts-pod-template-hash
MSG=$(kubectl -n produccion get rollout pedidos -o jsonpath='{.status.message}')
RES="$EVIDENCIAS/resumen-canary-$(date +%Y%m%d-%H%M%S).md"
cat > "$RES" <<EOF
# Reversion del canary por metricas ($(ahora))

| Dato | Valor |
|---|---|
| Rollout | pedidos (namespace produccion) |
| Fallo inducido | v2 con LATENCIA_EXTRA_MS=700 (regresion de latencia) |
| Hash estable / canary | $ESTABLE / ${CANARY:-?} |
| AnalysisRun fallido | ${FALLIDO:-no encontrado} |
| Mensaje del Rollout | ${MSG} |
| Fallo publicado en Git -> canary creado | $( [[ -n "$T_CANARY" ]] && duracion "$T0" "$T_CANARY" || echo "?") |
| Fallo publicado -> reversion automatica (abort) | $(duracion "$T0" "$T_ABORT") |
| Intervencion humana | ninguna (Argo Rollouts aborto y devolvio el trafico a la version estable) |

Registro completo: ${LOG#$P10_DIR/}
EOF
cat "$RES" | tee -a "$LOG"
log "Ahora deje Git consistente: ./P10/scripts/demo-canary.sh revertir"
