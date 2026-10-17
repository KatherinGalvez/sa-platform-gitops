#!/usr/bin/env bash
# Funciones comunes:  source "$(dirname "$0")/lib.sh"
set -euo pipefail

P10_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$P10_DIR/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

if [[ ! -f "$P10_DIR/p10.env" ]]; then
  echo "ERROR: falta $P10_DIR/p10.env  ->  cp $P10_DIR/p10.env.ejemplo $P10_DIR/p10.env" >&2
  exit 1
fi
set -a; source "$P10_DIR/p10.env"; set +a
export TZ="${TZ:-America/Guatemala}"
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

EVIDENCIAS="$P10_DIR/evidencias"
mkdir -p "$EVIDENCIAS"
LOG="${LOG:-$EVIDENCIAS/registro-$(date +%Y%m%d-%H%M%S).log}"

ahora()   { date '+%Y-%m-%d %H:%M:%S %Z'; }
epoch()   { date +%s; }
log()     { echo "[$(ahora)] $*" | tee -a "$LOG"; }
marca()   { echo "[$(ahora)] MARCA $1 epoch=$(epoch)" | tee -a "$LOG"; }
seccion() { echo | tee -a "$LOG"; echo "===== $* =====" | tee -a "$LOG"; }
duracion(){ local s=$(( $2 - $1 )); printf '%dm %02ds (%ds)' $((s/60)) $((s%60)) "$s"; }
correr()  { log "\$ $*"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

credenciales() {
  gcloud config set project "$PROYECTO" >/dev/null 2>&1
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONA" --project "$PROYECTO" >/dev/null
}

# Port-forward en segundo plano a un servicio; deja el PID en PF_PIDS.
PF_PIDS=()
reenviar() {  # $1=namespace $2=svc $3=puerto_local:puerto_remoto
  kubectl -n "$1" port-forward "svc/$2" "$3" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  sleep 3
}
cerrar_reenvios() { for p in "${PF_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; }
trap cerrar_reenvios EXIT

# Consulta instantanea a Prometheus (requiere reenviar observabilidad prometheus-operated 19090:9090)
promql() {
  curl -sG --max-time 10 --data-urlencode "query=$1" http://localhost:19090/api/v1/query
}
promql_valor() {
  promql "$1" | jq -r '.data.result[0].value[1] // "sin-datos"'
}

# Publica en Git un cambio de manifiesto (el cambio LO APLICA ArgoCD, no kubectl)
publicar_cambio() {  # $1=mensaje ; resto=archivos
  local msg="$1"; shift
  git -C "$REPO_DIR" add "$@"
  git -C "$REPO_DIR" commit -q -m "$msg"
  git -C "$REPO_DIR" push -q origin HEAD:main
  log "Git: '$msg' publicado ($(git -C "$REPO_DIR" rev-parse --short HEAD))"
  # Pedir a ArgoCD que lea Git ya (si no, lo hace solo en <= 3 min)
  kubectl -n argocd annotate application produccion argocd.argoproj.io/refresh=hard --overwrite >/dev/null
}
