# ERP SaaS — Cluster Build: Current State

**Updated:** 2026-09-19 (node-2 joined)
**Purpose:** where the non-production cluster build stands, what remains, and the
things already learned the hard way. Read `AGENT_PROMPT.md` next if you are handing
this to someone (or something) else to continue.

---

## 1. The goal

Stand up a **non-production** two-node k3s cluster to run the ERP SaaS vertical slice:
Postgres with Row-Level Security, Redis, Keycloak, and ArgoCD managing all of it from git.

> This cluster is explicitly **not** production and must not become production. One
> control-plane node means no etcd quorum; node-local storage means a dead node is a
> dead database. Both are fine for dev and staging, and unacceptable for client data.

The architecture it serves is fixed and documented — see `Server_Architecture.md`,
`ERP_SaaS_Documentation.md`, `HANDOFF.md`, `Task_Plan.md` in `D:\NP`. Do not re-open
those decisions while building infrastructure.

---

## 2. Environment

### Workstation

| | |
|---|---|
| Host | Windows, `Ahmed-WEB-PC2` |
| Shell | WSL2 Ubuntu 24.04, user `zied` |
| Repo | `D:\NP\erp-deploy` = `/mnt/d/NP/erp-deploy` in WSL |
| Toolchain | ansible 2.16.3, terraform 1.16.3, kubectl 1.37.0, helm 3.22.0, kubeseal 0.27.1 |
| SSH key | `~/.ssh/id_ed25519` (inside WSL, **not** on `/mnt/d`), installed on both VMs |
| kubeconfig | `/mnt/d/NP/erp-deploy/kubeconfig`, context `erp-nonprod` |

WSL was originally **WSL1**, which broke `systemd` package configuration with
`Failed to take /etc/passwd lock: Invalid argument`. Converted to WSL2. Do not go back.

### VMs

Both RHEL-family, cloned from one template, reachable over SSH as `root` with key auth.

| Node | IP | Role | k3s | Label | Status |
|---|---|---|---|---|---|
| `erp-node-1` | 192.168.152.230 | server | v1.31.5+k3s1 | `erp.devsty.io/role=data` | **Ready** |
| `erp-node-2` | 192.168.152.231 | agent | v1.31.5+k3s1 | `erp.devsty.io/role=apps` | **Ready** |

- RAM: 4 GB each (reports 3606 MB). Was 1.7 GB, resized — the stack does not fit in 1.7 GB.
- SELinux: **enforcing** on both.
- firewalld: **running**, configured by the playbook (6443/tcp, 10250/tcp, 8472/udp,
  80/tcp, 443/tcp; pod and service CIDRs trusted).
- Swap: disabled.
- **The VMs are remote, reached over a FortiClient SSL VPN.** `192.168.152.0/24` exists
  only while that tunnel is up. Two things to know:
  - It is a **full tunnel** — FortiClient installs a default route `0.0.0.0/0` via
    `172.16.18.104` on the `Ethernet 3` adapter, so *all* traffic rides the VPN and
    everything stalls together when it dips.
  - The adapter reporting `Up` does **not** mean traffic flows. During this build it
    read `Up` through a stretch where 16 consecutive SSH probes to both nodes failed.
    Test with an actual connection, not with the adapter status.
  - WSL2 reaches the tunnel fine in its default NAT mode. No `.wslconfig` exists on
    this workstation and none is needed; the `networkingMode=mirrored` note in earlier
    revisions of this document was wrong.

---

## 3. Done

- [x] WSL2 + full toolchain (`scripts/setup-wsl.ps1`, `scripts/setup-toolchain.sh`)
- [x] SSH key auth from WSL to both VMs
- [x] Cloned-VM identity fixed — distinct hostnames, machine-ids, SSH host keys
- [x] Ansible prep play on both nodes: packages, swap off, kernel modules, sysctl, firewalld
- [x] k3s **server** installed and healthy on node-1, labelled `role=data`
- [x] `kubeconfig` written to the repo root
- [x] `terraform init` + `terraform validate` pass on `terraform/bootstrap`
- [x] **node-2 joined** as an agent, labelled `role=apps` — both nodes `Ready`
- [x] `k3s-selinux` installed on node-2 to match node-1 (see §8, it is not automatic)
- [x] Agent play in `ansible/site.yml` rewritten: copies the binary from node-1 with a
      sha256 assert, `INSTALL_K3S_SKIP_DOWNLOAD=true`, no `curl … | sh`

## 4. Not done

- [ ] **Git remote created, repo pushed, repo URL updated in the three places below** —
      this is the immediate blocker, and it needs a URL from the operator
- [ ] `terraform apply` in `terraform/bootstrap` (ArgoCD + Sealed Secrets + root Application)
- [ ] Credentials sealed and committed
- [ ] ArgoCD sync: cert-manager, ingress-nginx, CNPG, Postgres ×2, Redis, Keycloak
- [ ] Private CA distributed, hosts entries added
- [ ] Verification checks (§7)

---

## 5. How node-2 was joined

Kept for the next rebuild. node-1 already had a verified binary, and the link to GitHub
from these VMs runs at ~115 KB/s, so the 70 MB download was skipped entirely:

```bash
# Binary copied across the LAN, then both checksums compared before installing.
# Both nodes: 399b87b432ce55013fa81adad572a8e4ecf56e0df97369cf02d4b8a41f039091

# The token goes into a 0600 file rather than onto the command line, so it never
# appears in `ps` on node-2.
ssh root@192.168.152.230 'cat /var/lib/rancher/k3s/server/node-token' \
  | ssh root@192.168.152.231 'install -m 600 /dev/stdin /root/.k3s-token'

# Run detached, so a VPN drop cannot abort the install half-way.
ssh root@192.168.152.231 'setsid nohup /root/k3s-join.sh > /root/k3s-join.log 2>&1 </dev/null &'
```

where `/root/k3s-join.sh` sets `INSTALL_K3S_SKIP_DOWNLOAD=true`,
`K3S_URL=https://192.168.152.230:6443`, `K3S_TOKEN="$(cat /root/.k3s-token)"` and
`INSTALL_K3S_EXEC='agent --node-name erp-node-2 --node-label erp.devsty.io/role=apps'`,
then runs `/root/k3s-install.sh`.

`ansible/site.yml` now does the same thing, so a rebuild from the playbook takes this
path automatically and both nodes are guaranteed byte-identical.

---

## 5a. Immediate next step — the git remote

Everything after this point needs a repository URL, and it must be reachable **from
inside the VMs**, because ArgoCD clones it from the cluster and not from the workstation.
Do not invent one; ask. Then update it in both places, which must agree:

- `terraform/bootstrap/terraform.tfvars` → `gitops_repo_url`
- `gitops/root/10-stacks.yaml` → three `repoURL:` lines

If they disagree the root Application reports Healthy while its children never appear.

---

## 6. Remaining sequence after that

1. **Git remote.** Create an empty repo, then push `erp-deploy`. ArgoCD clones it from
   *inside* the cluster, so it must be reachable from the VMs.
2. **Update the repo URL in three places** — they must agree, or the root Application
   goes Healthy while its children never appear:
   - `terraform/bootstrap/terraform.tfvars` → `gitops_repo_url`
   - `gitops/root/10-stacks.yaml` → three `repoURL:` lines
3. **`terraform apply`** in `terraform/bootstrap`. Installs Sealed Secrets and ArgoCD,
   and ships the root Application through the chart's `extraObjects`.
4. **Seal the credentials** — procedure in `README.md`, "Secrets". Five SealedSecrets;
   `keycloak-db-credentials` is needed in **two** namespaces with the **same** password.
   Back up the Sealed Secrets controller key; it cannot be rebuilt from git.
5. **Let ArgoCD sync.** Expect this to be slow (§8).
6. **Distribute the CA** and add hosts entries for `argocd`/`keycloak`/`api.erp.lan`.

---

## 7. Verification

```bash
# Both roles present
kubectl get nodes -L erp.devsty.io/role

# The check that matters most: erp_app must NOT bypass RLS
kubectl -n erp-data exec -it erp-postgres-1 -- psql -U postgres -d erp -c \
  "SELECT rolname, rolbypassrls, rolsuper FROM pg_roles WHERE rolname LIKE 'erp%';"
#   erp_migrator | f | f
#   erp_app      | f | f

# PgBouncer must be in transaction mode — this is why SET LOCAL is mandatory in the app
kubectl -n erp-data exec -it deploy/erp-postgres-pooler-rw -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "SHOW CONFIG;" | grep pool_mode

# Keycloak over TLS
curl -k https://keycloak.erp.lan/realms/master/.well-known/openid-configuration
```

If `erp_app` ever returns `rolbypassrls = t`, every cross-tenant isolation test in the
codebase is meaningless. Treat it as a build-breaking failure.

---

## 8. Things already learned the hard way

**Never `curl … | sh -s -` from automation.** `sh -s` reads the script from stdin, so
stdin *is* the script; anything the script runs that touches stdin parks the shell on a
read that never returns — no child process, no CPU, no progress, indefinitely. This cost
~25 minutes of debugging. And if `curl` fails, `sh` gets empty input and exits 0, so the
caller sees success on an install that never happened. The playbook now does `get_url`
then `command` with settings passed as environment variables.

**Never run two installers on the same node at once.** A duplicate manual run alongside
the Ansible task left two `curl` processes racing to write `/usr/local/bin/k3s`. Both
had to be killed.

**The link to GitHub is slow (~115 KB/s).** Copy the k3s binary between nodes rather than
downloading twice. Expect container image pulls (~1.5 GB total) to take hours, and stage
the ArgoCD sync rather than letting everything pull at once — otherwise large pulls
compete and pods sit in `ImagePullBackOff` looking like failures when they are just queued.

**`KUBECONFIG` is per-shell.** `kubectl` failing with `localhost:8080 connection refused`
means the variable is not set in that window, not that the cluster is down.

**Files on `/mnt/d` report mode 0777.** SSH refuses world-readable private keys, and
`kubectl` warns about the kubeconfig. Keep keys and `~/.kube/config` inside WSL.

**On RHEL:** the package is `nfs-utils`; firewalld silently kills cross-node pod traffic
if `8472/udp` is closed (nodes join, pods start, traffic vanishes — reads as an
application bug); SELinux enforcing needs `k3s-selinux` from `rpm.rancher.io`.

**`INSTALL_K3S_SKIP_DOWNLOAD=true` also skips the SELinux RPM.** The two are the same
switch inside the k3s installer: skipping the download skips `k3s-selinux` as well, and
it says so in one quiet line — `[INFO] Skipping installation of SELinux RPM`. Node-2
joined and went `Ready` without the policy, under SELinux **enforcing**, with no AVC
denials only because nothing was scheduled on it yet. node-2 is the `apps` node, so
ArgoCD, Keycloak, ingress-nginx and cert-manager all land there, and the denials would
have arrived later looking like unrelated container failures. `ansible/site.yml` now
installs `k3s-selinux` explicitly in the prep play (`k3s_selinux_rpm`), pinned to the
same 1.6-1.el9 that node-1 runs. Check with `rpm -q k3s-selinux` on **both** nodes.

**Check a command's exit status, especially over a flaky link.** A join step printed
"detached install started" while the SSH that was supposed to start it had actually
timed out — the script had no `||` guard on that last call. What gave it away was
`/root/k3s-join.sh` still being mode `0644`: the `chmod 700` in the same command had
never run. Before retrying anything remote, look at what the previous attempt really
left behind (`ls -l`, the log file, `systemctl is-active`), because a half-finished
step and a not-started step need different handling.

**Guard patterns can match themselves.** `pgrep -f "k3s-install.sh"` matched the very
`bash -c` that carried the pattern, so the "is an installer already running?" check
reported yes on an idle node. Write it as `[k]3s-install\.sh` — the running command
line then contains `[k]3s-install.sh`, which that regex does not match.

---

## 9. Memory budget

~3.6 GB usable per node. Requests are what Kubernetes schedules on; the sum of *limits*
on node-2 deliberately exceeds capacity.

| node-1 (data) | limit | node-2 (apps) | limit |
|---|---|---|---|
| k3s server | ~600 MB | k3s agent | ~350 MB |
| erp-postgres | 1024 MB | ArgoCD (4 components) | 816 MB |
| keycloak-postgres | 384 MB | Keycloak | 1280 MB |
| redis | 256 MB | ingress-nginx | 256 MB |
| | | cert-manager ×3 | 384 MB |
| | | cnpg-operator | 192 MB |
| | | pgbouncer | 256 MB |

Keycloak's heap is capped explicitly at 768 MB. Do not remove that and let
`MaxRAMPercentage` decide — its container default sizes the heap alone to ~70% of the
limit, then metaspace and thread stacks push the process over it, and it surfaces as an
OOMKill with no heap error in the logs.

ArgoCD runs without dex, notifications and applicationset. Re-enabling any of them costs
150–250 MB that node-2 does not have spare.
