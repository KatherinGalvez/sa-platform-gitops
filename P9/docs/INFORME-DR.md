# Informe de la prueba de DR — Práctica 9

Katherin Galvez · 202006633 · Pruebas ejecutadas el 15/10/2026 en GKE (`us-central1-a`, proyecto `sa-p6-202006633`). Hora de Guatemala (CST).

## 1. Objetivos declarados

*Declarados en el commit `3ccc5c4` del 25/09/2026, antes de ejecutar cualquier prueba.*

| Objetivo | Valor | Justificación |
|---|---|---|
| **RTO** | **45 min** | Crear un clúster GKE zonal y su node pool: 10-15 min; ArgoCD: 3-5 min; Velero, Sealed Secrets y la restauración de un volumen pequeño (2 GiB, Kopia): 5-8 min; Argo Rollouts, Kyverno y el canary: 3-5 min. Suma ≈ 30 min, más 50 % de margen por la variabilidad de la nube. |
| **RPO** | **60 min** | El schedule `velero-horario` respalda cada hora: en el peor caso se pierde lo escrito desde el inicio del último respaldo hasta el desastre. Bajarlo exigiría respaldos más frecuentes o replicación continua. |

## 2. Escenario ejecutado

Prueba válida: `scripts/prueba-dr.sh`, iniciada en **T0 = 22:47:39**. Orden de la destrucción (`scripts/destruir.sh`):

1. Se retiraron los bloqueos de la destrucción: ArgoCD detenido, PodDisruptionBudgets y webhooks de Kyverno eliminados.
2. Se sacó del estado de Terraform todo lo que vive dentro del clúster (node pool, ArgoCD, app raíz, llave), simulando que el clúster desaparece sin limpieza ordenada.
3. `terraform destroy` de la capa clúster: clúster GKE, 3 nodos y vínculo de Workload Identity.
4. Se **borraron los 2 discos persistentes** de PostgreSQL (`data-postgres-0` y `data-postgres-1`): los datos solo podían volver del respaldo.
5. Sobrevivieron únicamente: bucket de estado de Terraform, bucket de Velero y Secret Manager.

Reconstrucción con un solo comando, `scripts/bootstrap.sh`, sin intervención humana.

**Intento previo fallido (21:26).** El primer ensayo reconstruyó el clúster en 20 min 37 s, pero **no restauró los datos**: ArgoCD creó la base de datos vacía antes de que el Job de restauración revisara, y el Job concluyó "ya existe, no restauro". Se detectó porque la base tenía 4 marcas (no 11) y su primera marca era de la reconstrucción. Se corrigió y se repitió la prueba (ver sección 5).

## 3. Tiempos medidos

| Marca | Hora | Fuente |
|---|---|---|
| T0 inicio de la destrucción | 22:47:39 | `MARCA DESTRUCCION_INICIO` |
| T1 clúster destruido | 22:53:50 | `MARCA DESTRUCCION_FIN` |
| Clúster nuevo creado | 22:58:45 | `kube-system.creationTimestamp` |
| Terraform terminado (GKE + ArgoCD + app raíz) | 23:06:44 | `MARCA TERRAFORM_OK` |
| Restauración automática `dr-20261016051318` completada | 23:14:10 | `velero restore get` |
| PostgreSQL primario listo | 23:14:25 | condición `Ready` del pod |
| **T2 API lista (3/3 réplicas) con los datos restaurados** | **23:14:48** | condición `Ready` de `servicio-datos` |

**RTO real = T2 − T0 = 27 min 09 s** (destrucción 6 min 11 s + reconstrucción 20 min 58 s). Registro: `evidencias/dr-20261015-224733.log`; resumen: `evidencias/resumen-dr-20261015-224733.md`.

T2 se tomó de los registros del propio clúster porque la sesión de Cloud Shell que ejecutaba el script se reinició a las 23:41, antes de imprimir su marca final.

## 4. Pérdida medida

- Respaldo usado: `velero-horario-20261016044631` (22:46:31), el más reciente sin errores anterior al clúster nuevo.
- Última marca recuperada: **22:46:01**. Antes del desastre la última era de las 22:47:01.
- **RPO real (prueba de DR) = T0 − última marca recuperada = 1 min 38 s.** Se perdió 1 fila de `marcas`, escrita después del respaldo y solo presente en el disco destruido.
- La tabla `pedidos` volvió **idéntica**: 50 filas, md5 `6cf10531da4fef22fce909b6f22cab44`. La primera marca restaurada (20:50:28) prueba que es la base original y no una nueva.
- **Este RPO es optimista**: se tomó un respaldo manual 1 minuto antes de la prueba. La prueba de restauración de datos, que usó el respaldo **programado** de las 21:00, midió **RPO = 25 min 19 s** (25 marcas perdidas; `evidencias/resumen-restauracion-20261015-212512.md`), que es el valor representativo.

## 5. Puntos únicos de fallo detectados

| Punto | Qué reveló la prueba | Corrección |
|---|---|---|
| Orden de la restauración | 1.er intento: la BD vacía se creó antes de restaurar; la sincronización por olas de ArgoCD no esperó al Job | El Job pasó a ser un hook **PreSync** de la app `datos`: nada se crea hasta que el hook termina (verificado en el 2.º intento) |
| PDB en una destrucción total | Borrar el node pool quedó bloqueado ~55 min: GKE respeta los PDB y los pods no tenían a dónde ir | `destruir.sh` retira PDB y webhooks y borra el clúster directamente (6 min en el 2.º intento) |
| Repositorio Helm externo | El primer bootstrap falló: `bitnami-labs.github.io/sealed-secrets` devolvía 404 | Chart tomado del repositorio Git oficial, fijado a `helm-v2.20.0` |
| Escrituras en un solo primario | Reiniciar `postgres-0` hizo fallar una escritura del CronJob | Declarado: la réplica solo sirve lecturas (en la pérdida de nodo la API tuvo 100 % de disponibilidad) |
| Respaldos durante un incidente | Los respaldos de las 19:00 y 20:00 quedaron `PartiallyFailed` | La restauración solo usa respaldos sin errores ni advertencias |
| Estación del operador | El reinicio de Cloud Shell cortó el script a mitad de la prueba | El bootstrap es idempotente y se puede reanudar; mejor ejecutarlo desde un runner persistente |
| Clúster zonal, un proyecto, una cuenta | No probado; una caída de zona o de la cuenta lo detiene todo | Plan, punto 4 |

## 6. Brecha y plan

| Objetivo | Declarado | Medido | Brecha |
|---|---|---|---|
| RTO | 45 min | 27 min 09 s | **−17 min 51 s** (cumplido) |
| RPO | 60 min | 25 min 19 s (programado) · 1 min 38 s (DR con respaldo previo) | **−34 min 41 s** (cumplido) |

**Análisis.** El RTO se cumplió con margen, pero no por suerte. La creación del clúster (13 min) y la restauración (8 min) se ajustaron a lo estimado, y la destrucción ya corregida tardó 6 min. Sin embargo, el sistema **no cumplía su objetivo antes de las pruebas**: el primer intento habría dado una "recuperación" sin datos, una pérdida total que el tiempo de 20 minutos ocultaba. El RPO depende de cuándo ocurra el desastre dentro de la hora: el peor caso sigue siendo de 60 min, y 25 min fue un punto intermedio.

**Plan para cerrarla:**

1. **RPO:** archivado continuo del WAL de PostgreSQL a GCS (WAL-G) → RPO de segundos, sin depender del calendario de Velero.
2. **Escrituras:** PostgreSQL con failover automático (CloudNativePG) o Cloud SQL con alta disponibilidad.
3. **RTO y dependencias:** reflejar charts e imágenes en Artifact Registry y ejecutar el bootstrap desde un runner de CI, no desde una sesión interactiva.
4. **Alcance:** clúster regional, segunda copia de la llave en otro proyecto y ensayo trimestral del runbook por otra persona.
