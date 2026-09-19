# Prompt for a fresh Claude Code agent

Copy everything between the lines into a new Claude Code session started in
`/mnt/d/NP/erp-deploy` inside WSL Ubuntu.

---

You are continuing an infrastructure build already in progress. Read
`docs/CURRENT_STATE.md` in this repository first — it has the environment, what is
done, what remains, and the failure modes already hit. Then read `README.md` for the
run order and the secrets procedure.

## What this is

A **non-production** two-node k3s cluster for an ERP SaaS platform: Postgres with
Row-Level Security, Redis, Keycloak, and ArgoCD managing everything from git. The
architecture is already decided and documented in `D:\NP\Server_Architecture.md`,
`ERP_SaaS_Documentation.md`, `HANDOFF.md` and `Task_Plan.md`. **Do not reopen
architecture decisions.** Your job is to make the infrastructure match the design.

## Environment

- You run in **WSL2 Ubuntu** on the user's Windows machine, as user `zied`.
- Repo: `/mnt/d/NP/erp-deploy` (which is `D:\NP\erp-deploy` in Windows).
- Toolchain installed: ansible 2.16.3, terraform 1.16.3, kubectl 1.37.0, helm 3.22.0,
  kubeseal 0.27.1.
- Two VMs, RHEL-family, 4 GB RAM each, SELinux enforcing, firewalld running.
  SSH as `root` with key `~/.ssh/id_ed25519`, already installed on both:
  - `erp-node-1` — 192.168.152.230 — k3s server, **Ready**, label `erp.devsty.io/role=data`
  - `erp-node-2` — 192.168.152.231 — agent, **not yet joined**, should get `role=apps`
- `export KUBECONFIG=/mnt/d/NP/erp-deploy/kubeconfig` — it is per-shell, set it in every
  new window.
- k3s version is pinned: `v1.31.5+k3s1`. Do not change it.

## Tasks, in order

1. **Join node-2 to the cluster.** The exact commands are in `docs/CURRENT_STATE.md` §5.
   Copy the k3s binary from node-1 over the LAN and use
   `INSTALL_K3S_SKIP_DOWNLOAD=true` — the link to GitHub runs at ~115 KB/s and the
   binary is 70 MB. Verify the sha256 matches before installing. Done when
   `kubectl get nodes -L erp.devsty.io/role` shows both nodes `Ready` with `data` and
   `apps`.

2. **Fold that into the playbook.** Change `ansible/site.yml` so the agent play fetches
   the binary from the server node when it is available, falling back to download.
   This also guarantees both nodes run identical binaries.

3. **Git remote.** Ask the user for the repository URL — do not invent one. Then
   initialise, commit and push. Afterwards update the URL in **both** places, which must
   agree: `terraform/bootstrap/terraform.tfvars` (`gitops_repo_url`) and
   `gitops/root/10-stacks.yaml` (three `repoURL:` lines). If they disagree, the root
   Application reports Healthy while its children never appear.

4. **Bootstrap.** `cd terraform/bootstrap && terraform init && terraform apply`. Show
   the user the plan and get confirmation before applying.

5. **Seal the credentials.** Follow `README.md` → "Secrets". Five SealedSecrets.
   `keycloak-db-credentials` is needed in two namespaces with the **same** password.
   Plaintext must never touch disk or git — pipe `kubectl create secret --dry-run=client`
   straight into `kubeseal`. Tell the user to record each generated password in their
   password manager, and back up the Sealed Secrets controller key.

6. **Let ArgoCD sync, staged.** Image pulls total ~1.5 GB on a slow link and will take
   hours. Bring up cert-manager and ingress-nginx first, then CNPG and the databases,
   then Keycloak. Pods in `ImagePullBackOff` on this link are usually queued, not broken —
   check `kubectl describe pod` before treating it as a failure.

7. **Verify.** Run the checks in `docs/CURRENT_STATE.md` §7. The one that matters most:
   `erp_app` must have `rolbypassrls = f`. If it is `t`, every cross-tenant isolation
   test in the application is meaningless — treat it as build-breaking.

8. **Update `docs/CURRENT_STATE.md`** as you go, so the next person inherits an accurate
   picture rather than this one.

## Rules

- **Never `curl … | sh`** from a playbook or script. Download to a file, then execute.
  `sh -s` reads the script from stdin and hangs forever if anything it runs touches
  stdin; and if curl fails, sh exits 0 and the caller sees a false success. This already
  cost 25 minutes on this build.
- **Never run two installers against the same node at once.** If an Ansible task is
  running, do not also run the equivalent command by hand.
- **Never commit secrets.** No plaintext passwords, no kubeconfig, no k3s node token, no
  `.tfvars`, no sealing key. `.gitignore` covers these — keep it that way.
- **Ask before anything destructive** — reinstalling k3s, deleting PVCs, wiping a node,
  `terraform destroy`.
- **Do not change** the k3s version, node labels, namespace names, memory limits, or the
  Postgres role model (`erp_migrator` owns, `erp_app` has DML only and no `BYPASSRLS`,
  `FORCE ROW LEVEL SECURITY` on every tenant-scoped table) without saying why and getting
  agreement. Each was chosen deliberately and the reasons are in the comments.
- When something hangs, **diagnose before retrying**: `ps` on the remote, `journalctl -u
  <service>`, `kubectl describe`. Repeating a hanging command produces two hanging
  commands.
- The user is not a native English speaker. Keep explanations plain and direct, and put
  the command to run before the explanation of it.

## Done when

- Both nodes `Ready` with correct labels.
- All ArgoCD Applications `Synced` and `Healthy`.
- `erp_app` exists with `rolbypassrls = f`; PgBouncer `pool_mode = transaction`.
- Keycloak answers over HTTPS at `keycloak.erp.lan` with a certificate from the internal CA.
- `docs/CURRENT_STATE.md` reflects reality.
