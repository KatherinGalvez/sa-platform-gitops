# Informe de la prueba de DR — Práctica 9

> Máximo dos páginas. Los campos 1 se completan y suben **antes** de las pruebas; los campos 2 a 6 con los valores de `evidencias/resumen-dr-*.md` y `evidencias/resumen-restauracion-*.md`. Borre este recuadro al terminar.

## 1. Objetivos declarados

*Declarados el `<<fecha del commit>>`, antes de ejecutar las pruebas.*

| Objetivo | Valor | Justificación |
|---|---|---|
| **RTO** | **45 min** | Crear un clúster GKE zonal y su node pool toma 10-15 min; ArgoCD 3-5 min; Velero, Sealed Secrets y la restauración de un volumen pequeño (2 GiB, Kopia) 5-8 min; Argo Rollouts, Kyverno y el despliegue canary 3-5 min. Suma ≈ 30 min más un margen del 50 % por variabilidad de la nube. Para un sistema académico sin clientes externos, 45 min es aceptable. |
| **RPO** | **60 min** | El schedule `velero-horario` respalda cada hora. El peor caso es perder lo escrito desde el inicio del último respaldo hasta el desastre: hasta 60 min más la duración del respaldo (< 1 min). Un RPO menor exigiría respaldos más frecuentes o replicación continua de la BD. |

## 2. Escenario ejecutado

Orden exacto de la destrucción (script `scripts/destruir.sh`, iniciado en T0 = `<<fecha hora>>`):

1. Se retiró del estado de Terraform todo lo que vive dentro del clúster (ArgoCD, app raíz, llave), simulando que el clúster desaparece sin limpieza ordenada.
2. `terraform destroy` de la capa clúster: se eliminaron el clúster GKE, sus 3 nodos y el vínculo de Workload Identity.
3. Se **borraron los discos persistentes** de los PVC (`<<nombres>>`): la base de datos solo podía volver desde el respaldo.
4. Sobrevivieron únicamente: bucket de estado, bucket de Velero y Secret Manager.

Reconstrucción: un solo comando, `scripts/bootstrap.sh`, sin intervención.

## 3. Tiempos medidos

| Marca | Hora |
|---|---|
| T0 inicio de la destrucción | `<<>>` |
| T1 fin de la destrucción | `<<>>` |
| Terraform terminado | `<<>>` |
| ArgoCD todo sincronizado | `<<>>` |
| T2 API respondiendo con datos restaurados | `<<>>` |

**RTO real = T2 − T0 = `<<>>`** (destrucción `<<>>` + reconstrucción `<<>>`). Registro: `evidencias/dr-<<fecha>>.log`.

## 4. Pérdida medida

- Respaldo usado: `<<velero-horario-...>>`, iniciado `<<hora>>`.
- Última marca recuperada: id `<<>>` de las `<<hora>>`.
- **RPO real = T0 − última marca recuperada = `<<>>`.**
- No se recuperaron `<<N>>` filas de `marcas` (una por minuto) escritas entre el inicio del respaldo y T0, porque solo existían en el disco destruido. La tabla `pedidos` se recuperó **idéntica** (mismo md5 `<<>>`).
- Prueba de restauración de datos (borrado lógico): RPO real `<<>>`, `evidencias/resumen-restauracion-<<fecha>>.md`.

## 5. Puntos únicos de fallo detectados

| Punto | Qué revela la prueba | Impacto |
|---|---|---|
| PostgreSQL con 1 réplica | Drenar su nodo dejó la API sin respuesta `<<X>>` s (`--con-bd`) | Caída total del servicio con estado mientras el disco se reasigna |
| Respaldos cada hora | Todo lo escrito después del último respaldo se pierde | RPO de hasta 60 min |
| Llave de Sealed Secrets | Una sola copia en Secret Manager (versionada, `prevent_destroy`) | Si se borra, todos los SealedSecrets quedan ilegibles |
| Clúster zonal, un solo proyecto y una sola cuenta | Una caída de la zona o la pérdida de acceso a la cuenta detienen todo | Ni el runbook puede ejecutarse |
| Dependencias externas | GitHub (repositorio GitOps) y Docker Hub (imágenes) deben estar disponibles durante el bootstrap | El RTO depende de terceros |
| `<<lo que usted observe>>` | | |

## 6. Brecha y plan

| Objetivo | Declarado | Medido | Brecha |
|---|---|---|---|
| RTO | 45 min | `<<>>` | `<<+/− min>>` |
| RPO | 60 min | `<<>>` | `<<+/− min>>` |

**Análisis:** `<<Explique con honestidad por qué hubo o no diferencia: ¿qué fase tardó más de lo estimado? (normalmente la creación del clúster o la descarga de imágenes). Si se cumplió, ¿con cuánto margen y fue suerte o diseño?>>`

**Plan para cerrarla:**

1. RPO: respaldos cada 15 min para `datos` o archivado continuo de WAL (pgBackRest / WAL-G) a GCS → RPO de segundos.
2. PostgreSQL con réplica (operador CloudNativePG) o Cloud SQL con alta disponibilidad → elimina el punto único de fallo.
3. RTO: clúster regional o un node pool con imagen pre-descargada; reflejar imágenes en Artifact Registry.
4. Llave: segunda copia cifrada en otro proyecto y ensayo trimestral del runbook por otra persona.
