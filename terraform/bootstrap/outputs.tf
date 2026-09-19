output "argocd_url" {
  value = "https://argocd.${var.base_domain}"
}

# Deliberately not a data source. Reading argocd-initial-admin-secret from Terraform
# means the plaintext password lands in terraform.tfstate, which is a local file with
# no encryption. Fetch it with kubectl once and change it immediately.
output "next_steps" {
  value = <<-EOT

    1. Get the initial ArgoCD password (then change it and delete the secret):
         kubectl -n argocd get secret argocd-initial-admin-secret \
           -o jsonpath='{.data.password}' | base64 -d; echo
         # after changing it:
         kubectl -n argocd delete secret argocd-initial-admin-secret

    2. Trust the CA once cert-manager has issued it:
         kubectl -n cert-manager get secret erp-lan-ca-key-pair \
           -o jsonpath='{.data.tls\.crt}' | base64 -d > erp-lan-ca.crt

    3. Point DNS (or /etc/hosts) for argocd/keycloak/api.${var.base_domain}
       at either node IP — ingress-nginx runs as a DaemonSet, so both work.

    4. Seal the credential secrets (README, "Secrets"), commit and push.
       Until then erp-postgres and keycloak stay Progressing. That is expected,
       not a failure.

    5. Back up the Sealed Secrets private key. It cannot be rebuilt from git.
  EOT
}
