#!/usr/bin/env bash
# =============================================================================
# DEMOSTRACION: alerta por consumo del presupuesto de error y recorrido
# ALERTA -> TRAZA -> REGISTRO.
#
#   ./P10/scripts/demo-alerta.sh            # rompe la pasarela de pagos (90 %) y espera la alerta
#   ./P10/scripts/demo-alerta.sh revertir   # repara pagos y mide la recuperacion
#
# El usuario ve "pedido fallido" (502 en pedidos), pero la causa esta dos
# saltos mas abajo: pagos responde 503 porque la pasarela no contesta. Solo
# la traza (pedidos -> pagos) y el registro de pagos lo muestran.
# =============================================================================
source "$(dirname "$0")/lib.sh"
ARCHIVO="$P10_DIR/gitops/produccion/pagos-inventario.yaml"
credenciales
reenviar observabilidad prometheus-operated 19090:9090
ALERTA="PedidosDisponibilidadQuemaRapida"

estado_alerta() {
  promql "ALERTS{alertname=\"$ALERTA\"}" | jq -r '.data.result[0].metric.alertstate // "inactiva"'
}

if [[ "${1:-}" == "revertir" ]]; then
  LOG="$EVIDENCIAS/alerta-revertir-$(date +%Y%m%d-%H%M%S).log"
  # Solo la primera aparicion (pagos); inventario no se toca
  sed -i '0,/- { name: FALLA_PORCENTAJE, value: "90" }/s//- { name: FALLA_PORCENTAJE, value: "0" }/' "$ARCHIVO"
  marca REPARACION_PUBLICADA; T0=$(epoch)
  publicar_cambio "P10: reparar pagos (fin de la demo de alerta)" "$ARCHIVO"
  kubectl -n produccion rollout status deploy/pagos --timeout=5m | tee -a "$LOG"
  marca PAGOS_REPARADO
  until awk -v v="$(promql_valor 'sli:disponibilidad:ratio_rate5m')" 'BEGIN{exit !(v ~ /^[0-9.]+$/ && v+0 >= 0.99)}'; do
    log "SLI 5m=$(promql_valor 'sli:disponibilidad:ratio_rate5m') alerta=$(estado_alerta)"; sleep 20
  done
  marca SLI_RECUPERADO
  log "Errores -> 0 al desplegarse pagos; SLI 5m >= 99 % tras $(duracion "$T0" "$(epoch)")"
  until [[ "$(estado_alerta)" == "inactiva" ]]; do log "alerta=$(estado_alerta)"; sleep 20; done
  marca ALERTA_RESUELTA
  log "Alerta resuelta tras $(duracion "$T0" "$(epoch)") desde la reparacion"
  exit 0
fi

LOG="$EVIDENCIAS/alerta-$(date +%Y%m%d-%H%M%S).log"
seccion "Estado inicial"
log "SLI disponibilidad 5m: $(promql_valor 'sli:disponibilidad:ratio_rate5m')  alerta: $(estado_alerta)"

seccion "Romper la pasarela de pagos (FALLA_PORCENTAJE=90) via Git"
sed -i '0,/- { name: FALLA_PORCENTAJE, value: "0" }/s//- { name: FALLA_PORCENTAJE, value: "90" }/' "$ARCHIVO"
git -C "$REPO_DIR" diff | tee -a "$LOG"
marca FALLO_PUBLICADO; T0=$(epoch)
publicar_cambio "P10: fallo inducido en pagos (pasarela 90 % caida) para la demo de alerta" "$ARCHIVO"
kubectl -n produccion rollout status deploy/pagos --timeout=5m | tee -a "$LOG"
marca FALLO_ACTIVO; T1=$(epoch)

seccion "Esperando la alerta (rapida: burn rate 1h y 5m > 14.4, for 1m) - hasta 25 min"
T_PEND=""; T_FIRE=""
LIMITE=$(( $(epoch) + 1500 ))
while (( $(epoch) < LIMITE )); do
  E=$(estado_alerta)
  [[ "$E" == "pending" && -z "$T_PEND" ]] && { T_PEND=$(epoch); marca ALERTA_PENDING; }
  log "burn5m=$(promql_valor 'slo:disponibilidad:burn_rate5m') burn1h=$(promql_valor 'slo:disponibilidad:burn_rate1h') SLI5m=$(promql_valor 'sli:disponibilidad:ratio_rate5m') alerta=$E"
  if [[ "$E" == "firing" ]]; then T_FIRE=$(epoch); marca ALERTA_FIRING; break; fi
  sleep 20
done

seccion "Pistas para el recorrido (las mismas que se siguen en Grafana)"
reenviar observabilidad tempo 13200:3200
reenviar observabilidad loki 13100:3100
TRAZA=$(curl -sG --max-time 10 http://localhost:13200/api/search \
  --data-urlencode 'q={ resource.service.name = "pagos" && status = error }' --data-urlencode limit=1 \
  | jq -r '.traces[0].traceID // ""')
log "Traza con error (Tempo): ${TRAZA:-no encontrada}"
if [[ -n "$TRAZA" ]]; then
  curl -sG --max-time 10 http://localhost:13100/loki/api/v1/query_range \
    --data-urlencode "query={k8s_namespace_name=\"produccion\"} | trace_id=\"$TRAZA\"" \
    --data-urlencode "since=30m" --data-urlencode limit=20 \
    | jq -r '.data.result[].values[][1]' | tee "$EVIDENCIAS/registros-traza-$TRAZA.json" | tee -a "$LOG"
fi

RES="$EVIDENCIAS/resumen-alerta-$(date +%Y%m%d-%H%M%S).md"
cat > "$RES" <<EOF
# Alerta por presupuesto de error ($(ahora))

| Dato | Valor |
|---|---|
| Fallo inducido | pagos con FALLA_PORCENTAJE=90 (pasarela de pago caida, responde 503) |
| Sintoma para el usuario | POST /pedidos responde 502 |
| Fallo publicado en Git -> pods de pagos con el fallo | $(duracion "$T0" "$T1") |
| Fallo activo -> alerta pending (primera senal) | $( [[ -n "$T_PEND" ]] && duracion "$T1" "$T_PEND" || echo "?") |
| Fallo activo -> alerta $ALERTA firing | $( [[ -n "$T_FIRE" ]] && duracion "$T1" "$T_FIRE" || echo "no disparo en 25 min") |
| Traza de ejemplo | ${TRAZA:-?} |
| Registros de esa traza | evidencias/registros-traza-${TRAZA:-?}.json |

El recorrido manual en Grafana (alerta -> tablero -> traza -> registro) se
cronometra en el video; anote el tiempo en docs/INFORME-OPERACION.md.
Registro completo: ${LOG#$P10_DIR/}
EOF
cat "$RES" | tee -a "$LOG"
log "Haga ahora el recorrido en Grafana. Al terminar: ./P10/scripts/demo-alerta.sh revertir"
