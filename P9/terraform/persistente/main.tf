# =============================================================================
# CAPA PERSISTENTE
# Recursos que DEBEN sobrevivir a la perdida total del cluster:
#   - bucket de respaldos de Velero (fuera del cluster, multi-region)
#   - cuenta de servicio de Velero y sus permisos
#   - contenedores de Secret Manager para la llave de Sealed Secrets
# Esta capa NO se destruye en la prueba de DR.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
  # Backend remoto con bloqueo nativo de GCS. bucket/prefix se pasan con
  # -backend-config desde scripts/lib.sh (no se versionan credenciales).
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region" { type = string }
variable "velero_bucket" { type = string }

# ---------------------------------------------------------------------------
# Almacenamiento de respaldos (fuera del cluster)
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "velero" {
  name                        = var.velero_bucket
  location                    = "US" # multi-region: sobrevive a la caida de una region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # Retencion de respaldo adicional a la TTL de Velero (7 dias): nada queda mas de 30 dias
  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }

  labels = { practica = "p9", uso = "velero" }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Identidad de Velero (se usa via Workload Identity, sin llaves JSON)
# ---------------------------------------------------------------------------
resource "google_service_account" "velero" {
  account_id   = "velero-p9"
  display_name = "Velero P9 (respaldos)"
}

resource "google_storage_bucket_iam_member" "velero_objetos" {
  bucket = google_storage_bucket.velero.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.velero.email}"
}

resource "google_storage_bucket_iam_member" "velero_lectura_bucket" {
  bucket = google_storage_bucket.velero.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.velero.email}"
}

# Velero firma URLs (velero backup logs / describe --details)
resource "google_service_account_iam_member" "velero_firma" {
  service_account_id = google_service_account.velero.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.velero.email}"
}

# ---------------------------------------------------------------------------
# Continuidad de secretos: la llave de Sealed Secrets vive FUERA del cluster.
# Terraform crea solo los contenedores; el material de la llave lo sube
# scripts/01-llave-sealed-secrets.sh (asi la llave privada no pasa por este estado).
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret" "sealed_crt" {
  secret_id = "p9-sealed-secrets-crt"
  replication {
    auto {}
  }
  labels = { practica = "p9" }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "sealed_key" {
  secret_id = "p9-sealed-secrets-key"
  replication {
    auto {}
  }
  labels = { practica = "p9" }
  lifecycle {
    prevent_destroy = true
  }
}

output "velero_bucket" { value = google_storage_bucket.velero.name }
output "velero_gsa_email" { value = google_service_account.velero.email }
output "sealed_crt_secret" { value = google_secret_manager_secret.sealed_crt.secret_id }
output "sealed_key_secret" { value = google_secret_manager_secret.sealed_key.secret_id }
