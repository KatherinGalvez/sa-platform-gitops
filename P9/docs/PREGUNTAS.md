# Preparación para las preguntas teóricas

La rúbrica premia analizar **su propio sistema** y reconocer sus límites. Respuestas base (ajústelas a lo que midió):

**¿Qué se reconstruye automáticamente y qué se pierde para siempre?**
Se reconstruye todo lo declarativo: clúster (Terraform), plataforma y aplicaciones (GitOps) y secretos (SealedSecrets + llave en Secret Manager). Se pierde de forma irreversible lo escrito en la base de datos después del último respaldo (hasta 60 min) y todo estado no respaldado: logs, métricas, eventos, historial de ArgoCD y de Rollouts.

**¿Qué pasa si se borra la llave de Secret Manager?**
Los SealedSecrets del repositorio quedan ilegibles para siempre (cifrado asimétrico). El bootstrap falla en Terraform. Mitigación: `prevent_destroy`, versiones de Secret Manager y una segunda copia fuera del proyecto.

**¿Qué pasa si se pierde el bucket de estado de Terraform?**
La infraestructura sigue funcionando, pero Terraform ya no la conoce: un `apply` intentaría crear todo de nuevo y chocaría con lo existente. Se recupera con `terraform import` o desde una versión anterior (el bucket tiene versionado).

**¿Por qué el bloqueo del estado?**
Dos personas ejecutando `apply` a la vez corromperían el estado. GCS usa un archivo `.tflock` con escritura condicional: la segunda ejecución falla con *Error acquiring the state lock*.

**¿Por qué Velero con Kopia y no snapshots de disco?**
Los datos quedan en GCS (fuera del clúster, multi-región) y la restauración no depende de la zona original del disco. Costo: más lento para volúmenes grandes.

**¿Por qué restaurar antes de que ArgoCD cree la base de datos?**
Velero no sobrescribe PVC existentes (`existingResourcePolicy: none`). Si ArgoCD crea primero un volumen vacío, la restauración se salta los datos.

**¿Por qué `skipImmediately: true` en el schedule?**
En un clúster recién reconstruido el schedule generaría de inmediato un respaldo **vacío**, que sería el "más reciente". El job además solo acepta respaldos anteriores a la creación del clúster.

**PDB `minAvailable: 2` con 3 réplicas: ¿qué pasa si drenan dos nodos a la vez?**
El segundo drenaje queda bloqueado hasta que la réplica desalojada esté *Ready* en otro nodo. El PDB protege de interrupciones **voluntarias**, no de la caída súbita de un nodo.

**¿Anti-afinidad obligatoria o preferida?**
Preferida: con 3 nodos y 3 réplicas, una regla obligatoria dejaría la réplica desalojada en *Pending* durante el drenaje. La preferida la reprograma en otro nodo y conserva la capacidad.

**¿Qué punto único de fallo sigue sin cubrir?**
PostgreSQL con una réplica, clúster zonal, una sola cuenta y dependencia de GitHub/Docker Hub durante el bootstrap. Ver el informe, sección 5.

**Si el RTO medido superó el declarado, ¿cambiaría el objetivo?**
No: se reporta la brecha y se corrige el sistema (el valor de *honestidad técnica* de la práctica).
