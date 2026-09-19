terraform {
  required_version = ">= 1.6"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }

  # Local state is acceptable here and only here: this layer runs once, and the
  # cluster it bootstraps is disposable. Do not copy this backend to production.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = "erp-nonprod"
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = "erp-nonprod"
  }
}
