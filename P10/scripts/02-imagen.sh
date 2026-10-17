#!/usr/bin/env bash
# Construye y publica la imagen unica de los servicios (pedidos, pagos,
# inventario y generador) en Artifact Registry, con version fija.
#   ./P10/scripts/02-imagen.sh
source "$(dirname "$0")/lib.sh"
LOG="$EVIDENCIAS/imagen-$(date +%Y%m%d-%H%M%S).log"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet >/dev/null 2>&1
seccion "docker build $IMAGEN:$VERSION_IMAGEN"
correr docker build -t "$IMAGEN:$VERSION_IMAGEN" "$P10_DIR/servicios"
seccion "Prueba rapida de la imagen (pedidos responde /salud y expone metricas)"
docker rm -f p10-prueba >/dev/null 2>&1 || true
docker run -d --name p10-prueba -p 18080:8080 -e OTEL_SERVICE_NAME=pedidos \
  -e OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317 "$IMAGEN:$VERSION_IMAGEN" >/dev/null
sleep 4
curl -sf localhost:18080/salud | tee -a "$LOG"; echo | tee -a "$LOG"
curl -sf localhost:18080/metrics | grep -c '^http_server' | sed 's/^/series http_server_*: /' | tee -a "$LOG"
docker logs p10-prueba 2>&1 | tail -n 2 | tee -a "$LOG"
docker rm -f p10-prueba >/dev/null
seccion "docker push"
correr docker push "$IMAGEN:$VERSION_IMAGEN"
log "Imagen publicada: $IMAGEN:$VERSION_IMAGEN"
log "Siguiente paso: ./P10/scripts/bootstrap.sh"
