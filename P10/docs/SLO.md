# Objetivos de nivel de servicio (SLO)

**Recorrido medido:** `POST /pedidos` del servicio **pedidos**.
Es lo que hace el usuario cuando compra: confirma el carrito y espera la respuesta.
En ese momento se llama a inventario y a pagos, así que un fallo de cualquiera de los tres servicios se ve aquí.
Por eso se mide desde el punto de entrada y no servicio por servicio, porque eso es lo que percibe el usuario.

| | SLO 1: Disponibilidad | SLO 2: Latencia |
|---|---|---|
| Lo que el usuario vive | "Le di *Comprar* y no me dio error" | "Le di *Comprar* y la respuesta fue inmediata" |
| Indicador (SLI) | pedidos **sin** respuesta 5xx / pedidos totales | pedidos respondidos en **< 500 ms** / pedidos totales |
| Objetivo | **99 %** | **95 %** |
| Ventana | **30 días** móviles | **30 días** móviles |
| Presupuesto de error | 1 % de pedidos (≈ 7 h 12 min de caída total al mes) | 5 % de pedidos lentos |
| Regla de registro del SLI | `sli:disponibilidad:ratio_rate5m` (y `sli:pedidos_errores:ratio_rate{5m,30m,1h,6h}`) | `sli:latencia:ratio_rate5m` (y `sli:pedidos_lentos:ratio_rate{5m,30m,1h,6h}`) |
| Presupuesto consumido | `slo:disponibilidad:presupuesto_consumido:ratio30d` / `..._restante` | `slo:latencia:presupuesto_consumido:ratio30d` / `..._restante` |
| Velocidad de consumo | `slo:disponibilidad:burn_rate{5m,30m,1h,6h}` | `slo:latencia:burn_rate{5m,30m,1h,6h}` |

Manifiesto: [`gitops/observabilidad/slo/reglas-slo.yaml`](../gitops/observabilidad/slo/reglas-slo.yaml)

## Por qué esos números y no otros

**99 % de disponibilidad, no 99.9 %**
- Hoy la tienda corre en un solo clúster zonal de 2 nodos, sin réplica en otra zona.
  Una actualización de nodo de GKE o un reinicio de pagos ya cuesta minutos.
  Prometer 99.9 % (43 min al mes) sería prometer algo que la infraestructura actual no puede sostener.
  El presupuesto se agotaría con el primer incidente y la alerta dejaría de significar algo.
- El 1 % (unas 7 h al mes) alcanza para desplegar varias veces por semana con canary.
  También es estricto: un error del 2 % sostenido un día entero ya consume dos tercios del mes.
- **No gastan presupuesto** las respuestas 402 (pago rechazado por fondos) ni 409 (sin stock).
  Son respuestas correctas del negocio, no fallas del sistema. Si contaran, la alerta se dispararía por clientes sin saldo.

**95 % en menos de 500 ms, medido en el p95 y no en el promedio**
- Un pedido sano tarda entre 80 y 150 ms: inventario (10–40 ms), pagos (20–80 ms) y la red.
  500 ms deja más de 3 veces de margen sobre lo normal.
  También está por debajo del umbral en que un usuario percibe que "se trabó" (alrededor de 1 s).
- 95 % y no 99 %, porque la pasarela de pago es externa y su latencia varía.
  Exigir 99 % convertiría en alerta la cola lenta normal de un tercero, algo que el equipo no puede corregir.
- El canary usa **el mismo umbral** (p95 < 500 ms) para que desplegar y alertar se rijan por la misma promesa.

## Cómo se alerta: por consumo del presupuesto, no por umbral instantáneo

Se sigue el esquema multiventana del libro de SRE de Google:

| Alerta | Condición | Significado | Acción |
|---|---|---|---|
| `PedidosDisponibilidadQuemaRapida` | burn 1h **y** burn 5m > 14.4 | Se consume el 2 % del presupuesto mensual en 1 hora; a ese ritmo se agota en ~2 días | **Página** (critical): intervenir ya |
| `PedidosDisponibilidadQuemaLenta` | burn 6h **y** burn 30m > 6 | Se consume el 5 % en 6 horas | Ticket (warning): revisar en horario laboral |
| `PedidosLatenciaQuemaRapida` | burn 1h y 5m > 14.4 | Más del 72 % de los pedidos tardan más de 500 ms | Página |
| `PedidosLatenciaQuemaLenta` | burn 6h y 30m > 6 | Más del 30 % lentos de forma sostenida | Ticket |

Cómo se lee el burn rate:
- burn rate = proporción de eventos malos / (1 − objetivo).
- 1x significa gastar exactamente el presupuesto en 30 días.
- La ventana larga evita alertar por un pico de segundos.
- La ventana corta hace que la alerta se apague pocos minutos después de corregir el problema.

**Alertas que NO se definieron, a propósito:**
- "CPU > 80 %", "un pod se reinició" o "latencia de pagos alta": son causas posibles, no síntomas para el usuario.
  Si no afectan los pedidos, despertar a alguien por ellas es ruido.
  Se ven en el tablero (señal de saturación), no como alerta.
- Alerta de "pagos rechazados": un rechazo por fondos insuficientes es negocio, no una falla. Queda en el tablero.

## Límites conocidos (honestidad en la medición)

- **Retención de 3 días** en el entorno de práctica: el "presupuesto de 30 días" se calcula sobre los datos disponibles.
  Después de las demostraciones de fallo queda **negativo**, porque se consumió a propósito.
  En producción, Prometheus necesitaría almacenamiento persistente y al menos 30 días de retención.
- El SLI se mide **en el servidor** (pedidos).
  Si el balanceador o la red fallan antes de llegar a pedidos, el usuario lo sufre pero el SLI no lo ve.
  Una sonda sintética externa (blackbox) cerraría ese hueco.
- Los histogramas usan cubetas fijas (…0.4, 0.5, 0.75…).
  El p95 es una interpolación dentro de la cubeta, no el valor exacto.
