# Práctica 10: Observabilidad y operación (del síntoma a la causa)

**Carnet:** 202006633 · **Entorno propio:** clúster GKE `p10-obs` (separado de `p9-dr`, como indicó el auxiliar) · proyecto `sa-p6-202006633`, zona `us-central1-a`

Hay una tienda con tres microservicios **instrumentados con OpenTelemetry**: `pedidos` llama a `inventario` y a `pagos`.
Esos servicios producen métricas, trazas y registros correlacionados por `trace_id`.
Todo el stack (Prometheus, Alertmanager, Grafana, Loki, Tempo, Collector, Argo Rollouts y Kyverno) se despliega **por GitOps** (ArgoCD app-of-apps).
El canary de `pedidos` se promueve o se revierte según **métricas reales de Prometheus**.

## 4.1 Tabla de enlaces obligatoria

| Ítem | Enlace o dato |
|---|---|
| Repositorio de código | https://github.com/KatherinGalvez/sa-platform-gitops (carpeta [`/P10`](https://github.com/KatherinGalvez/sa-platform-gitops/tree/main/P10)) |
| Repositorio GitOps | https://github.com/KatherinGalvez/sa-platform-gitops (manifiestos en [`/P10/gitops`](https://github.com/KatherinGalvez/sa-platform-gitops/tree/main/P10/gitops); app raíz [`p10-raiz`](gitops/bootstrap/raiz.yaml)) |
| Servicios instrumentados | `pedidos`, `pagos`, `inventario` en el namespace **`produccion`** ([código](servicios/); instrumentación común en [`servicios/telemetria.py`](servicios/telemetria.py)) |
| AnalysisTemplate por métricas | **`pedidos-canary-salud`**: [`P10/gitops/produccion/analysis-template.yaml`](gitops/produccion/analysis-template.yaml) (usado por el Rollout [`pedidos`](gitops/produccion/pedidos-rollout.yaml)) |
| Consultas del análisis | Ver el bloque [Consultas](#consultas-que-deciden-la-promocion) (tasa de errores 5xx del canary < 5 % y p95 del canary < 500 ms) |
| SLO declarados | **Disponibilidad:** 99 % de `POST /pedidos` sin 5xx, ventana 30 días · **Latencia:** 95 % de `POST /pedidos` en < 500 ms, ventana 30 días ([justificación](docs/SLO.md)) |
| Reglas de alerta | [`P10/gitops/observabilidad/slo/reglas-slo.yaml`](gitops/observabilidad/slo/reglas-slo.yaml) (PrometheusRule `slo-pedidos`, namespace `observabilidad`) |
| Tablero | [`P10/gitops/observabilidad/slo/tablero-p10.json`](gitops/observabilidad/slo/tablero-p10.json) · captura: [`evidencias/img/tablero.png`](evidencias/img/tablero.png) |
| Reversión por métricas | AnalysisRun **`⟨COMPLETAR⟩`** (fase Failed) del Rollout **`pedidos`** ([evidencia](evidencias/)) |
| Recorrido síntoma a causa | [`evidencias/`](evidencias/) (`resumen-alerta-*.md`, `registros-traza-*.json`, capturas) · tiempo medido: **⟨COMPLETAR⟩** |
| Video demostrativo | ⟨COMPLETAR URL⟩ · minutaje abajo |

### Consultas que deciden la promoción

```promql
# 1) Tasa de errores 5xx SOLO del canary (successCondition: result[0] < 0.05)
(
  (sum(rate(http_server_requests_seconds_count{namespace="produccion",service="pedidos",route="/pedidos",status=~"5..",rollouts_pod_template_hash="{{args.canary-hash}}"}[1m])) or vector(0))
  /
  clamp_min(sum(rate(http_server_requests_seconds_count{namespace="produccion",service="pedidos",route="/pedidos",rollouts_pod_template_hash="{{args.canary-hash}}"}[1m])), 0.001)
) or vector(0)

# 2) Latencia p95 SOLO del canary (successCondition: result[0] < 0.5)
(
  histogram_quantile(0.95,
    sum by (le) (rate(http_server_requests_seconds_bucket{namespace="produccion",service="pedidos",route="/pedidos",rollouts_pod_template_hash="{{args.canary-hash}}"}[1m]))
  ) >= 0
) or vector(0)
```

- `canary-hash` viene de `podTemplateHashValue: Latest`.
- El PodMonitor copia la etiqueta del pod `rollouts-pod-template-hash` a cada serie.
- Cada métrica se mide 5 veces cada 20 s, con `failureLimit: 1`: si falla 2 veces, el Rollout se aborta y vuelve a la versión estable.

### Minutaje del video

| Minuto | Punto demostrado |
|---|---|
| ⟨00:00⟩ | ArgoCD: las 8 aplicaciones Synced/Healthy (todo por GitOps) |
| ⟨…⟩ | Una traza de extremo a extremo en Tempo (pedidos → inventario → pagos) y sus registros JSON en Loki |
| ⟨…⟩ | Tablero: SLO, presupuesto, cuatro señales de oro, negocio |
| ⟨…⟩ | Canary v2 (latencia +700 ms) → AnalysisRun Failed → reversión automática |
| ⟨…⟩ | Fallo en pagos → alerta por presupuesto → runbook → traza → registro (cronometrado) |
| ⟨…⟩ | Recuperación y verificador |

## Estructura

```
P10/
├── servicios/              pedidos.py pagos.py inventario.py generador.py telemetria.py Dockerfile requirements.txt
├── gitops/
│   ├── bootstrap/          argocd-values.yaml, raiz.yaml (lo único que se aplica a mano)
│   ├── apps/               app-of-apps por olas (-1 OCI, 0 rollouts/kps/kyverno, 1 telemetría/SLO/políticas, 2 producción)
│   ├── observabilidad/
│   │   ├── telemetria/     loki.yaml, tempo.yaml, otel-collector.yaml
│   │   └── slo/            podmonitor.yaml, reglas-slo.yaml, tablero-p10.json, kustomization.yaml
│   ├── plataforma/politicas/   políticas Kyverno (flujo de P8 conservado)
│   └── produccion/         pedidos-rollout.yaml, analysis-template.yaml, pagos-inventario.yaml, generador.yaml
├── scripts/                01-crear-cluster, 02-imagen, bootstrap, accesos, demo-canary, demo-alerta, evidencias, pausar, destruir
├── docs/                   SLO, INFORME-OPERACION, DIAGRAMA-TELEMETRIA, PREGUNTAS, PRESENTACION, runbooks/
├── evidencias/             registros y resúmenes con marcas de tiempo, img/ capturas
└── verificacion/           p10.conf, verificar_p10.sh (original), verificar_p10_corregido.sh, CORRECCION-VERIFICADOR.md
```

## Documentos

- [Definición y justificación de los SLO](docs/SLO.md)
- [Informe de operación](docs/INFORME-OPERACION.md) (los 6 campos)
- [Diagrama del flujo de telemetría](docs/DIAGRAMA-TELEMETRIA.md)
- Runbooks: [disponibilidad](docs/runbooks/RUNBOOK-disponibilidad-pedidos.md) · [latencia](docs/runbooks/RUNBOOK-latencia-pedidos.md)
- [Preguntas teóricas](docs/PREGUNTAS.md)
- [Guía de presentación y comandos](docs/PRESENTACION.md)
- [Error del script verificador y su corrección](verificacion/CORRECCION-VERIFICADOR.md)

## Cómo levantarlo desde cero (Cloud Shell)

```bash
cd ~/sa-platform-gitops && cp P10/p10.env.ejemplo P10/p10.env
./P10/scripts/01-crear-cluster.sh   # GKE p10-obs + Artifact Registry (~6 min)
./P10/scripts/02-imagen.sh          # docker build + push de la imagen tienda:1.0.0
./P10/scripts/bootstrap.sh          # ArgoCD + app raíz -> todo lo demás desde Git (~10 min)
./P10/scripts/accesos.sh            # Grafana 8080, ArgoCD 8081, Prometheus 8082, Rollouts 8083
```
