# Práctica 9 — Continuidad operativa y recuperación ante desastres

Universidad de San Carlos de Guatemala · Facultad de Ingeniería · Software Avanzado
Estudiante: Katherin Galvez · Carné: 202006633

El ecosistema de microservicios de las prácticas anteriores se vuelve **recuperable**: el entorno completo se destruye (clúster y discos) y se reconstruye con un solo comando en Google Cloud (GKE), restaurando datos y secretos, con tiempos medidos contra objetivos declarados antes de las pruebas.

## 4.1 Tabla de enlaces obligatoria

| Ítem | Enlace o dato |
|---|---|
| Repositorio GitOps | https://github.com/KatherinGalvez/sa-platform-gitops (público) — manifiestos en [`P9/gitops`](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/gitops) |
| Aplicación raíz en ArgoCD | **`p9-raiz`**, namespace **`argocd`** (creada por Terraform en [`terraform/cluster/main.tf`](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/terraform/cluster/main.tf); lee [`P9/gitops/apps`](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/gitops/apps)) |
| Punto de entrada del bootstrap | **`P9/scripts/bootstrap.sh`** — [ver script](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/scripts/bootstrap.sh) |
| Backend remoto de Terraform | **Google Cloud Storage** (`backend "gcs"`), bucket `sa-p6-202006633-p9-tfstate`, prefijos `p9/persistente` y `p9/cluster`; bloqueo nativo de GCS (`.tflock`) y bucket versionado. Sin credenciales en el repositorio |
| Schedule de Velero | **`velero-horario`** (ns `velero`): `0 * * * *`, retención 168 h, volúmenes con Kopia → `gs://sa-p6-202006633-p9-velero`. Además **`velero-llave`**: diario, retención 720 h (llave de Sealed Secrets). [Manifiesto](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/gitops/apps/10-velero.yaml) |
| Reconstrucción cronometrada | [`evidencias/dr-20261015-224733.log`](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/evidencias/dr-20261015-224733.log) · [resumen](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/evidencias/resumen-dr-20261015-224733.md) |
| Restauración de datos | [`evidencias/restauracion-datos-20261015-212512.log`](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/evidencias/restauracion-datos-20261015-212512.log) · [resumen](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/evidencias/resumen-restauracion-20261015-212512.md) |
| Prueba de pérdida de nodo | [`evidencias/perdida-nodo-20261015-210954.log`](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/evidencias/perdida-nodo-20261015-210954.log) · [sonda segundo a segundo](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/evidencias/sonda-20261015-210954.log) (149/149 respuestas OK, 100 %) |
| RTO y RPO declarados | Objetivo **RTO 45 min / RPO 60 min** · Medido **RTO 27 min 09 s** · **RPO 25 min 19 s** (respaldo programado) y 1 min 38 s (DR). [Informe](https://github.com/KatherinGalvez/sa-platform-gitops/blob/main/P9/docs/INFORME-DR.md) |
| Video demostrativo | `https://drive.google.com/file/d/1-z41MkDcqLS0TH0WAP81Kh1RG9w0C8WZ/view?usp=sharing` — 7:01 min |

## Documentos

| Entregable | Archivo |
|---|---|
| Informe de la prueba de DR (6 campos) | [`docs/INFORME-DR.md`](./docs/INFORME-DR.md) |
| Runbook de recuperación | [`docs/RUNBOOK.md`](./docs/RUNBOOK.md) |
| Diagrama del bootstrap | [`docs/DIAGRAMA-BOOTSTRAP.md`](./docs/DIAGRAMA-BOOTSTRAP.md) |
| Guía de despliegue en Google Cloud | [`docs/GUIA-NUBE.md`](./docs/GUIA-NUBE.md) |
| Evidencias (registros y capturas) | [`evidencias/`](./evidencias) |

## Arquitectura de la recuperación

| Debilidad de la Práctica 8 | Solución en P9 |
|---|---|
| Volúmenes de BD sin respaldo | Velero + Kopia (respaldo de archivos del volumen) hacia GCS multi-región, schedule horario, retención 7 días + ciclo de vida de 30 días en el bucket |
| Estado de Terraform en la máquina del estudiante | Backend GCS con bloqueo y versionado; dos capas: **persistente** (sobrevive) y **clúster** (efímera) |
| Llave de Sealed Secrets solo dentro del clúster | **Respaldo de la llave de Sealed Secrets** en dos lugares fuera del clúster: Google Secret Manager (fuente para la reconstrucción; Terraform la reinyecta en `kube-system` **antes** de instalar el controlador) y el schedule `velero-llave`, que respalda a diario el Secret de la llave de `kube-system` en el bucket de Velero (TTL 30 días). Renovación automática desactivada |
| Reconstrucción manual | `bootstrap.sh` → Terraform (GKE + ArgoCD + app raíz) → app-of-apps por olas con restauración automática de datos |
| Caída de un nodo | PostgreSQL primario + réplica en espera (2 réplicas, en nodos distintos), 3 réplicas de la API, anti-afinidad por nodo, `topologySpreadConstraints`, PDB `minAvailable: 2`, probes de arranque/vida/disponibilidad |
| Flujo de la Práctica 8 (GitOps, entrega progresiva, admisión) | ArgoCD app-of-apps, la API se publica como `Rollout` canary (34 % → 67 % → 100 %) y Kyverno aplica 3 políticas `Enforce`; todo se reconstruye en el mismo bootstrap ([`scripts/verificar-flujo.sh`](./scripts/verificar-flujo.sh)) |

**Servicio con estado verificable:** PostgreSQL (`StatefulSet` de 2 réplicas: primario `postgres-0` y réplica en espera `postgres-1`; PVC `data-postgres-0` de 2 GiB) con 50 pedidos semilla y un CronJob que escribe una "marca" por minuto. La API REST (`servicio-datos`, PostgREST, desplegada como `Rollout`) expone los datos. La huella md5 de `pedidos` demuestra que se restauró el **contenido** y la última marca recuperada da el RPO exacto.

```
P9/
├── scripts/            bootstrap.sh (entrada única), destruir.sh, prueba-*.sh, verificar-secretos.sh
├── terraform/
│   ├── persistente/    buckets, SA de Velero, Secret Manager (no se destruye)
│   └── cluster/        GKE, Workload Identity, llave, ArgoCD, app raíz
├── gitops/
│   ├── apps/           app-of-apps: sealed-secrets, velero, argo-rollouts, kyverno, politicas, restauracion-dr, datos
│   ├── plataforma/     job de restauración automática y políticas de Kyverno
│   └── cargas/datos/   PostgreSQL, API, PDB, CronJob, SealedSecret
├── docs/               informe, runbook, diagrama, guía
├── plantillas/         CI de Terraform
└── evidencias/         registros con marcas de tiempo y capturas
```

## Cómo reconstruir desde cero

```bash
cd P9 && cp p9.env.ejemplo p9.env   # completar PROYECTO y REPO_URL
./scripts/bootstrap.sh
```

Paso a paso completo (incluida la preparación única): [`docs/RUNBOOK.md`](./docs/RUNBOOK.md).

## Minutaje del video

| Minuto | Punto demostrado |
|---|---|
| `00:00` | Arquitectura y objetivos RTO/RPO declarados |
| `<<>>` | Estado remoto en GCS y bloqueo (sin `.tfstate` en el repositorio) |
| `<<>>` | Schedule de Velero, respaldos `Completed` y bucket externo |
| `<<>>` | Pérdida de nodo: drenaje con la sonda respondiendo |
| `<<>>` | Restauración de datos: borrado, restauración y verificación del contenido |
| `<<>>` | Destrucción total del entorno (cronómetro corriendo) |
| `<<>>` | `bootstrap.sh`: ArgoCD por olas y restauración automática |
| `<<>>` | Secretos descifrados tras la reconstrucción; canary y política de Kyverno operando |
| `<<>>` | RTO/RPO medidos frente a declarados y brecha |
