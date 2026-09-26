#!/usr/bin/env bash
# =============================================================================
# PRUEBA DE PERDIDA DE NODO
#
#   ./P9/scripts/prueba-perdida-nodo.sh            # drena un nodo con replicas de la API (no el de la BD)
#   ./P9/scripts/prueba-perdida-nodo.sh --con-bd   # drena el nodo de PostgreSQL (mide el punto unico de fallo)
#
# Una sonda consulta la API cada segundo durante todo el drenaje y registra
# cada respuesta. Resultado: evidencias/perdida-nodo-<fecha>.log
# =============================================================================
source "$(dirname "$0")/lib.sh"
SELLO=$(date +%Y%m%d-%H%M%S)
LOG="$EVIDENCIAS/perdida-nodo-$SELLO.log"
SONDA="$EVIDENCIAS/sonda-$SELLO.log"
credenciales_cluster

NODO_BD=$(kubectl -n datos get pod postgres-0 -o jsonpath='{.spec.nodeName}')
if [[ "${1:-}" == "--con-bd" ]]; then
  NODO="$NODO_BD"
else
  NODO=$(kubectl -n datos get pods -l app=servicio-datos -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | grep -v "^$NODO_BD$" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
fi
[[ -z "$NODO" ]] && { log "No se encontro un nodo adecuado"; exit 1; }

seccion "Antes del drenaje (nodo elegido: $NODO; nodo de la BD: $NODO_BD)"
correr kubectl get nodes
correr kubectl -n datos get pdb
correr kubectl -n datos get pods -o wide

seccion "Sonda HTTP cada 1 s"
(
  while :; do
    if servicio_responde; then r="OK"; else r="FALLO"; fi
    echo "$(date '+%H:%M:%S') $r"
    sleep 1
  done
) > "$SONDA" 2>&1 &
PID_SONDA=$!
trap 'kill $PID_SONDA 2>/dev/null || true' EXIT
sleep 10

marca DRENAJE_INICIO
correr kubectl drain "$NODO" --ignore-daemonsets --delete-emptydir-data --timeout=600s
marca DRENAJE_FIN
correr kubectl -n datos get pods -o wide
correr kubectl get nodes
log "Nodo acordonado; se mantiene 60 s fuera de servicio..."
sleep 60
correr kubectl -n datos get pods -o wide

correr kubectl uncordon "$NODO"
marca NODO_REINCORPORADO
sleep 15
kill "$PID_SONDA" 2>/dev/null || true

seccion "Resultado de la sonda"
TOTAL=$(grep -cE 'OK|FALLO' "$SONDA" || true)
OK=$(grep -c ' OK$' "$SONDA" || true)
FALLOS=$(grep -c ' FALLO$' "$SONDA" || true)
DISP=$(awk -v o="$OK" -v t="$TOTAL" 'BEGIN{ if (t>0) printf "%.2f", 100*o/t; else print "0" }')
log "Consultas: $TOTAL   OK: $OK   FALLO: $FALLOS   Disponibilidad: $DISP %"
[[ "$FALLOS" -gt 0 ]] && { log "Fallos registrados:"; grep FALLO "$SONDA" | tee -a "$LOG"; }
log "Detalle segundo a segundo: ${SONDA#$P9_DIR/}"
