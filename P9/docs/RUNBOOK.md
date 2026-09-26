# Runbook de recuperación ante desastres — Práctica 9

**Para quién:** cualquier persona con acceso al proyecto de Google Cloud, sin conocimiento previo del sistema y sin poder consultar al autor.
**Cuándo usarlo:** el clúster `p9-dr` no existe, no responde o perdió sus volúmenes.
**Resultado esperado:** sistema completo reconstruido y datos restaurados desde el último respaldo en ≤ 45 min (RTO declarado), con pérdida de datos ≤ 60 min (RPO declarado).

---

## 0. Datos que necesita (todos sin credenciales)

| Dato | Valor |
|---|---|
| Proyecto GCP | `<<ID del proyecto>>` |
| Zona del clúster | `us-central1-a` |
| Nombre del clúster | `p9-dr` |
| Repositorio (público) | `<<URL del repositorio>>` |
| Bucket de estado Terraform | `gs://<<proyecto>>-p9-tfstate` (prefijos `p9/persistente`, `p9/cluster`) |
| Bucket de respaldos | `gs://<<proyecto>>-p9-velero` |
| Llave de Sealed Secrets | Secret Manager: `p9-sealed-secrets-crt`, `p9-sealed-secrets-key` |
| Aplicación raíz ArgoCD | `p9-raiz` en el namespace `argocd` |
| Schedule de respaldos | `velero-horario` (cada hora, retención 7 días) |

**Permisos mínimos de su cuenta en el proyecto:** *Kubernetes Engine Admin*, *Storage Admin*, *Secret Manager Secret Accessor*, *Service Account Admin*, *Project IAM Admin* (o simplemente *Owner*).

## 1. Evaluar antes de actuar (2 min)

Abra Cloud Shell (ícono `>_` en <https://console.cloud.google.com>) y ejecute:

```bash
gcloud config set project <<ID del proyecto>>
gcloud container clusters list
gcloud storage ls gs://<<proyecto>>-p9-velero/backups/ | tail -3
```

| Si ve… | Entonces… |
|---|---|
| El clúster **no aparece** | Siga con el paso 2 (reconstrucción completa). |
| El clúster aparece pero no responde / está dañado | Declare el incidente, anote la hora (T0) y siga con el paso 2 usando **2b**. |
| El clúster funciona pero **faltan datos** | Vaya al **Anexo A** (restauración de datos sin reconstruir). |
| **No hay** carpetas en `backups/` | La reconstrucción funcionará pero con base de datos vacía. Registre la pérdida total en el informe. |

✅ Verificación: anotó la hora de inicio del incidente (T0).

## 2. Preparar el entorno (3 min)

```bash
git clone <<URL del repositorio>> repo && cd repo/P9
cp p9.env.ejemplo p9.env
sed -i 's/^PROYECTO=.*/PROYECTO="<<ID del proyecto>>"/' p9.env
sed -i 's#^REPO_URL=.*#REPO_URL="<<URL del repositorio>>"#' p9.env
chmod +x scripts/*.sh
./scripts/00-preparar-gcp.sh
```

✅ Verificación: la salida termina en `Listo.` y muestra `velero_bucket` y `velero_gsa_email`. Si dice `Error acquiring the state lock`, otra persona está ejecutando Terraform: espere o coordine; **no** use `force-unlock` salvo que confirme que nadie más está trabajando.

**2b. (solo si el clúster existe pero está dañado):** `./scripts/destruir.sh` y escriba `DESTRUIR`. ✅ `gcloud container clusters list` ya no muestra `p9-dr`.

## 3. Reconstruir (≈ 20-30 min, sin intervención)

```bash
./scripts/bootstrap.sh
```

El script hace, en orden y sin pasos manuales:

1. Terraform capa persistente (verifica bucket, cuenta de servicio y Secret Manager).
2. Terraform capa clúster: GKE → llave de Sealed Secrets desde Secret Manager → ArgoCD → app raíz `p9-raiz`.
3. ArgoCD por olas: `sealed-secrets` y `velero` → `restauracion-dr` (restaura `datos` del último respaldo) → `datos` → `sistema-p8`.
4. Verifica secretos, contenido de la base de datos y respuesta HTTP.

Mientras corre, las líneas `Esperando aplicaciones:` indican qué falta. ✅ Verificación final: aparecen `MARCA SERVICIO_RESPONDE` y `Duración total del bootstrap`.

## 4. Verificar la recuperación (3 min)

```bash
kubectl -n argocd get applications              # todas Synced / Healthy
kubectl -n velero logs job/restauracion-dr      # "Restaurando datos desde el respaldo ..." y fase Completed
./scripts/verificar-secretos.sh                 # huellas iguales y "llaves en el cluster: 1"
kubectl -n datos exec postgres-0 -- psql -U app -d p9 -c "select count(*), max(creado) from marcas;"
```

| Verificación | Correcto | Si no |
|---|---|---|
| Aplicaciones | Todas `Synced Healthy` | Ver tabla de fallas |
| Job de restauración | `fase: Completed` | `velero restore describe <nombre> --details` |
| Secretos | Huella de Secret Manager = huella del clúster | Ver tabla de fallas |
| Datos | `count` > 0 y `max(creado)` cercano a la hora del último respaldo | Anexo A |

La **pérdida de datos** es el intervalo entre la última marca recuperada y T0. Anótelo.

## 5. Cierre

1. Registre T0, la hora de `SERVICIO_RESPONDE` y la última marca recuperada en `docs/INFORME-DR.md`.
2. Fuerce un respaldo nuevo: `./scripts/respaldos.sh --ahora`.

## Tabla de fallas

| Síntoma | Diagnóstico | Acción |
|---|---|---|
| `terraform apply` falla por cuota de CPU | `gcloud compute regions describe us-central1 --format="value(quotas)"` | Editar `TIPO_MAQUINA="e2-medium"` en `p9.env` y repetir el paso 3 |
| Secret Manager "NOT_FOUND" en Terraform | La llave no existe | **Si hay un respaldo de la llave**, súbalo con `./scripts/01-llave-sealed-secrets.sh <archivo>`. Si no existe ninguna copia, los secretos sellados son irrecuperables: genere llave nueva, vuelva a sellar (`scripts/sellar.sh`) y registre el incidente |
| App `velero` Degraded, BSL `Unavailable` | `kubectl -n velero get bsl default -o yaml` | Esperar 3 min (Workload Identity); si sigue, repetir el paso 3 |
| Job `restauracion-dr` dice "arranque en limpio" pero hay respaldos | Respaldos aún no sincronizados | `kubectl -n velero delete job restauracion-dr` (ArgoCD lo recrea) **antes** de que la app `datos` cree la BD; si ya la creó, usar Anexo A |
| Pods de `datos` en `CreateContainerConfigError` | `kubectl -n datos get sealedsecret db-credenciales -o yaml` → condición en error | Verificar huellas con `verificar-secretos.sh`; si difieren, la llave del clúster no es la de Secret Manager: `kubectl -n kube-system delete pod -l app.kubernetes.io/name=sealed-secrets` |
| `postgres-0` no arranca tras restaurar (datos corruptos) | `kubectl -n datos logs postgres-0` | Cada respaldo trae un volcado consistente en `/var/lib/postgresql/data/volcado/p9.sql`: copiarlo con `kubectl cp`, borrar el PVC para obtener una BD nueva y cargarlo con `psql -U app -d p9 -f p9.sql` |
| `Esperando aplicaciones` durante > 40 min | `kubectl -n argocd get app <nombre> -o yaml` → `status.conditions` | Corregir y ejecutar de nuevo `./scripts/bootstrap.sh` (es idempotente) |

## Anexo A — Restaurar datos sin reconstruir el clúster

```bash
velero backup get                                       # elegir el último Completed
velero restore create manual-$(date +%s) --from-backup <respaldo> \
  --include-namespaces datos --namespace-mappings datos:datos-restaurado \
  --exclude-resources cronjobs.batch,jobs.batch,sealedsecrets.bitnami.com --wait
kubectl -n datos-restaurado rollout status statefulset/postgres
kubectl -n datos-restaurado exec postgres-0 -- psql -U app -d p9 -c "select count(*) from pedidos;"
# Copiar a producción:
kubectl -n datos-restaurado exec postgres-0 -- pg_dump -U app -d p9 --data-only -t pedidos -t marcas \
  | kubectl -n datos exec -i postgres-0 -- psql -U app -d p9
kubectl delete ns datos-restaurado
```

O, automatizado con verificación: `./scripts/prueba-restauracion-datos.sh`.
