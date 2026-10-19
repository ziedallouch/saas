# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Read `docs/CURRENT_STATE.md` first — it holds what is done, what remains, and the
failure modes already hit. `README.md` holds the design decisions and the reasons
behind them; do not re-open those while building infrastructure.

## Repository layout

One repo holds the whole project. `gitops/` must stay at the root — every ArgoCD
`path:` and the `gitops_repo_url` in `terraform.tfvars` depend on it. Do not move it
into a subfolder.

| Path | What |
|---|---|
| `gitops/` `terraform/` `ansible/` `scripts/` | infrastructure |
| `app/` | NestJS + Angular application code (empty so far) |
| `planning/` | Task_Plan, Server_Architecture, documentation, QUESTIONS |
| `docs/CURRENT_STATE.md` | where the cluster build actually stands |
| `.claude/skills/next-task/` | the task runner — reads the plan, dispatches by role |
| `.claude/agents/` | `infra` and `backend`. They point here for the rules rather than copying them, so there is one copy to keep true |

## Where this runs

The repo lives on a Windows host but **every tool runs inside WSL2 Ubuntu**:

| | |
|---|---|
| Windows path | `D:\NP\erp-deploy` **on the original machine** — it is a clone of `git@github.com:ziedallouch/saas.git` and may sit anywhere else |
| WSL path | the same path under `/mnt/<drive>/…` |
| Toolchain | ansible, terraform, kubectl, helm, kubeseal — WSL only, none on Windows |
| SSH key | `~/.ssh/id_ed25519` **inside WSL** (files on `/mnt/d` report mode 0777, and SSH refuses world-readable keys) |

Run things through WSL, from PowerShell:

```powershell
wsl.exe -d Ubuntu -- bash /mnt/d/NP/erp-deploy/.tmp/<script>.sh
```

Two traps when driving WSL from the Windows side:

- **Git Bash rewrites `/mnt/...` into `C:/Program Files/Git/mnt/...`.** Prefix with
  `MSYS_NO_PATHCONV=1`, or call `wsl.exe` from PowerShell instead.
- **Inline `bash -lc` with loops and `$var` gets mangled** across the wsl.exe boundary.
  Write a script to `.tmp/` (gitignored) and run the file.

## The VPN is part of the environment

The VMs are reachable only through FortiClient, which installs a **full tunnel**
(`0.0.0.0/0`). It drops regularly. Before blaming anything else:

```powershell
Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*Fortinet*" }
```

`Disconnected` means the cluster is unreachable, not broken. Consequences for how you work:

- Wrap long cluster operations in a **retry loop**; terraform and helm are idempotent.
- Run remote installs **detached** (`setsid nohup … > log 2>&1 &`) so a drop cannot
  abort them halfway, then poll the log.
- `dial tcp … i/o timeout` is the VPN. A failure that repeats at the *same step and the
  same elapsed time* is deterministic and is **not** the VPN — diagnose it instead.

## Commands

There is no build or test suite; the checks are per-tool.

```bash
export KUBECONFIG=$PWD/kubeconfig   # from the repo root; per-shell, set it in every window
```

`kubectl` failing with `localhost:8080 connection refused` means this variable is unset
in that window.

```bash
# Ansible — install/repair k3s on both nodes
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml --syntax-check
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml --limit erp-node-2

# Terraform — platform bootstrap, runs once
cd terraform/bootstrap
terraform fmt && terraform validate
terraform plan -out=/tmp/bs.tfplan      # always show the plan before applying
terraform apply /tmp/bs.tfplan

# Helm chart in-repo
helm lint terraform/bootstrap/charts/root-app --set namespace=argocd --set repoURL=x --set targetRevision=main
```

Verification that matters most — `erp_app` must not bypass RLS:

```bash
kubectl -n erp-data exec -it erp-postgres-1 -- psql -U postgres -d erp -c \
  "SELECT rolname, rolbypassrls, rolsuper FROM pg_roles WHERE rolname LIKE 'erp%';"
```

If `erp_app` returns `rolbypassrls = t`, every cross-tenant isolation test in the
application is meaningless. Treat it as build-breaking.

## Architecture

Three layers, each handing off to the next. The split is deliberate — see README.

```
Ansible  →  k3s on two VMs, kubeconfig to ./kubeconfig
Terraform →  Sealed Secrets + ArgoCD + the root Application   (bootstrap, once)
ArgoCD   →  everything else, from gitops/ in this repo
```

Nothing below the Terraform layer is ever `kubectl apply`-ed by hand.

**Node roles.** `erp-node-1` = `erp.devsty.io/role=data` (k3s server, Postgres ×2, Redis);
`erp-node-2` = `role=apps` (ArgoCD, Keycloak, ingress, controllers). Every workload sets
a `nodeSelector` on one of these. Both VMs have 4 GB; the memory budget in README has
~800 MB headroom per node, so **an unsized workload will start evicting things** — always
set requests and limits.

**ArgoCD sync waves** order the rollout; `gitops/root/` is the only directory the root
Application reads:

| Wave | Application | Path |
|---|---|---|
| -2 | cert-manager, ingress-nginx, cnpg-operator | upstream charts |
| -1 | `platform-config` (ClusterIssuers) | `gitops/platform` |
| 0 | `data` (Postgres ×2, Redis) | `gitops/data` |
| 1 | `apps` (Keycloak) | `gitops/apps` |

**The repo URL appears in two places and they must agree:**
`terraform/bootstrap/terraform.tfvars` (`gitops_repo_url`) and
`gitops/root/10-stacks.yaml` (three `repoURL:` lines). If they disagree the root
Application reports Healthy while its children never appear.

**The root Application is a second Helm release, on purpose.** It lives in
`terraform/bootstrap/charts/root-app/`, not in the argo-cd release's `extraObjects`.
Helm resolves the kind of every rendered manifest *before* applying any of them, and the
argo-cd chart keeps its `argoproj.io` CRDs under `templates/`, not `crds/` — so an
`Application` inside that same release fails with `no matches for kind "Application"`,
nothing is applied, and retrying never helps. Do not merge it back in.

## Invariants — change only with a stated reason and agreement

- **k3s version** is pinned (`k3s_version` in the inventory). Both nodes must run the
  identical binary; the playbook copies it from node-1 and asserts the sha256 matches.
- **Postgres role model**: `erp_migrator` owns the schema, `erp_app` has DML only, no
  `BYPASSRLS`, `FORCE ROW LEVEL SECURITY` on every tenant-scoped table.
- **PgBouncer runs in transaction mode**, which is what makes `SET LOCAL` mandatory in
  the application.
- Node labels, namespace names, memory limits.

## Hard rules

- **Never `curl … | sh` from a playbook or script.** `sh -s` reads the script from stdin,
  so anything it runs that touches stdin hangs forever; and if curl fails, sh exits 0 and
  the caller sees a false success. Download to a file, then execute it.
- **Never run two installers against the same node at once.** Guard with a pattern that
  cannot match its own command line (`ps -eo args | grep -E "[k]3s-install\.sh"`).
- **Never commit secrets**: no plaintext passwords, no `kubeconfig`, no k3s node token,
  no `.tfvars`, no sealing key. `.gitignore` covers these.
- Secrets are sealed by piping `kubectl create secret --dry-run=client` straight into
  `kubeseal`; plaintext never touches disk or git. Procedure in README → "Secrets".
- `keycloak-db-credentials` is needed in **two** namespaces with the **same** password —
  SealedSecrets are sealed per-namespace, so that is two files.
- Ask before anything destructive: reinstalling k3s, deleting PVCs, wiping a node,
  `terraform destroy`, `helm rollback`.
- When something hangs, diagnose before retrying (`ps` on the remote,
  `journalctl -u <service>`, `kubectl describe`). Repeating a hanging command produces
  two hanging commands.

## Upstream drift already hit

Pinned versions do not protect against the source moving:

- The Sealed Secrets chart moved from `bitnami-labs.github.io` to
  `bitnami.github.io/sealed-secrets`; the old URL 404s on `index.yaml` and surfaces as
  "not a valid chart repository".
- `applicationSet.enabled` **does not exist** in argo-cd chart 7.7.11 — it is accepted and
  silently ignored, and the controller runs with no requests or limits. Use `replicas = 0`.

Image pulls total ~1.5 GB on a slow link. Pods in `ImagePullBackOff` are usually queued,
not broken — check `kubectl describe pod` before treating it as a failure.

Keep `docs/CURRENT_STATE.md` accurate as you work; it is what the next person inherits.
