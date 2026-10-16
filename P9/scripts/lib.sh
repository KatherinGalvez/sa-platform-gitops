#!/usr/bin/env bash
# Funciones comunes. Se incluye desde los demas scripts:  source "$(dirname "$0")/lib.sh"
set -euo pipefail

P9_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

if [[ ! -f "$P9_DIR/p9.env" ]]; then
  echo "ERROR: falta $P9_DIR/p9.env  (copie p9.env.ejemplo a p9.env y ajustelo)" >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source "$P9_DIR/p9.env"; set +a
export TZ="${TZ:-America/Guatemala}"
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

EVIDENCIAS="$P9_DIR/evidencias"
mkdir -p "$EVIDENCIAS"
# LOG puede venir heredado (prueba-dr.sh) para que todo quede en un solo registro
LOG="${LOG:-$EVIDENCIAS/registro-$(date +%Y%m%d-%H%M%S).log}"
export LOG

ahora()       { date '+%Y-%m-%d %H:%M:%S %Z'; }
epoch()       { date +%s; }
log()         { echo "[$(ahora)] $*" | tee -a "$LOG"; }
marca()       { local e; e=$(epoch); echo "[$(ahora)] MARCA $1 epoch=$e" | tee -a "$LOG"; }
seccion()     { echo | tee -a "$LOG"; echo "===== $* =====" | tee -a "$LOG"; }
duracion()    { local s=$(( $2 - $1 )); printf '%dm %02ds (%ds)' $((s/60)) $((s%60)) "$s"; }
correr()      { log "\$ $*"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

tf_init() {
  # $1 = carpeta (persistente | cluster)
  terraform -chdir="$P9_DIR/terraform/$1" init -input=false -reconfigure \
    -backend-config="bucket=$BUCKET_ESTADO" \
    -backend-config="prefix=p9/$1" >/dev/null
}

TF_VARS_CLUSTER=(
  -var="project_id=$PROYECTO" -var="region=$REGION" -var="zona=$ZONA"
  -var="estado_bucket=$BUCKET_ESTADO" -var="cluster_name=$CLUSTER"
  -var="tipo_maquina=$TIPO_MAQUINA" -var="nodos=$NODOS"
  -var="repo_url=$REPO_URL" -var="repo_rama=$REPO_RAMA" -var="gitops_ruta=$GITOPS_RUTA"
)

credenciales_cluster() {
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONA" --project "$PROYECTO" >/dev/null 2>&1
}

psql_datos() {
  # $1 = namespace, $2 = SQL
  kubectl -n "$1" exec postgres-0 -c postgres -- sh -c "psql -U \"\$POSTGRES_USER\" -d p9 -At -F '|' -c \"$2\""
}

huella_datos() {
  # Resumen verificable del CONTENIDO (no solo del volumen)
  local ns="${1:-datos}"
  psql_datos "$ns" "SELECT 'pedidos_filas=' || count(*) || ' pedidos_md5=' || coalesce(md5(string_agg(id||':'||cliente||':'||producto||':'||total, ',' ORDER BY id)),'vacio') FROM pedidos"
  psql_datos "$ns" "SELECT 'marcas_filas=' || count(*) || ' marca_max_id=' || coalesce(max(id),0) || ' ultima_marca=' || coalesce(to_char(max(creado) AT TIME ZONE 'America/Guatemala','YYYY-MM-DD HH24:MI:SS'),'ninguna') FROM marcas"
}

servicio_responde() {
  # Consulta la API a traves del proxy del API server (no requiere IP publica)
  kubectl get --raw "/api/v1/namespaces/datos/services/servicio-datos:3000/proxy/pedidos?select=id&limit=1" >/dev/null 2>&1
}
