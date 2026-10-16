#!/usr/bin/env bash
# =============================================================================
# PRUEBA DE RESTAURACION DE DATOS
#
#   ./P9/scripts/prueba-restauracion-datos.sh
#
# 1. Registra la huella del contenido (md5 de pedidos, ultima marca).
# 2. PERDIDA: borra todas las filas de pedidos y marcas (error humano / bug).
# 3. Restaura el ULTIMO RESPALDO PROGRAMADO en un namespace aparte
#    (datos-restaurado) sin tocar produccion, y verifica el contenido real.
# 4. Repara produccion copiando las tablas desde la copia restaurada.
# 5. Calcula el RPO real con la ultima marca recuperada.
# =============================================================================
source "$(dirname "$0")/lib.sh"
SELLO=$(date +%Y%m%d-%H%M%S)
LOG="$EVIDENCIAS/restauracion-datos-$SELLO.log"
NS_R="datos-restaurado"
credenciales_cluster

seccion "1. Estado inicial"
ULTIMO=$(kubectl -n velero get backups -l velero.io/schedule-name=velero-horario \
  -o jsonpath='{range .items[?(@.status.phase=="Completed")]}{.status.startTimestamp}{" "}{.metadata.name}{"\n"}{end}' | sort | tail -1)
[[ -z "$ULTIMO" ]] && { log "No hay respaldos programados completados todavia."; exit 1; }
RESPALDO=${ULTIMO#* }
log "Respaldo programado mas reciente: $RESPALDO (inicio ${ULTIMO%% *})"
correr velero backup describe "$RESPALDO" --details
huella_datos datos | tee -a "$LOG" | tee "$EVIDENCIAS/huella-antes-borrado-$SELLO.txt"
MAX_ID_ANTES=$(psql_datos datos "SELECT max(id) FROM marcas")

seccion "2. PERDIDA DE DATOS"
T0=$(epoch); T0_UTC=$(date -u -d "@$T0" '+%Y-%m-%d %H:%M:%S+00')
marca PERDIDA_DATOS
psql_datos datos "DELETE FROM pedidos; DELETE FROM marcas;" | tee -a "$LOG"
log "Contenido despues del borrado:"
huella_datos datos | tee -a "$LOG"

seccion "3. Restauracion desde el respaldo (namespace $NS_R)"
kubectl delete namespace "$NS_R" --wait=true >/dev/null 2>&1 || true
correr velero restore create "prueba-datos-$SELLO" \
  --from-backup "$RESPALDO" \
  --include-namespaces datos \
  --namespace-mappings "datos:$NS_R" \
  --exclude-resources cronjobs.batch,jobs.batch,sealedsecrets.bitnami.com,events \
  --wait
correr velero restore describe "prueba-datos-$SELLO"
kubectl -n "$NS_R" rollout status statefulset/postgres --timeout=10m | tee -a "$LOG"
marca RESTAURACION_LISTA
log "Contenido restaurado (verificacion del CONTENIDO, no solo del volumen):"
huella_datos "$NS_R" | tee -a "$LOG" | tee "$EVIDENCIAS/huella-restaurada-$SELLO.txt"
log "Muestra de filas restauradas:"
psql_datos "$NS_R" "SELECT id, cliente, producto, total FROM pedidos ORDER BY id LIMIT 5" | tee -a "$LOG"

seccion "4. Reparacion de produccion"
kubectl -n "$NS_R" exec postgres-0 -c postgres -- sh -c 'pg_dump -U "$POSTGRES_USER" -d p9 --data-only -t pedidos -t marcas' \
  | kubectl -n datos exec -i postgres-0 -c postgres -- sh -c 'psql -U "$POSTGRES_USER" -d p9 -q -v ON_ERROR_STOP=1' 2>&1 | tee -a "$LOG"
psql_datos datos "SELECT setval('pedidos_id_seq', (SELECT max(id) FROM pedidos)), setval('marcas_id_seq', GREATEST((SELECT max(id) FROM marcas), $MAX_ID_ANTES))" >/dev/null
marca PRODUCCION_REPARADA
log "Produccion despues de reparar:"
huella_datos datos | tee -a "$LOG"

seccion "5. Calculo del RPO real"
FILA=$(psql_datos "$NS_R" "SELECT id || '|' || extract(epoch from creado)::bigint || '|' || to_char(creado AT TIME ZONE 'America/Guatemala','YYYY-MM-DD HH24:MI:SS') FROM marcas ORDER BY id DESC LIMIT 1")
ID_REC=${FILA%%|*}; RESTO=${FILA#*|}; EP_REC=${RESTO%%|*}; ISO_REC=${RESTO#*|}
A=$(grep -o 'pedidos_md5=[a-z0-9]*' "$EVIDENCIAS/huella-antes-borrado-$SELLO.txt")
B=$(grep -o 'pedidos_md5=[a-z0-9]*' "$EVIDENCIAS/huella-restaurada-$SELLO.txt")
[[ "$A" == "$B" ]] && V="IDENTICO al original" || V="DIFERENTE al original"
{
  echo "| Medida | Valor |"
  echo "|---|---|"
  echo "| Respaldo usado | $RESPALDO |"
  echo "| Momento de la perdida | $(date -d "@$T0" '+%Y-%m-%d %H:%M:%S %Z') |"
  echo "| Ultima marca recuperada | id $ID_REC, $ISO_REC |"
  echo "| **RPO real** | **$(duracion "$EP_REC" "$T0")** |"
  echo "| Filas de marcas no recuperadas | $(( MAX_ID_ANTES - ID_REC )) (escritas despues del respaldo) |"
  echo "| Tabla pedidos restaurada | $V ($B) |"
} | tee -a "$LOG" | tee "$EVIDENCIAS/resumen-restauracion-$SELLO.md"

log "Deje $NS_R para las capturas. Para borrarlo: kubectl delete ns $NS_R"
