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
  name = "sealed-secrets"
  # The project moved from bitnami-labs/ to bitnami/ and the old GitHub Pages repo
  # now 404s on index.yaml, which surfaces as "not a valid chart repository". Same
  # chart, same pinned version (2.16.2 / appVersion 0.27.2, matching kubeseal 0.27.1).
  repository = "https://bitnami.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = var.sealed_secrets_chart_version
  namespace  = "kube-system"

  # The controller image is small, so waiting for it is still worth it — but the
  # default 5 minutes is not enough on a link this slow.
  timeout = 900

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

  # ArgoCD is ~816 MB of images over a ~115 KB/s link, through a VPN that drops every
  # few minutes. With the provider defaults (wait = true, timeout = 300) the apply holds
  # one connection open for the whole pull and fails on either count — it did, with
  # "http2: client connection lost".
  #
  # wait = false submits the manifests and returns; the pulling then happens inside the
  # cluster, where the workstation's VPN is irrelevant. Terraform therefore does NOT
  # confirm ArgoCD is healthy — verify that separately and afterwards with:
  #   kubectl -n argocd rollout status deploy/argocd-server --timeout=30m
  wait    = false
  timeout = 1800

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
    dex           = { enabled = false } # no SSO into ArgoCD; local admin only
    notifications = { enabled = false } # no Slack/webhook notifications yet

    # applicationSet has NO "enabled" key in chart 7.7.11 — setting one is
    # accepted and silently ignored, and the controller runs anyway. It was
    # running here with no requests and no limits at all, which on a node this
    # small is how you get evictions later. replicas = 0 is the supported way
    # to switch it off; verify with:
    #   kubectl -n argocd get deploy argocd-applicationset-controller
    applicationSet = { replicas = 0 } # no ApplicationSets in gitops/

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
    # The root Application does NOT ship in this release.
    #
    # The obvious two options both fail on a fresh cluster:
    #   - kubernetes_manifest does a server-side dry-run at PLAN time, so it
    #     fails with "no matches for kind Application" before anything exists.
    #   - extraObjects here fails too, which is less obvious: Helm resolves the
    #     kind of EVERY rendered manifest before applying any of them, and this
    #     chart keeps its argoproj.io CRDs under templates/, not crds/. So the
    #     CRD is not registered yet at mapping time and the whole release is
    #     rejected — nothing is applied, so retrying never helps.
    #
    # It is therefore a second, tiny Helm release (charts/root-app) that runs
    # after this one, when the CRDs exist. See helm_release.root_app below.
    #########################################################################
    extraObjects = []
  })]

  depends_on = [
    helm_release.sealed_secrets,
    kubernetes_secret_v1.gitops_repo,
  ]
}

###############################################################################
# The ArgoCD root Application — second release, after the CRDs exist.
#
# argocd above runs with wait = false, which does not weaken this: Helm still
# applies every manifest in that release (CRDs included) before returning; it
# just does not block until the pods are Ready. So argoproj.io/v1alpha1 is
# registered by the time this release is rendered.
###############################################################################

resource "helm_release" "root_app" {
  name      = "argocd-root"
  chart     = "${path.module}/charts/root-app"
  namespace = kubernetes_namespace_v1.core["argocd"].metadata[0].name

  values = [yamlencode({
    namespace      = kubernetes_namespace_v1.core["argocd"].metadata[0].name
    repoURL        = var.gitops_repo_url
    targetRevision = var.gitops_repo_revision
  })]

  depends_on = [helm_release.argocd]
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
