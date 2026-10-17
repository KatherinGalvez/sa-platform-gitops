# Preguntas teóricas: respuestas sobre ESTE sistema

La rúbrica premia "analizar el comportamiento de su propia instrumentación y reconocer sus límites". Cada respuesta usa el sistema real.

**1. ¿Qué diferencia hay entre monitoreo y observabilidad?**
- El monitoreo responde preguntas que se definieron antes, por ejemplo: ¿el SLI bajó de 99 %?
- La observabilidad permite responder preguntas **nuevas** sin desplegar código nuevo.
  Ejemplo: "¿los pedidos de laptops fallan más en el pod X?"
  Aquí se responde con Loki (`{service_name="pedidos"} | producto="laptop" | level="ERROR"`) o con TraceQL, porque cada evento lleva contexto (trace_id, producto, versión).

**2. ¿Por qué tres pilares y no solo métricas?**
- Las **métricas** son baratas y agregadas: dicen *que* algo pasa y *cuánto*. Sirven para el SLO, el canary y las alertas.
- La **traza** dice *dónde* pasa: qué salto de pedidos → pagos se puso rojo.
- El **registro** dice *por qué*: "la pasarela de pago no respondió".
- En la demo, las métricas de pedidos solo mostraban 502. Sin traza no se sabía que la causa era pagos, y sin registro no se sabía que era la pasarela.

**3. ¿Cómo se propaga el contexto entre servicios?**
- Con W3C TraceContext.
  - pedidos inyecta la cabecera `traceparent: 00-<trace_id>-<span_id>-01` en cada llamada (`propagate.inject()` en `servicios/telemetria.py`, más `RequestsInstrumentor`).
  - En el receptor, `FlaskInstrumentor` la extrae y crea spans hijos de la misma traza.
- **Límite:** el generador de tráfico no está instrumentado, así que la traza empieza en pedidos y no en el "cliente".

**4. ¿Por qué el canary mide solo los pods del canary?**
- Con 1 de 4 pods (25 %), un canary que falla al 100 % sube el error total solo al ~25 %.
  Si v2 tuviera 10 % de errores, el total sería 2.5 % y **pasaría** un umbral de 5 % medido sobre todo el tráfico.
- Filtrar por `rollouts_pod_template_hash="{{args.canary-hash}}"` mide solo la versión candidata.
- **Límite:** sin un *traffic router* (Istio o un Ingress con pesos), el 25 % es por número de réplicas, no exacto.
  Con poco tráfico la muestra del canary es pequeña; por eso hay una pausa de 60 s antes de analizar.

**5. ¿Por qué alertar por burn rate y no por "error > 5 %"?**
- Un umbral instantáneo alerta por picos de segundos (ruido) y no distingue un 2 % de un minuto de un 2 % de un día entero.
- El burn rate expresa *qué tan rápido se gasta lo que se prometió*.
  14.4x en 1 h significa que se perdió el 2 % del mes en una hora; eso sí justifica despertar a alguien.
- La segunda ventana (5m) hace que la alerta se apague rápido al corregir.

**6. ¿Qué pasa si se cae el Collector o Loki?**
- Las **métricas no dependen** del Collector: Prometheus raspa directo, así que el SLO y el canary siguen funcionando.
- Las trazas se pierden: el SDK las encola y las descarta si no hay destino. El servicio **no se cae**, porque la exportación es asíncrona (BatchSpanProcessor).
- Los registros quedan en el nodo (`/var/log/pods`) y el Collector, al volver, sigue desde `start_at: end`, así que **se pierde lo intermedio**.
  Esto es un límite reconocido: con `file_storage` como checkpoint se retomaría donde quedó.

**7. ¿Qué cardinalidad tienen sus métricas y por qué importa?**
- Las etiquetas son `service`, `route`, `method`, `status`, `pod` y el hash del canary: pocas combinaciones, del orden de cientos de series.
- `pedido_id` y `trace_id` **no** son etiquetas de métrica, porque crearían una serie por pedido y saturarían Prometheus.
  Viven en los registros y las trazas, que sí soportan alta cardinalidad.

**8. ¿El SLI refleja lo que vive el usuario?**
- En gran parte, porque mide el recorrido de compra en el punto de entrada y no la CPU.
- **Límites:**
  - Se mide en el servidor, así que no ve fallas de red o del balanceador antes de pedidos.
  - Un pedido "201" con datos incorrectos cuenta como bueno.
  - 402 y 409 se excluyen por ser negocio: si inventario reportara "sin stock" por un error de código, el SLI no lo vería.
    Por eso `inventario_sin_stock_total` está en el tablero.

**9. ¿Qué es el presupuesto de error y qué decide?**
- Es el 1 % de pedidos que *se permite* fallar en 30 días (5 % lentos para latencia).
- Si queda presupuesto, se puede desplegar y experimentar.
- Si se agota, se congelan los cambios y se prioriza la confiabilidad.
- El tablero muestra el presupuesto restante para que negocio lo use sin conocer PromQL.

**10. ¿Qué mejoraría primero?**
1. Persistencia y 30 días de retención en Prometheus, porque hoy el presupuesto se calcula sobre unos 3 días.
2. *Exemplars* para saltar de la gráfica de latencia a la traza exacta.
3. Una sonda externa (blackbox) para medir desde fuera.
4. Muestreo de trazas en el Collector (*tail sampling*: guardar todas las de error y el 10 % de las sanas), porque hoy se guarda el 100 %.
