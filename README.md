# erp-deploy

Infrastructure for the ERP SaaS **non-production** cluster: two VMs, k3s, GitOps.

> **This cluster is not production and must not become production.** One control-plane
> node means no etcd quorum; node-local storage means a dead node is a dead database.
> Both are fine for dev and staging and unacceptable for client data. The production
> cluster is a separate decision, deliberately deferred.

---

## What runs where

| VM | IP | k3s role | Label | Carries |
|---|---|---|---|---|
| `erp-node-1` | 192.168.152.230 | server | `erp.devsty.io/role=data` | control plane, Postgres ×2, Redis |
| `erp-node-2` | 192.168.152.231 | agent | `erp.devsty.io/role=apps` | ArgoCD, Keycloak, ingress, controllers |

Both VMs are RHEL-family with **4 GB RAM**. Everything below is sized against that, and
there is roughly 800 MB of headroom per node. That is enough, and it is not enough to be
careless with — adding an unsized workload will start evicting things.

### Memory budget

| node-1 | limit | | node-2 | limit |
|---|---|---|---|---|
| k3s server | ~600 MB | | k3s agent | ~350 MB |
| erp-postgres | 1024 MB | | ArgoCD (4 components) | 816 MB |
| keycloak-postgres | 384 MB | | Keycloak | 1280 MB |
| redis | 256 MB | | ingress-nginx | 256 MB |
| | | | cert-manager ×3 | 384 MB |
| | | | cnpg-operator | 192 MB |
| | | | pgbouncer | 256 MB |
| **total** | **~2.3 GB** | | **total** | **~3.5 GB** |

Keycloak is over half of node-2. Its heap is capped explicitly at 768 MB rather than
left to `MaxRAMPercentage`, because the JVM's container default takes ~70% of the limit
for heap alone and then overruns it with metaspace and thread stacks — which shows up as
an OOMKill with no heap error, and costs an afternoon to diagnose.

ArgoCD runs without dex, notifications and applicationset. Turning any of them back on
costs 150–250 MB that node-2 does not have spare.

## Tooling split, and why

| Layer | Tool | Reason |
|---|---|---|
| k3s install on the two VMs | **Ansible** | The VMs already exist. Terraform provisions infrastructure; there is no infrastructure to provision. |
| Platform bootstrap (ArgoCD, Sealed Secrets) | **Terraform** | Needs to run exactly once, before GitOps can manage anything, and needs to produce outputs (kubeconfig paths, admin password) |
| Everything else | **ArgoCD** | Declarative from the first commit. Nothing is ever `kubectl apply`-ed by hand. |

Terraform installing ArgoCD and then ArgoCD managing everything is the standard
resolution of the bootstrap chicken-and-egg. Sealed Secrets is in the Terraform layer
for the same reason — ArgoCD cannot sync an encrypted secret before the controller that
decrypts it exists.

---

## Decisions taken in this repo

**k3s, not kubeadm.** Single binary, sane defaults, trivial to tear down and rebuild.
Nothing here depends on k3s specifically; the manifests are vanilla Kubernetes.

**Traefik disabled, ingress-nginx installed.** k3s bundles Traefik. ingress-nginx has
broader documentation and more people know its annotations. Reversible — it is one
ArgoCD Application.

**ServiceLB (k3s built-in), not MetalLB.** With two nodes on a LAN, klipper-lb binding
host ports is enough. MetalLB earns its place when you want one stable VIP that survives
a node reboot; `gitops/platform/metallb.yaml.disabled` is there for when you do.

**local-path storage, Postgres pinned to node-1.** Two nodes cannot give you replicated
storage worth trusting (Longhorn with `replica=2` has no tiebreaker). Node-local volumes
with an explicit node pin are honest about the constraint instead of hiding it.

**CloudNativePG, not a Postgres Helm chart.** Because of the `Pooler` CRD — it gives you
PgBouncer in **transaction mode**, which is what the architecture assumes, and it manages
roles declaratively (`managed.roles`), which is how `erp_app` gets created without
`BYPASSRLS` and without a password in git.

**Redis as a plain Deployment with `emptyDir`.** It holds only cache. Losing it causes a
resolution storm against `erp-platform-core`, not data loss. Persistence, replication and
a chart dependency would all be machinery for nothing.

**cert-manager with a private CA, not Let's Encrypt.** LAN-only, no public DNS. The CA
certificate is generated once and distributed to the team; Keycloak refuses most flows
over plain HTTP, so TLS is not optional even internally.

**Sealed Secrets.** Works with no cloud and no Vault. Note the limitation now rather than
later: rotating the context-envelope HMAC (`Server_Architecture.md` §3.1) means
re-sealing and committing, which is a deploy, not an operation. Revisit at production.

---

---

## Before anything: the VMs are clones

Both hosts present the **same SSH host key fingerprint** and both are named
`localhost`. node-2 is a clone of node-1, and three things must differ before k3s will
work:

| Shared | Consequence |
|---|---|
| **hostname** (`localhost`) | k3s derives the node name from the hostname. Two nodes with the same name collide; the second never joins cleanly. **Hard blocker.** |
| **`/etc/machine-id`** | systemd and parts of the CNI path key off it. Symptoms are intermittent and confusing. |
| **SSH host keys** | Either machine can impersonate the other to anything that trusts that fingerprint. Also why your client warned about a known key under a different address. |

The playbook sets hostnames itself. The identity regeneration is opt-in, because
changing `machine-id` on a running host can upset systemd units mid-flight:

```bash
# On node-2 only, then reboot it.
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --limit erp-node-2 -e regenerate_identity=true
```

Remove the stale entry from your workstation afterwards, or SSH will keep complaining:

```powershell
ssh-keygen -R 192.168.152.231
```

Your VM template should have been sealed before cloning (`rm -f /etc/ssh/ssh_host_*`,
`truncate -s 0 /etc/machine-id`). Worth fixing in the template so the next clone is clean.

---

## RHEL specifics the playbook handles

- `nfs-utils`, not `nfs-common`.
- **firewalld** is enabled by default and breaks the cluster in a way that looks like an
  application bug: nodes join, pods start, and cross-node traffic silently vanishes
  because VXLAN on `8472/udp` is dropped. The playbook trusts the pod and service CIDRs
  and opens 6443, 10250, 8472, 80 and 443.
- **SELinux** — the k3s installer pulls `k3s-selinux` from `rpm.rancher.io`. If these VMs
  have no outbound internet, that step fails and k3s will not start under enforcing mode.
  The playbook installs `container-selinux` first and reports the SELinux state so you
  see it before it bites.
- Swap is disabled. On a 4 GB node swap does not save you; it converts a loud, obvious
  OOMKill into everything being slow, which is much harder to diagnose.

---

## Run order

```bash
# 0. Fill in your two VMs
ansible-galaxy collection install -r ansible/requirements.yml
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
$EDITOR ansible/inventory/hosts.yml

# 1. Install k3s on both nodes, fetch kubeconfig to ./kubeconfig
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes          # both Ready before continuing

# 2. Bootstrap ArgoCD + Sealed Secrets, register this repo, create the root Application
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init && terraform apply

terraform output -raw argocd_admin_password

# 3. Seal the secrets ArgoCD is waiting for (see "Secrets" below), commit, push.
#    ArgoCD syncs everything else.
```

Add to every team member's hosts file (or your internal DNS). ingress-nginx runs as a
DaemonSet, so either node IP works:

```
192.168.152.231  argocd.erp.lan keycloak.erp.lan api.erp.lan
```

On Windows that file is `C:\Windows\System32\drivers\etc\hosts`, edited as administrator.

---

## Secrets

Four secrets must exist before the data layer becomes healthy. Generate, seal, commit:

```bash
kubeseal --fetch-cert > sealed-secrets.pem   # once

# CNPG requires type kubernetes.io/basic-auth with username + password keys.
seal_basic_auth() {          # $1 name  $2 namespace  $3 username  $4 outfile
  kubectl create secret generic "$1" --namespace "$2" \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$3" \
    --from-literal=password="$(openssl rand -base64 24)" \
    --dry-run=client -o yaml \
  | kubeseal --cert sealed-secrets.pem -o yaml > "$4"
}

seal_basic_auth erp-migrator-credentials erp-data erp_migrator \
  gitops/data/sealed-erp-migrator.yaml
seal_basic_auth erp-app-credentials      erp-data erp_app \
  gitops/data/sealed-erp-app.yaml

# Keycloak's database password is needed in TWO namespaces — erp-data for the CNPG
# cluster, erp-apps for the Deployment. SealedSecrets are sealed against a specific
# namespace, so this is two files, and both must carry the SAME password.
KC_DB_PW="$(openssl rand -base64 24)"
for ns in erp-data erp-apps; do
  kubectl create secret generic keycloak-db-credentials --namespace "$ns" \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=keycloak \
    --from-literal=password="$KC_DB_PW" \
    --dry-run=client -o yaml \
  | kubeseal --cert sealed-secrets.pem -o yaml \
    > "gitops/$([ "$ns" = erp-data ] && echo data || echo apps)/sealed-keycloak-db-$ns.yaml"
done
unset KC_DB_PW

kubectl create secret generic redis-credentials --namespace erp-data \
  --from-literal=password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml \
  | kubeseal --cert sealed-secrets.pem -o yaml > gitops/data/sealed-redis.yaml

kubectl create secret generic keycloak-bootstrap-admin --namespace erp-apps \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml \
  | kubeseal --cert sealed-secrets.pem -o yaml > gitops/apps/sealed-keycloak-admin.yaml
```

The plaintext never touches disk or git — `--dry-run=client` pipes straight into
`kubeseal`. Record the generated passwords in your password manager as you go, because
you cannot read them back out of a SealedSecret.

> **Back up the Sealed Secrets private key.** It is the one piece of state in this
> cluster that cannot be rebuilt from git. Lose it and every sealed file becomes
> undecryptable — you regenerate all credentials by hand.
>
> ```bash
> kubectl -n kube-system get secret \
>   -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.yaml
> ```
>
> Store it in your password manager. Not in this repo.

---

## Distributing the CA

After `platform-ca` issues its first certificate:

```bash
kubectl -n cert-manager get secret erp-lan-ca-key-pair \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > erp-lan-ca.crt
```

Each developer imports that once (system trust store, and Java's if they run Keycloak
tooling locally). Browsers will otherwise reject every internal hostname.

---

## What this deliberately does not include

Prometheus, Grafana, Loki, Jaeger, a container registry, CI pipelines, backups. All of
Phase 1's observability stack is waiting on something to observe. Backups are a
production decision bundled with the production cluster.

The one exception worth reconsidering early: a **container registry**. The moment you
build the first service image you will need somewhere to push it. `ghcr.io` with an
imagePullSecret is the least work; a self-hosted registry is one more ArgoCD Application.

---

## Verification

After ArgoCD reports everything Synced and Healthy:

```bash
# Postgres is up, and erp_app genuinely cannot bypass RLS
kubectl -n erp-data exec -it erp-postgres-1 -- psql -U postgres -d erp -c \
  "SELECT rolname, rolbypassrls, rolsuper FROM pg_roles WHERE rolname LIKE 'erp%';"
#   erp_migrator | f | f
#   erp_app      | f | f     <- both false, or the isolation model is already broken

# PgBouncer is in transaction mode, which is what makes SET LOCAL mandatory
kubectl -n erp-data exec -it deploy/erp-postgres-pooler-rw -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "SHOW CONFIG;" | grep pool_mode

# Keycloak answers over TLS
curl -k https://keycloak.erp.lan/realms/master/.well-known/openid-configuration
```

The `rolbypassrls = f` check is the one that matters. If `erp_app` ever comes back `t`,
every cross-tenant test in the codebase is meaningless.
