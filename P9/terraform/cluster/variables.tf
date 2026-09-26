variable "project_id" { type = string }
variable "region" { type = string }
variable "zona" { type = string }
variable "estado_bucket" {
  type        = string
  description = "Bucket del estado remoto (para leer las salidas de la capa persistente)"
}

variable "cluster_name" {
  type    = string
  default = "p9-dr"
}

variable "tipo_maquina" {
  type    = string
  default = "e2-standard-2"
}

variable "nodos" {
  type    = number
  default = 3
}

variable "repo_url" {
  type        = string
  description = "Repositorio GitOps publico"
}

variable "repo_rama" {
  type    = string
  default = "main"
}

variable "gitops_ruta" {
  type    = string
  default = "P9/gitops"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.9.2"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.5"
}
