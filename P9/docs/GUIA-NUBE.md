# Guía para levantar la Práctica 9 en Google Cloud

Todo se ejecuta desde **Cloud Shell** (la terminal del navegador de Google Cloud), que ya trae `gcloud`, `terraform`, `kubectl` y `helm`. No hace falta instalar nada en Windows.

Cada vez que vea **📸 Cxx** tome una captura de pantalla y guárdela en `P9/evidencias/capturas/Cxx-descripcion.png`. La columna "Criterio" indica a qué parte de la rúbrica responde.

> **Costo aproximado:** 3 nodos `e2-standard-2` ≈ USD 0.20 por hora (≈ 5 por día). La tarifa de gestión de un clúster zonal la cubre el crédito gratuito de GKE. Con la prueba gratuita de USD 300 alcanza de sobra, **pero destruya el clúster cuando no esté trabajando** (sección 10).

---

## 0. Proyecto de Google Cloud (una sola vez)

1. Entre a <https://console.cloud.google.com> con su cuenta.
2. Arriba a la izquierda → selector de proyectos → **Proyecto nuevo** → nombre `p9-dr` → Crear. Anote el **ID del proyecto** (puede ser distinto del nombre, por ejemplo `p9-dr-471203`).
3. Menú ☰ → **Facturación** → vincule la cuenta de facturación (la de prueba gratuita).
4. Recomendado: Facturación → **Presupuestos y alertas** → cree un presupuesto de USD 20 con alertas al 50 % y 90 %.
5. Abra **Cloud Shell**: ícono `>_` arriba a la derecha.

## 1. Subir la carpeta P9 al repositorio

Desde su PC (PowerShell), copie la carpeta `P9` que le entregué dentro de `REPO\` y súbala:

```powershell
cd "C:\Users\kater\Desktop\2S 2026\SA\LAB\Practicas\REPO"
git add P9
git commit -m "P9: continuidad operativa y DR"
git push
```

El repositorio debe ser **público** (ArgoCD lo lee sin credenciales y la tabla de enlaces lo exige).

## 2. Clonar y configurar en Cloud Shell

```bash
git clone https://github.com/USUARIO/REPO.git
cd REPO/P9
cp p9.env.ejemplo p9.env
nano p9.env        # PROYECTO, REPO_URL (y ZONA si quiere otra)
chmod +x scripts/*.sh
```

> Si Cloud Shell se desconecta, vuelva a abrirlo y haga `cd REPO/P9`. Todos los scripts se pueden repetir sin romper nada.

## 3. Preparar el proyecto: estado remoto y capa persistente

```bash
./scripts/00-preparar-gcp.sh
```

Habilita APIs, instala `velero` y `kubeseal`, crea el bucket del **estado remoto** de Terraform y aplica la capa persistente (bucket de Velero, cuenta de servicio, Secret Manager).

| | Captura | Criterio |
|---|---|---|
| 📸 C01 | Consola → **Cloud Storage → Buckets**: se ven `<proyecto>-p9-tfstate` y `<proyecto>-p9-velero` | 2.2 / 2.3 |
| 📸 C02 | Entrar al bucket `-p9-tfstate` → carpetas `p9/persistente/` y `p9/cluster/` con `default.tfstate` (la segunda aparece tras el paso 5) | 2.2 |
| 📸 C03 | En Cloud Shell: `ls terraform/*/ ; git status` → no hay ningún `.tfstate` en el repositorio | 2.2 |

## 4. Llave de Sealed Secrets fuera del clúster y GitOps

```bash
./scripts/01-llave-sealed-secrets.sh      # genera la llave y la guarda en Secret Manager
./scripts/02-configurar-gitops.sh         # rellena bucket/SA/repo y sella la contraseña de la BD
```

> Si todavía tiene el clúster de la Práctica 8 y quiere conservar su llave, primero exporte la llave allí (`kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > llave-p8.yaml`), súbala a Cloud Shell y ejecute `./scripts/01-llave-sealed-secrets.sh llave-p8.yaml`. Si no, sus SealedSecrets de P8 deben volver a sellarse con `scripts/sellar.sh` (ver sección 4.1).

Suba los cambios **desde Cloud Shell** (o descárguelos y súbalos desde su PC):

```bash
cd ~/REPO
git config user.email "3057796210301@ingenieria.usac.edu.gt"; git config user.name "Su Nombre"
git add P9 && git commit -m "P9: configuración GitOps y secreto sellado" && git push
cd P9
```

(Para `git push` desde Cloud Shell GitHub pide un *Personal Access Token* como contraseña.)

| | Captura | Criterio |
|---|---|---|
| 📸 C04 | Consola → **Security → Secret Manager**: `p9-sealed-secrets-crt` y `p9-sealed-secrets-key` | 2.4 |
| 📸 C05 | GitHub: archivo `P9/gitops/cargas/datos/05-db-credenciales-sealed.yaml` (se ve cifrado) | 2.4 |

### 4.1 Integrar los microservicios de P4/P5 (flujo de la Práctica 8)

1. Renombre `gitops/apps/40-sistema-p8.yaml.ejemplo` a `40-sistema-p8.yaml` y ajuste `path:` a la carpeta GitOps de su P8.
2. Si su P8 instalaba Sealed Secrets, quítelo de allí (ya lo instala `00-sealed-secrets.yaml`).
3. Vuelva a sellar los secretos de sus microservicios con la llave nueva, por ejemplo:
   `./scripts/sellar.sh <namespace> <nombre-secreto> ../P8/gitops/<ruta>/sealed.yaml CLAVE=valor`
4. Agregue a cada microservicio el bloque de `plantillas/resiliencia-microservicio.yaml` (réplicas ≥ 2, anti-afinidad, PDB, probes).
5. Commit y push. Cambie en `bootstrap.sh` el `-ge 5` por `-ge 6` si agregó la app `sistema-p8`.

## 5. Primer bootstrap (punto de entrada único)

**Antes de esta prueba**, complete y suba la sección "Objetivos declarados" de `docs/INFORME-DR.md` (el commit con fecha anterior a las pruebas demuestra que los objetivos se declararon antes).

```bash
./scripts/bootstrap.sh
```

Tarda ~15-25 min. Al final imprime el tiempo total y la API respondiendo.

| | Captura | Criterio |
|---|---|---|
| 📸 C06 | Terminal: inicio del bootstrap (línea `MARCA BOOTSTRAP_INICIO`) | 2.1 |
| 📸 C07 | Terminal: final con `MARCA SERVICIO_RESPONDE` y "Duración total" | 2.1 |
| 📸 C08 | Consola → **Kubernetes Engine → Clústeres**: `p9-dr` con 3 nodos | 2.1 |

### Ver la interfaz de ArgoCD

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

En Cloud Shell → botón **Vista previa en la web** → **Vista previa en el puerto 8080**. Usuario `admin`.

| | Captura | Criterio |
|---|---|---|
| 📸 C09 | ArgoCD: árbol de `p9-raiz` con las apps hijas (sealed-secrets, velero, restauracion-dr, datos, sistema-p8) todas *Synced/Healthy* | 2.1 |
| 📸 C10 | ArgoCD: app `datos` abierta (StatefulSet, PVC, PDB, CronJob, Deployment) | 2.5 |

## 6. Respaldo con Velero

El schedule `velero-horario` respalda cada hora. Para no esperar, fuerce el primero:

```bash
./scripts/respaldos.sh --ahora
./scripts/respaldos.sh
```

| | Captura | Criterio |
|---|---|---|
| 📸 C11 | Salida de `respaldos.sh`: ubicación `Available`, schedule `0 * * * *` con TTL 168h, respaldos `Completed` | 2.3 |
| 📸 C12 | `velero backup describe <respaldo> --details` → sección *Pod Volume Backups* con el volumen `data` de postgres (kopia) | 2.3 |
| 📸 C13 | Consola → bucket `-p9-velero` → carpetas `backups/` y `kopia/` | 2.3 |

Deje pasar **al menos una ejecución programada** (espere al minuto 00 de la siguiente hora) antes de las pruebas 8 y 9: el RPO se mide contra el respaldo programado, no contra uno forzado.

## 7. Prueba de pérdida de nodo

```bash
./scripts/prueba-perdida-nodo.sh
```

| | Captura | Criterio |
|---|---|---|
| 📸 C14 | Pods con `-o wide` antes del drenaje (3 réplicas en 3 nodos distintos) y el PDB `minAvailable 2` | 2.5 |
| 📸 C15 | Durante el drenaje: nodo `SchedulingDisabled` y réplica reprogramada | 2.5 |
| 📸 C16 | Resultado de la sonda: "Disponibilidad 100 %" (o el % real) | 2.5 |

Opcional para el informe (puntos únicos de fallo): `./scripts/prueba-perdida-nodo.sh --con-bd` drena el nodo de PostgreSQL y mide cuánto no responde la API.

## 8. Prueba de restauración de datos

```bash
./scripts/prueba-restauracion-datos.sh
```

| | Captura | Criterio |
|---|---|---|
| 📸 C17 | Huella antes (50 pedidos, md5) y después del borrado (0 filas) | 2.6 |
| 📸 C18 | Contenido restaurado en `datos-restaurado`: mismo md5 y filas de muestra | 2.6 |
| 📸 C19 | Tabla final con el RPO real | 2.6 / 1.2 |

## 9. Prueba de recuperación cronometrada (destrucción total)

Deje correr el sistema al menos unos minutos después de un respaldo programado y ejecute:

```bash
./scripts/prueba-dr.sh
```

Destruye el clúster **y sus discos**, lo reconstruye con `bootstrap.sh` y restaura automáticamente los datos. Genera `evidencias/dr-<fecha>.log` y `evidencias/resumen-dr-<fecha>.md`.

| | Captura | Criterio |
|---|---|---|
| 📸 C20 | `MARCA DESTRUCCION_INICIO` y consola de GKE con el clúster eliminándose / sin clústeres | 1.2 |
| 📸 C21 | Registro del job de restauración automática: "Restaurando datos desde el respaldo …" | 2.3 |
| 📸 C22 | `verificar-secretos.sh`: huella de Secret Manager = huella en el clúster, SealedSecret sincronizado | 2.4 |
| 📸 C23 | Resumen final con RTO y RPO reales | 1.2 |
| 📸 C24 | ArgoCD después de la reconstrucción: todo Synced/Healthy, incluido el sistema de P8 (Rollouts, políticas) | 2.1 |

## 10. Documentación y video

1. Copie los valores de `resumen-dr-*.md` y `resumen-restauracion-*.md` a `docs/INFORME-DR.md` y a la tabla del `README.md`.
2. Suba `evidencias/` (logs y capturas) al repositorio.
3. Grabe el video (5-8 min) siguiendo el guion del README y anote el minutaje.

## 11. Ahorro y limpieza

- Pausar entre sesiones: `./scripts/respaldos.sh --ahora && ./scripts/destruir.sh` (los datos vuelven solos con el siguiente `bootstrap.sh`). Recuerde que para la calificación el sistema debe estar **desplegado y sincronizado**.
- Después de la calificación: `./scripts/limpiar-todo.sh` borra todo.

## Problemas frecuentes

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `Quota exceeded ... CPUS` | Cuota de la prueba gratuita | Use `TIPO_MAQUINA="e2-medium"` o pida aumento de cuota |
| App `velero` en *Degraded* / BSL `Unavailable` | Workload Identity aún propagándose | Espere 2-3 min; `kubectl -n velero logs deploy/velero \| grep -i error` |
| App `datos` con pods en `CreateContainerConfigError` | SealedSecret sellado con otra llave | `./scripts/verificar-secretos.sh`; vuelva a ejecutar el paso 4 |
| Error de imagen `alpine/k8s` en `restauracion-dr` | Etiqueta no disponible | Cambie la imagen en `gitops/plataforma/restauracion/restauracion-dr.yaml` por otra con `kubectl` y `sh` |
| Políticas de admisión de P8 bloquean pods de velero/datos | Reglas de Kyverno/Gatekeeper | Excluya los namespaces `velero`, `kube-system` y `datos-restaurado` en esas políticas |
