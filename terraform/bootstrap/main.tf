###############################################################################
# Bootstrap layer.
#
# Everything here exists because ArgoCD cannot install itself, and cannot sync a
# SealedSecret before the controller that decrypts it is running. Nothing else
# belongs in this file — if you are tempted to add an application here, add an
# ArgoCD Application under gitops/ instead.
###############################################################################

locals {
  namespaces = ["argocd", "erp-data", "erp-apps", "erp-platform"]
}

resource "kubernetes_namespace_v1" "core" {
  for_each = toset(local.namespaces)

  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/managed-by" = "terraform-bootstrap"
    }
  }
}

###############################################################################
# Sealed Secrets — must exist before ArgoCD syncs anything holding credentials.
###############################################################################

resource "helm_release" "sealed_secrets" {
  name       = "sealed-secrets"
  repository = "https://bitnami-labs.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = var.sealed_secrets_chart_version
  namespace  = "kube-system"

  set {
    name  = "fullnameOverride"
    value = "sealed-secrets-controller" # kubeseal's default lookup name
  }

  # The controller's private key is the one piece of state in this cluster that
  # cannot be regenerated from git. Back it up before you ever rebuild a node:
  #   kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  #     -o yaml > sealed-secrets-key.yaml    # then store it somewhere safe, NOT in git
}

###############################################################################
# ArgoCD
###############################################################################

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.core["argocd"].metadata[0].name

  values = [yamlencode({
    global = {
      nodeSelector = var.apps_node_selector
    }

    configs = {
      params = {
        # ingress-nginx terminates TLS; ArgoCD should not also try to.
        "server.insecure" = true
      }
      cm = {
        # Without this, ArgoCD reports CNPG clusters as permanently OutOfSync
        # because the operator writes defaults back into the spec.
        "resource.customizations.ignoreDifferences.postgresql.cnpg.io_Cluster" = yamlencode({
          jsonPointers = ["/spec/bootstrap"]
        })
      }
    }

    #########################################################################
    # Sized for a 4 GB node. Default ArgoCD wants roughly 1 GB across its
    # components; this trims it to about 600 MB by switching off the parts
    # nothing here uses.
    #########################################################################
    dex            = { enabled = false } # no SSO into ArgoCD; local admin only
    notifications  = { enabled = false } # no Slack/webhook notifications yet
    applicationSet = { enabled = false } # no ApplicationSets in gitops/

    # Quoted: HCL will not accept a hyphen in a bare object key.
    "redis-ha" = { enabled = false }

    controller = {
      replicas = 1
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    repoServer = {
      replicas = 1
      resources = {
        requests = { cpu = "100m", memory = "192Mi" }
        limits   = { memory = "384Mi" }
      }
    }

    server = {
      replicas = 1
      resources = {
        requests = { cpu = "50m", memory = "96Mi" }
        limits   = { memory = "192Mi" }
      }
      ingress = {
        enabled          = true
        ingressClassName = "nginx"
        hostname         = "argocd.${var.base_domain}"
        annotations = {
          "cert-manager.io/cluster-issuer" = "erp-ca"
        }
        tls = [{
          secretName = "argocd-server-tls"
          hosts      = ["argocd.${var.base_domain}"]
        }]
      }
    }

    redis = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }
    }

    #########################################################################
    # The root Application ships as part of this release, not as a separate
    # kubernetes_manifest resource.
    #
    # kubernetes_manifest performs a server-side dry-run at PLAN time, so it
    # fails on a fresh cluster with "no matches for kind Application" — the
    # CRD it needs is installed by this very release, which has not run yet.
    # Helm applies CRDs before objects, so putting it here sidesteps the
    # ordering problem entirely.
    #########################################################################
    extraObjects = [
      {
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata = {
          name       = "root"
          namespace  = "argocd"
          finalizers = ["resources-finalizer.argocd.argoproj.io"]
        }
        spec = {
          project = "default"
          source = {
            repoURL        = var.gitops_repo_url
            targetRevision = var.gitops_repo_revision
            path           = "gitops/root"
            directory      = { recurse = true }
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated   = { prune = true, selfHeal = true }
            syncOptions = ["CreateNamespace=false"]
          }
        }
      }
    ]
  })]

  depends_on = [
    helm_release.sealed_secrets,
    kubernetes_secret_v1.gitops_repo,
  ]
}

###############################################################################
# Repository credentials (private repos only)
###############################################################################

resource "kubernetes_secret_v1" "gitops_repo" {
  count = var.gitops_repo_password == "" ? 0 : 1

  metadata {
    name      = "gitops-repo"
    namespace = kubernetes_namespace_v1.core["argocd"].metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.gitops_repo_url
    username = var.gitops_repo_username
    password = var.gitops_repo_password
  }

  depends_on = [kubernetes_namespace_v1.core]
}
