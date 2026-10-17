# Guía de la Práctica 10: levantar, demostrar, presentar y apagar

> La P10 corre en **su propio clúster `p10-obs`**. La P9 sigue en `p9-dr` (pausado).
> Todos los comandos se ejecutan en **Cloud Shell**, dentro de `~/sa-platform-gitops`.
> Puertos de **Vista previa web**: 8080 Grafana · 8081 ArgoCD · 8082 Prometheus · 8083 Argo Rollouts · 8084 Alertmanager.

---

## PARTE A: Levantar todo (una sola vez, ~45 min)

### A0. Subir los archivos al repositorio
```bash
cd ~/sa-platform-gitops
git status                   # si hay cambios de P9 sin subir: git add -A && git commit -m "P9: pendientes" && git push
git pull --rebase
unzip -o ~/P10.zip -d ~/sa-platform-gitops     # P10.zip subido con "Upload" del editor de Cloud Shell
chmod +x P10/scripts/*.sh P10/verificacion/*.sh
cp P10/p10.env.ejemplo P10/p10.env
git add P10 && git commit -m "P10: observabilidad y operacion" && git push
```
> Si `git push` pide clave, use el **token de GitHub** (el mismo de P9). Para no volver a escribirlo:
> `git config --global credential.helper 'cache --timeout=172800'`.
> ArgoCD lee **GitHub**, así que el push debe hacerse **antes** del bootstrap.

### A1. Crear el clúster y la imagen
```bash
./P10/scripts/01-crear-cluster.sh    # ~6 min. Muestra la cuota de CPU de la región
./P10/scripts/02-imagen.sh           # ~3 min. Construye y publica tienda:1.0.0
```

### A2. Bootstrap GitOps
```bash
./P10/scripts/bootstrap.sh           # ~10-15 min. Termina con 8 aplicaciones Healthy
```
Si se corta Cloud Shell, vuelva a correrlo: es idempotente.

### A3. Abrir las consolas (en una **segunda terminal**, déjela abierta)
```bash
./P10/scripts/accesos.sh             # imprime usuario y clave de Grafana y ArgoCD
```
Espere **5 minutos** de tráfico antes de las capturas; las reglas de 5m necesitan datos.

---

## PARTE B: Demostraciones y capturas (guárdelas en `P10/evidencias/img/`)

| # | Captura | Dónde |
|---|---|---|
| C1 | 8 aplicaciones Synced/Healthy | ArgoCD (8081) |
| C2 | `kubectl -n produccion get pods -L rollouts-pod-template-hash` y `kubectl -n observabilidad get pods` | terminal |
| C3 | **Traza de extremo a extremo**: Explore → Tempo → *Search* → servicio `pedidos` → abrir una traza (cascada con pedidos, inventario y pagos) | Grafana (8080) |
| C4 | En un span de esa traza: **Logs for this span** → registros JSON con el mismo `trace_id` | Grafana |
| C5 | Explore → Loki: `{service_name="pedidos"} \| json \| message="pedido creado"` (consulta **por campo**) | Grafana |
| **tablero.png** | Dashboards → **P10 - Tienda: cuatro señales de oro y SLO** (página completa) | Grafana |
| C6 | Status → *Rules*: grupos `sli-pedidos`, `slo-presupuesto-pedidos`, `alertas-slo-pedidos` | Prometheus (8082) |

### B1. Canary con reversión automática (~6 min)
```bash
./P10/scripts/demo-canary.sh
```
Mientras corre, tome estas capturas:
- **C7:** Argo Rollouts (8083) → `pedidos` en el paso de análisis.
- **C8:** panel *Latencia p95 por versión*, donde se ve el hash nuevo por encima de 500 ms.

Al terminar:
- **C9:** la salida del script, con el AnalysisRun **Failed** y el Rollout `Degraded`/abortado.
- Anote el **nombre del AnalysisRun** en el README (fila "Reversión por métricas").

```bash
./P10/scripts/demo-canary.sh revertir    # deja Git de nuevo en v1
```

### B2. Alerta → traza → registro (~15 min)
```bash
./P10/scripts/demo-alerta.sh             # rompe pagos al 90 % y espera la alerta (~10-12 min)
```
- **C10:** Prometheus → *Alerts* → `PedidosDisponibilidadQuemaRapida` en **FIRING**, con su `runbook_url`.
- **Cronometre aquí**, desde que ve la alerta hasta llegar al registro:
  1. Tablero → panel *3. ERRORES* (pagos y pedidos con 5xx).
  2. Tabla *Trazas con error* → clic (**C11**: span `consultar_pasarela` en rojo).
  3. **Logs for this span** (**C12**: `"la pasarela de pago no respondio"`).
- Anote el tiempo (< 3 min) en el README y en el informe.

```bash
./P10/scripts/demo-alerta.sh revertir    # repara pagos y mide la recuperacion
./P10/scripts/evidencias.sh              # foto en texto del estado final
```

### B3. Verificador
```bash
cd P10/verificacion
./verificar_p10.sh             # original: 45/60 por el error de llaves (C13)
./verificar_p10_corregido.sh   # corregido: 60/60 (C14)
cd ~/sa-platform-gitops
```

### B4. Completar la documentación y subir
- Rellene los ⟨COMPLETAR⟩ de `P10/README.md` y `P10/docs/INFORME-OPERACION.md`.
  Los tiempos salen de `P10/evidencias/resumen-canary-*.md`, `resumen-alerta-*.md` y `alerta-revertir-*.log`.
- Suba todo:
```bash
git add P10 && git commit -m "P10: evidencias" && git push
```

---

## PARTE C: El video (5 a 8 min)

| Tiempo | Qué mostrar | Criterio de la rúbrica |
|---|---|---|
| 0:00–0:40 | ArgoCD con las 8 apps; explicar que todo sale de `P10/gitops` | Requisito GitOps |
| 0:40–1:50 | Una traza de pedidos → inventario → pagos; *Logs for this span*; en Loki, clic en `trace_id` para volver a la traza | 2.1 (14) y 2.5 (8) |
| 1:50–3:00 | Tablero: SLO y presupuesto arriba, cuatro señales de oro, métricas de negocio. Decir **qué pregunta responde cada fila** | 1.1 (10) y 1.2 (8) |
| 3:00–4:30 | `demo-canary.sh`: p95 del canary > 500 ms → AnalysisRun Failed → aborto automático. Mostrar el AnalysisTemplate y que filtra por `rollouts_pod_template_hash` | 2.2 (16) |
| 4:30–6:30 | Alerta en firing → runbook → tablero → traza → registro, **con cronómetro visible** | 2.3 (12) y 2.4 (10) |
| 6:30–7:30 | Recuperación, informe (6 campos) y verificador corregido | 1.3 (12) |

> Tip: el video puede grabarse **durante** las demos B1 y B2. Así no hace falta repetirlas.

---

## PARTE D: El sábado (calificación)

### Reanudar (1 hora antes)
Revise primero la cuota. **Si el límite de CPUs es 8** (cuenta de prueba), **no caben** P9 (6 vCPU) y P10 (4 vCPU) a la vez: califique una y luego la otra.
```bash
gcloud compute regions describe us-central1 --format=json | jq -r '.quotas[]|select(.metric=="CPUS")|"\(.usage)/\(.limit)"'
```
P10:
```bash
cd ~/sa-platform-gitops && ./P10/scripts/pausar.sh reanudar      # ~5-10 min
# esperar 10 min de trafico; luego:
./P10/scripts/accesos.sh                                        # segunda terminal
cd P10/verificacion && ./verificar_p10_corregido.sh
```
P9: siga `P9/docs/PRESENTACION.md`.

**Cambiar entre clústeres** (el verificador usa el contexto actual de kubectl):
```bash
gcloud container clusters get-credentials p10-obs --zone us-central1-a   # para P10
gcloud container clusters get-credentials p9-dr  --zone us-central1-a    # para P9
kubectl config current-context
```

### Si el auxiliar pide la demostración en vivo
- Canary: `./P10/scripts/demo-canary.sh` (~6 min) y luego `revertir`.
- Alerta: `./P10/scripts/demo-alerta.sh`. Tarda ~10 min en disparar; mientras tanto se muestran el tablero y la traza con error, que aparecen desde el primer minuto.

---

## PARTE E: Pausar o eliminar (para no gastar)

```bash
./P10/scripts/pausar.sh          # 0 nodos: queda ~US$0.10/h (tarifa del clúster) + discos
./P10/scripts/destruir.sh        # elimina p10-obs y las imágenes (despues de la calificacion)
gcloud container clusters list   # verificar
gcloud compute disks list        # no deben quedar discos de p10-obs
```
Después de calificar las dos prácticas, haga también la limpieza de P9 (`P9/docs/PRESENTACION.md`, parte final) y **revoque el token de GitHub** en *Settings → Developer settings → Tokens*.

### Costo aproximado de P10
| Estado | Costo |
|---|---|
| Encendido (2 × e2-standard-2 + tarifa de GKE) | ~US$0.25/h. Toda una noche (12 h) ≈ US$3 |
| Pausado (0 nodos) | ~US$0.10/h de tarifa del clúster (la cuenta de facturación cubre gratis **un** clúster zonal) |
| Eliminado | US$0 |
