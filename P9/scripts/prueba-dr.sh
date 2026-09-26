#!/usr/bin/env bash
# =============================================================================
# PRUEBA DE RECUPERACION CRONOMETRADA (destruccion + reconstruccion completa)
#
#   ./P9/scripts/prueba-dr.sh
#
# T0 = inicio de la destruccion (el "incidente").
# RTO real  = momento en que la API responde con los datos restaurados - T0
# RPO real  = T0 - ultima marca (fila del CronJob) recuperada del respaldo
# Todo queda en evidencias/dr-<fecha>.log y evidencias/resumen-dr-<fecha>.md
# =============================================================================
source "$(dirname "$0")/lib.sh"
SELLO=$(date +%Y%m%d-%H%M%S)
export LOG="$EVIDENCIAS/dr-$SELLO.log"
export LOG_HEREDADO=1
RESUMEN="$EVIDENCIAS/resumen-dr-$SELLO.md"

credenciales_cluster

seccion "ESTADO ANTES DEL DESASTRE"
correr kubectl -n argocd get applications
log "Respaldos disponibles:"
velero backup get 2>&1 | tee -a "$LOG" || kubectl -n velero get backups | tee -a "$LOG"
ULTIMO_RESPALDO=$(kubectl -n velero get backups -l velero.io/schedule-name=velero-horario \
  -o jsonpath='{range .items[?(@.status.phase=="Completed")]}{.status.startTimestamp}{" "}{.metadata.name}{"\n"}{end}' | sort | tail -1)
log "Ultimo respaldo completado: ${ULTIMO_RESPALDO:-NINGUNO}"
[[ -z "$ULTIMO_RESPALDO" ]] && { log "No hay respaldos: ejecute 'velero backup create --from-schedule velero-horario --wait' primero"; exit 1; }
log "Huella de datos ANTES:"
huella_datos datos | tee -a "$LOG" | tee "$EVIDENCIAS/huella-antes-$SELLO.txt"
MAX_ID_ANTES=$(psql_datos datos "SELECT max(id) FROM marcas")

# ---- Desastre ----
T0=$(epoch); T0_ISO=$(date -d "@$T0" '+%Y-%m-%d %H:%M:%S %Z'); T0_UTC=$(date -u -d "@$T0" '+%Y-%m-%d %H:%M:%S+00')
"$P9_DIR/scripts/destruir.sh" --si
T1=$(epoch)

# ---- Reconstruccion (punto de entrada unico) ----
"$P9_DIR/scripts/bootstrap.sh"
T2=$(cat "$EVIDENCIAS/.ultimo_servicio_ok")

seccion "VERIFICACION DE DATOS RESTAURADOS"
huella_datos datos | tee -a "$LOG" | tee "$EVIDENCIAS/huella-despues-$SELLO.txt"
FILA=$(psql_datos datos "SELECT id || '|' || extract(epoch from creado)::bigint || '|' || to_char(creado AT TIME ZONE 'America/Guatemala','YYYY-MM-DD HH24:MI:SS') FROM marcas WHERE creado < '$T0_UTC' ORDER BY id DESC LIMIT 1")
ID_REC=${FILA%%|*}; RESTO=${FILA#*|}; EP_REC=${RESTO%%|*}; ISO_REC=${RESTO#*|}
PERDIDAS=$(( MAX_ID_ANTES - ID_REC ))
PED_ANTES=$(grep -o 'pedidos_md5=[a-z0-9]*' "$EVIDENCIAS/huella-antes-$SELLO.txt")
PED_DESP=$(grep -o 'pedidos_md5=[a-z0-9]*' "$EVIDENCIAS/huella-despues-$SELLO.txt")
[[ "$PED_ANTES" == "$PED_DESP" ]] && PED_OK="IDENTICO (contenido verificado)" || PED_OK="DIFERENTE"

log "Secretos tras la reconstruccion:"
"$P9_DIR/scripts/verificar-secretos.sh" | tee -a "$LOG"

RTO=$(duracion "$T0" "$T2"); RECON=$(duracion "$T1" "$T2"); DESTR=$(duracion "$T0" "$T1")
RPO=$(duracion "$EP_REC" "$T0")

cat > "$RESUMEN" <<EOF
# Resumen de la prueba de DR ($SELLO)

| Marca | Fecha y hora |
|---|---|
| T0 inicio de la destruccion (incidente) | $T0_ISO |
| T1 fin de la destruccion | $(date -d "@$T1" '+%Y-%m-%d %H:%M:%S %Z') |
| T2 API respondiendo con datos restaurados | $(date -d "@$T2" '+%Y-%m-%d %H:%M:%S %Z') |

| Medida | Valor |
|---|---|
| **RTO real (T2 - T0)** | **$RTO** |
| Destruccion (T1 - T0) | $DESTR |
| Reconstruccion (T2 - T1) | $RECON |
| Respaldo usado | ${ULTIMO_RESPALDO#* } (iniciado ${ULTIMO_RESPALDO%% *}) |
| Ultima marca recuperada | id $ID_REC, $ISO_REC |
| **RPO real (T0 - ultima marca recuperada)** | **$RPO** |
| Marcas perdidas (escritas despues del respaldo) | $PERDIDAS filas (id $((ID_REC+1)) a $MAX_ID_ANTES) |
| Tabla pedidos antes vs despues | $PED_OK |

Registro completo: \`evidencias/$(basename "$LOG")\`
EOF
seccion "RESUMEN"
cat "$RESUMEN" | tee -a "$LOG"
