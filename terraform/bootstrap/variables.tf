variable "kubeconfig_path" {
  description = "Path to the kubeconfig produced by the Ansible play."
  type        = string
  default     = "../../kubeconfig"
}

variable "gitops_repo_url" {
  description = "Git URL of this repository, as ArgoCD will clone it."
  type        = string
}

variable "gitops_repo_revision" {
  description = "Branch or tag ArgoCD tracks."
  type        = string
  default     = "main"
}

variable "gitops_repo_username" {
  description = "Username for a private repo. Leave empty for a public one."
  type        = string
  default     = ""
}

variable "gitops_repo_password" {
  description = "Token or password for a private repo. Leave empty for a public one."
  type        = string
  default     = ""
  sensitive   = true
}

variable "base_domain" {
  description = "Internal domain serving the cluster, e.g. erp.lan."
  type        = string
  default     = "erp.lan"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version. Pinned deliberately."
  type        = string
  default     = "7.7.11"
}

variable "sealed_secrets_chart_version" {
  description = "sealed-secrets Helm chart version. Pinned deliberately."
  type        = string
  default     = "2.16.2"
}

variable "apps_node_selector" {
  description = "Where platform workloads that are not data stores should land."
  type        = map(string)
  default     = { "erp.devsty.io/role" = "apps" }
}
