# Diagrama del bootstrap y de la recuperación

Orden de reconstrucción y dependencias. Verde = automático; amarillo = manual (una sola vez, antes de cualquier desastre); azul = persiste fuera del clúster y sobrevive al desastre.

```mermaid
flowchart TD
    subgraph PREVIO["Preparación única (manual, antes del desastre)"]
        M1["00-preparar-gcp.sh<br/>APIs + bucket de estado"]:::manual
        M2["01-llave-sealed-secrets.sh<br/>llave a Secret Manager"]:::manual
        M3["02-configurar-gitops.sh<br/>sellar secretos + git push"]:::manual
    end

    subgraph PERSISTE["Sobrevive al desastre (fuera del clúster)"]
        S1[("GCS: estado Terraform<br/>bloqueo nativo")]:::persiste
        S2[("GCS: respaldos Velero<br/>velero-horario, TTL 7 d")]:::persiste
        S3[("Secret Manager<br/>llave Sealed Secrets")]:::persiste
        S4[("GitHub público<br/>repositorio GitOps")]:::persiste
    end

    INICIO(["./P9/scripts/bootstrap.sh<br/>PUNTO DE ENTRADA ÚNICO"]):::auto
    T1["1. Terraform persistente<br/>(verifica buckets, SA, secretos)"]:::auto
    T2["2. Terraform clúster<br/>GKE + node pool 3 nodos"]:::auto
    T3["3. Workload Identity<br/>velero-server → GSA"]:::auto
    T4["4. Secret llave Sealed Secrets<br/>en kube-system"]:::auto
    T5["5. Helm: ArgoCD"]:::auto
    T6["6. Helm: app raíz p9-raiz"]:::auto

    W0A["Ola 0: sealed-secrets<br/>adopta la llave restaurada"]:::auto
    W0B["Ola 0: velero + node-agent<br/>sincroniza respaldos del bucket"]:::auto
    W1["Ola 1: Job restauracion-dr<br/>restaura ns datos del último respaldo"]:::auto
    W2["Ola 2: datos<br/>PostgreSQL + API + PDB + CronJob"]:::auto
    W3["Ola 3: sistema-p8<br/>microservicios P4/P5, Rollouts, políticas"]:::auto
    V["Verificación: apps Healthy,<br/>secretos, huella de datos, HTTP 200<br/>MARCA SERVICIO_RESPONDE"]:::auto

    M1 --> S1
    M2 --> S3
    M3 --> S4
    M1 -. "crea" .-> S2

    INICIO --> T1 --> T2 --> T3 --> T4 --> T5 --> T6
    S1 -. "estado" .-> T1
    S3 -. "lee llave" .-> T4
    T6 --> W0A & W0B
    S4 -. "manifiestos" .-> T6
    W0A --> W1
    W0B --> W1
    S2 -. "último respaldo" .-> W1
    W1 --> W2 --> W3 --> V

    classDef auto fill:#d4edda,stroke:#2e7d32,color:#1b3a1f
    classDef manual fill:#fff3cd,stroke:#b8860b,color:#4a3800
    classDef persiste fill:#dbe9f7,stroke:#1f5fa8,color:#0d2b4d
```

## Por qué este orden

| Dependencia | Motivo |
|---|---|
| Llave (4) antes de ArgoCD (5) | Si el controlador de Sealed Secrets arranca sin llave, genera una nueva y los secretos del repositorio quedan ilegibles. |
| Velero (ola 0) antes de restauración (ola 1) | La restauración necesita los CRDs de Velero y la sincronización de respaldos desde el bucket. |
| Restauración (ola 1) antes de datos (ola 2) | Velero no sobrescribe un PVC existente: si ArgoCD creara primero la base de datos vacía, la restauración se omitiría. |
| Datos (ola 2) antes de P8 (ola 3) | Los microservicios dependen de la base de datos y de los secretos ya descifrados. |
| Salud de `Application` personalizada en ArgoCD | Sin ella las olas no esperan a que la ola anterior esté *Healthy*. |
