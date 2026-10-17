# Runbook: `PedidosLatenciaQuemaRapida` / `PedidosLatenciaQuemaLenta`

**Qué significa:** demasiados pedidos tardan más de 500 ms.
El cliente espera con la pantalla congelada y una parte abandona la compra o la reintenta, lo que duplica la carga.

| Severidad | Condición | Por qué amerita intervención |
|---|---|---|
| critical | burn rate 1h y 5m > 14.4 (más del 72 % de pedidos lentos) | La tienda es prácticamente inutilizable |
| warning | burn rate 6h y 30m > 6 (más del 30 % lentos sostenido) | Degradación que agotará el presupuesto de latencia en días |

## 1. Confirmar y ubicar (30 s)
- Grafana → **P10 - Tienda** → panel **1. LATENCIA**: ¿qué servicio subió su p95/p99?
- Panel **Latencia p95 por versión**: si una sola versión (hash) está lenta, es un **despliegue**.
  El canary debió abortarlo; confirmarlo con `kubectl -n produccion get rollout pedidos`.
- Panel **4. SATURACIÓN**: si las *peticiones en curso* suben, el servicio se está encolando, por falta de CPU o por una dependencia lenta.

## 2. Traza (1 min)
- Explore → Tempo, con la consulta:
  ```
  { resource.service.name = "pedidos" && duration > 500ms }
  ```
- En la cascada, buscar el span que ocupa casi todo el tiempo.
  - Si es `pagos POST /cobrar` o `inventario POST /reservar`, la lentitud está en esa dependencia.
  - Si es el span raíz de pedidos sin hijos lentos, la lentitud está en el propio pedidos (código o versión nueva).

## 3. Registro (30 s)
- Desde el span: **Logs for this span**.
- Consulta en Loki para ver los pedidos más lentos:
  ```
  {service_name="pedidos"} | duration_ms > 500
  ```
- El campo `version` del registro indica qué versión atendió la petición.

## 4. Mitigar
| Causa | Acción |
|---|---|
| Versión nueva lenta | El canary la aborta solo. Revertir Git: `./P10/scripts/demo-canary.sh revertir` o `git revert` |
| Dependencia lenta (pagos/inventario) | Revisar su último cambio en Git y revertirlo; si es externa, avisar al proveedor |
| Saturación de CPU | Escalar réplicas en Git (`replicas:`) y revisar límites |

## 5. Verificar
- El p95 vuelve a menos de 500 ms y `sli:latencia:ratio_rate5m` vuelve a ≥ 0.95. La alerta se resuelve sola.
