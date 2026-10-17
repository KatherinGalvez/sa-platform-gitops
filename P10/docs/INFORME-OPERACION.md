# Informe de operación: Práctica 10

> Tiempos **medidos** en el clúster `p10-obs`. Se toman de los archivos `evidencias/resumen-*.md` y `evidencias/*.log`, con sus marcas `MARCA ... epoch=`.
> Los campos marcados ⟨COMPLETAR⟩ se llenan con esos archivos después de correr las demostraciones.

## 1. SLO declarados
| SLO | Objetivo | Ventana | Por qué ese número |
|---|---|---|---|
| Disponibilidad de `POST /pedidos` | 99 % sin 5xx (402/409 no cuentan) | 30 días | Un clúster zonal de 2 nodos no sostiene 99.9 %. El 1 % (unas 7 h al mes) permite desplegar con canary varias veces por semana y aun así detecta degradaciones del 2 % en un día |
| Latencia de `POST /pedidos` | 95 % en < 500 ms | 30 días | Un pedido sano tarda 80–150 ms y 500 ms deja más de 3 veces de margen. Es 95 % y no 99 % porque la pasarela de pago es externa y variable. El canary usa el mismo umbral |

Detalle y reglas: [SLO.md](SLO.md).

## 2. Fallo inducido
Se provocaron dos fallos, ambos **a través de Git** (ArgoCD los aplicó) y ambos distintos al de la Práctica 8:

- **A. Regresión de latencia en el canary**
  - La versión `v2` de pedidos agrega 700 ms por pedido (`LATENCIA_EXTRA_MS=700`, `scripts/demo-canary.sh`).
  - No produce errores: solo una métrica de percentil sobre los pods del canary podía detectarla.
- **B. Caída parcial de la pasarela de pago**
  - `pagos` responde 503 en el 90 % de los cobros (`FALLA_PORCENTAJE=90`, `scripts/demo-alerta.sh`).
  - El usuario solo ve "pedido fallido" (502 en pedidos); la causa está dos saltos más abajo.

## 3. Tiempo de detección
| Fallo | Inicio (marca) | Primera señal | Minutos |
|---|---|---|---|
| A canary | `FALLO_PUBLICADO` ⟨COMPLETAR hora⟩ | AnalysisRun `⟨COMPLETAR nombre⟩` en estado Failed y `ROLLOUT_ABORTADO` ⟨hora⟩ | ⟨COMPLETAR⟩ |
| B pagos | `FALLO_ACTIVO` ⟨COMPLETAR hora⟩ | `ALERTA_PENDING` ⟨hora⟩ → `ALERTA_FIRING` ⟨hora⟩ | ⟨COMPLETAR⟩ |

## 4. Recorrido hasta la causa (fallo B)
Pasos exactos, cronometrados en el video (minuto ⟨COMPLETAR⟩):
1. Prometheus → *Alerts*: `PedidosDisponibilidadQuemaRapida` en *firing*. Abrir el `runbook_url`.
2. Grafana → tablero **P10 - Tienda** → panel *3. ERRORES*: `pedidos` y `pagos` con 5xx, `inventario` en 0.
   El panel *Pedidos no completados por motivo* muestra `pagos_error`.
3. Tabla *Trazas con error recientes* → clic en una traza.
   La cascada muestra `pedidos POST /pedidos` → `cobrar_pago` → `pagos POST /cobrar` → `consultar_pasarela` **en rojo**.
4. En el span de pagos: **Logs for this span** → Loki muestra
   `{"level":"ERROR","service":"pagos","message":"la pasarela de pago no respondio","error":"timeout pasarela ..."}` con el mismo `trace_id`.

**Tiempo total, de la alerta al registro: ⟨COMPLETAR⟩ (objetivo: menos de 3 min).**

## 5. Tiempo de recuperación
| Fallo | Quién o qué lo resolvió | Minutos hasta el estado estable |
|---|---|---|
| A canary | **Argo Rollouts, sin intervención humana**: el AnalysisRun falló, abortó el canary y el 100 % del tráfico volvió a v1. Luego, `demo-canary.sh revertir` dejó Git consistente | ⟨COMPLETAR (de `FALLO_PUBLICADO` a `ROLLOUT_ABORTADO`)⟩ |
| B pagos | El operador, siguiendo el runbook: revirtió el cambio en Git y ArgoCD lo aplicó | ⟨COMPLETAR (de `REPARACION_PUBLICADA` a `SLI_RECUPERADO`)⟩; la alerta se resolvió en ⟨COMPLETAR⟩ |

## 6. Alerta faltante o sobrante
- **Faltante, que habría acortado la detección del fallo B:**
  - La alerta rápida necesita que la ventana de **1 h** supere 14.4x, así que tarda unos 10 minutos con el 90 % de errores.
  - La señal ya era evidente en el minuto 1, porque el burn rate de 5m llegó a ~88x. Ese retraso es el precio de no despertar a nadie por picos.
  - Mejora concreta: una alerta de *dependencia*, `rate(pedidos_rechazados_total{motivo="pagos_error"}[5m]) > 0.5`, enviada al canal del equipo de pagos sin paginar.
  - También una sonda **blackbox** externa, porque el SLI se mide en el servidor y no ve fallas antes de pedidos.
- **Sobrante o ruido:**
  - Las reglas por defecto de kube-prometheus-stack (CPU, memoria, nodos) se desactivaron: alertan sobre causas, no sobre síntomas del usuario.
  - Durante la demo, la alerta *lenta* (6h/30m) también se disparó con el mismo incidente.
  - Se podría inhibir en Alertmanager cuando la rápida está activa, para no notificar dos veces la misma causa.
- **Mejora a la instrumentación:**
  - Exponer *exemplars* (formato OpenMetrics) en el histograma, para saltar de un punto lento del gráfico directamente a su traza.
  - Persistir Prometheus y Loki (hoy usan `emptyDir`), porque al reanudar el clúster se pierde la historia del SLO.
