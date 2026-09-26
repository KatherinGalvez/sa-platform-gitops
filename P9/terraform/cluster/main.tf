# =============================================================================
# CAPA DEL CLUSTER (efimera: se destruye y se reconstruye en la prueba de DR)
#   1. Cluster GKE + node pool de 3 nodos
#   2. Workload Identity para Velero
#   3. Llave de Sealed Secrets restaurada desde Secret Manager (ANTES del controlador)
#   4. ArgoCD
#   5. Aplicacion raiz app-of-apps "p9-raiz" -> el resto lo levanta GitOps
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Salidas de la capa persistente (mismo bucket de estado, otro prefijo)
data "terraform_remote_state" "persistente" {
  backend = "gcs"
  config = {
    bucket = var.estado_bucket
    prefix = "p9/persistente"
  }
}

locals {
  velero_gsa = data.terraform_remote_state.persistente.outputs.velero_gsa_email
}

# ---------------------------------------------------------------------------
# 1. Cluster
# ---------------------------------------------------------------------------
resource "google_container_cluster" "p9" {
  name     = var.cluster_name
  location = var.zona

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {}

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = { practica = "p9" }
}

resource "google_container_node_pool" "principal" {
  name       = "principal"
  cluster    = google_container_cluster.p9.id
  location   = var.zona
  node_count = var.nodos

  node_config {
    machine_type = var.tipo_maquina
    disk_size_gb = 50
    disk_type    = "pd-standard"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels       = { practica = "p9" }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ---------------------------------------------------------------------------
# 2. Workload Identity: SA de Kubernetes velero/velero-server -> GSA de Velero
# ---------------------------------------------------------------------------
resource "google_service_account_iam_member" "velero_wi" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.velero_gsa}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[velero/velero-server]"
  depends_on         = [google_container_cluster.p9]
}

# ---------------------------------------------------------------------------
# Proveedores de Kubernetes/Helm apuntando al cluster recien creado
# ---------------------------------------------------------------------------
data "google_client_config" "actual" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.p9.endpoint}"
  token                  = data.google_client_config.actual.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.p9.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.p9.endpoint}"
    token                  = data.google_client_config.actual.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.p9.master_auth[0].cluster_ca_certificate)
  }
}

# ---------------------------------------------------------------------------
# 3. Continuidad de secretos: la MISMA llave vuelve al cluster antes de que
#    arranque el controlador de Sealed Secrets (que la adopta en lugar de
#    generar una nueva).
# ---------------------------------------------------------------------------
data "google_secret_manager_secret_version" "sealed_crt" {
  secret = data.terraform_remote_state.persistente.outputs.sealed_crt_secret
}

data "google_secret_manager_secret_version" "sealed_key" {
  secret = data.terraform_remote_state.persistente.outputs.sealed_key_secret
}

resource "kubernetes_secret_v1" "sealed_secrets_llave" {
  metadata {
    name      = "sealed-secrets-key-p9"
    namespace = "kube-system"
    labels = {
      "sealedsecrets.bitnami.com/sealed-secrets-key" = "active"
    }
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = data.google_secret_manager_secret_version.sealed_crt.secret_data
    "tls.key" = data.google_secret_manager_secret_version.sealed_key.secret_data
  }
  depends_on = [google_container_node_pool.principal]
}

# ---------------------------------------------------------------------------
# 4. ArgoCD
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [yamlencode({
    configs = {
      params = {
        # TLS lo termina el port-forward / Web Preview de Cloud Shell
        "server.insecure" = true
      }
      cm = {
        # Seguimiento por anotacion: los recursos restaurados en otro namespace
        # (datos-restaurado) no se confunden con los de la app "datos".
        "application.resourceTrackingMethod" = "annotation"
        # Salud de Application: necesaria para que las sync-waves del app-of-apps
        # esperen a que cada aplicacion hija este Healthy antes de seguir.
        "resource.customizations.health.argoproj.io_Application" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.health ~= nil then
              hs.status = obj.status.health.status
              if obj.status.health.message ~= nil then
                hs.message = obj.status.health.message
              end
            end
          end
          return hs
        LUA
      }
    }
  })]

  depends_on = [
    google_container_node_pool.principal,
    kubernetes_secret_v1.sealed_secrets_llave,
  ]
}

# ---------------------------------------------------------------------------
# 5. Aplicacion raiz (app-of-apps). A partir de aqui todo es GitOps.
# ---------------------------------------------------------------------------
resource "helm_release" "raiz" {
  name       = "p9-raiz"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      "p9-raiz" = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.repo_url
          targetRevision = var.repo_rama
          path           = "${var.gitops_ruta}/apps"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
          retry = {
            limit   = 10
            backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
          }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd, google_service_account_iam_member.velero_wi]
}

output "cluster" { value = google_container_cluster.p9.name }
output "zona" { value = google_container_cluster.p9.location }
output "app_raiz" { value = "p9-raiz (namespace argocd)" }
