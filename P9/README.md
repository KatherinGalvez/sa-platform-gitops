# Práctica 9 — Continuidad operativa y recuperación ante desastres

Universidad de San Carlos de Guatemala · Facultad de Ingeniería · Software Avanzado
Estudiante: `<<Nombre>>` · Carné: `<<carné>>`

El ecosistema de microservicios de las prácticas anteriores se vuelve **recuperable**: el entorno completo se destruye (clúster y discos) y se reconstruye con un solo comando en Google Cloud (GKE), restaurando datos y secretos, con tiempos medidos contra objetivos declarados antes de las pruebas.

## 4.1 Tabla de enlaces obligatoria

| Ítem | Enlace o dato |
|---|---|
| Repositorio GitOps | `<<https://github.com/USUARIO/REPO>>` — carpeta [`P9/gitops`](./gitops) |
| Aplicación raíz en ArgoCD | `p9-raiz`, namespace `argocd` (definida en [`terraform/cluster/main.tf`](./terraform/cluster/main.tf), lee [`gitops/apps`](./gitops/apps)) |
| Punto de entrada del bootstrap | [`P9/scripts/bootstrap.sh`](./scripts/bootstrap.sh) |
| Backend remoto de Terraform | Google Cloud Storage `gs://<<proyecto>>-p9-tfstate`, prefijos `p9/persistente` y `p9/cluster`, bloqueo nativo de GCS, bucket versionado |
| Schedule de Velero | `velero-horario` (namespace `velero`), cada hora, TTL 168 h → `gs://<<proyecto>>-p9-velero` ([`gitops/apps/10-velero.yaml`](./gitops/apps/10-velero.yaml)) |
| Reconstrucción cronometrada | [`evidencias/dr-<<fecha>>.log`](./evidencias) y [`evidencias/resumen-dr-<<fecha>>.md`](./evidencias) |
| Restauración de datos | [`evidencias/restauracion-datos-<<fecha>>.log`](./evidencias) y [`evidencias/resumen-restauracion-<<fecha>>.md`](./evidencias) |
| Prueba de pérdida de nodo | [`evidencias/perdida-nodo-<<fecha>>.log`](./evidencias) y [`evidencias/sonda-<<fecha>>.log`](./evidencias) |
| RTO y RPO declarados | Objetivo RTO **45 min** / RPO **60 min** · Medido RTO `<<>>` / RPO `<<>>` ([informe](./docs/INFORME-DR.md)) |
| Video demostrativo | `<<URL>>` — minutaje abajo |

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
| Llave de Sealed Secrets solo dentro del clúster | Llave en Google Secret Manager; Terraform la reinyecta en `kube-system` **antes** de instalar el controlador; renovación automática desactivada |
| Reconstrucción manual | `bootstrap.sh` → Terraform (GKE + ArgoCD + app raíz) → app-of-apps por olas con restauración automática de datos |
| Caída de un nodo | 3 réplicas de la API, anti-afinidad por nodo, `topologySpreadConstraints`, PDB `minAvailable: 2`, probes de arranque/vida/disponibilidad |

**Servicio con estado verificable:** PostgreSQL (`StatefulSet`, PVC 2 GiB) con 50 pedidos semilla y un CronJob que escribe una "marca" por minuto. La API REST (`servicio-datos`, PostgREST) expone los datos. La huella md5 de `pedidos` demuestra que se restauró el **contenido** y la última marca recuperada da el RPO exacto.

```
P9/
├── scripts/            bootstrap.sh (entrada única), destruir.sh, prueba-*.sh, verificar-secretos.sh
├── terraform/
│   ├── persistente/    buckets, SA de Velero, Secret Manager (no se destruye)
│   └── cluster/        GKE, Workload Identity, llave, ArgoCD, app raíz
├── gitops/
│   ├── apps/           app-of-apps: sealed-secrets, velero, restauracion-dr, datos, sistema-p8
│   ├── plataforma/     job de restauración automática
│   └── cargas/datos/   PostgreSQL, API, PDB, CronJob, SealedSecret
├── docs/               informe, runbook, diagrama, guía
├── plantillas/         resiliencia para microservicios P4/P5, CI de Terraform
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
| `<<>>` | Secretos descifrados tras la reconstrucción y flujo de P8 operando |
| `<<>>` | RTO/RPO medidos frente a declarados y brecha |
