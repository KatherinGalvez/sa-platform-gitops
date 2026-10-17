# Runbook: `PedidosDisponibilidadQuemaRapida` / `PedidosDisponibilidadQuemaLenta`

**Qué significa:** demasiados pedidos responden con error 5xx.
El cliente pulsó *Comprar* y recibió un error, así que la tienda está perdiendo ventas.

| Severidad | Condición | Por qué amerita intervención |
|---|---|---|
| critical (Quema rápida) | burn rate 1h y 5m > 14.4 | A este ritmo el presupuesto mensual (1 %) se agota en ~2 días; cada minuto son pedidos perdidos |
| warning (Quema lenta) | burn rate 6h y 30m > 6 | Una degradación pequeña pero sostenida gastará el mes en ~5 días; se atiende en horario laboral |

## 1. Confirmar el impacto (30 s)
- Grafana → **P10 - Tienda: cuatro señales de oro y SLO**.
  - Fila **SLO**: confirmar que el SLI está por debajo de 99 % y que el burn rate sube.
  - Panel **3. ERRORES**: ver **qué servicio** tiene errores.
  - Si solo `pedidos` muestra 5xx, el error nace en pedidos.
  - Si `pagos` o `inventario` también muestran 5xx, pedidos solo los propaga como 502.
- Fila **Métricas de negocio**: el panel *Pedidos no completados por motivo* dice en qué paso falla, por ejemplo `pagos_error`, `inventario_error` o `error_interno`.

## 2. De la alerta a la traza (1 min)
- Fila **Del síntoma a la causa** → tabla *Trazas con error recientes*, y clic en una traza.
- También desde **Explore → Tempo**, con la consulta TraceQL:
  ```
  { resource.service.name = "pedidos" && status = error }
  ```
- En la cascada de spans, el **span más profundo en rojo** es la causa.
  Ejemplo: `pedidos POST /pedidos` → `cobrar_pago` → `pagos POST /cobrar` → `consultar_pasarela` (error).

## 3. De la traza al registro (30 s)
- En el span, botón **Logs for this span**. Abre Loki con `{k8s_namespace_name="produccion"} | trace_id="<id>"`.
- El registro JSON del servicio culpable dice el motivo, por ejemplo:
  `"message": "la pasarela de pago no respondio", "error": "timeout pasarela"`.
- Consulta directa por campo en Loki:
  ```
  {service_name="pagos"} | level="ERROR"
  ```

## 4. Mitigar
| Causa encontrada | Acción |
|---|---|
| Un despliegue reciente de **pedidos** | Normalmente el canary ya lo revirtió (`kubectl -n produccion get rollout pedidos`). Si no: `kubectl argo rollouts abort pedidos -n produccion` y revertir el commit en Git |
| Cambio de configuración en **pagos/inventario** (Git) | `git revert <commit>` y `git push`; ArgoCD lo aplica (< 3 min, o de inmediato con *Refresh*) |
| Pasarela de pago externa caída | Avisar al proveedor; comunicar a negocio que los pedidos fallan en el cobro |
| Pods caídos / sin recursos | `kubectl -n produccion get pods`, `kubectl describe pod`, revisar el panel **4. SATURACIÓN** |

## 5. Verificar la recuperación
- El panel **3. ERRORES** vuelve a 0 y `sli:disponibilidad:ratio_rate5m` vuelve a ≥ 0.99.
- La alerta se resuelve sola cuando el burn rate de 5m baja de 14.4, unos 5 minutos después de corregir.
- Anotar en el informe de operación: hora de inicio, hora de detección, causa, quién lo resolvió y presupuesto consumido.
