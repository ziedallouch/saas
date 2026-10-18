# ERP SaaS — Cluster Build: Current State

**Updated:** 2026-10-18 (bootstrap applied; one change still pending, see §4)
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
- [x] **Git remote** — `git@github.com:ziedallouch/saas.git`, pushed, URL consistent in
      `terraform.tfvars` and `gitops/root/10-stacks.yaml`. Pushes go over **SSH from WSL**
      (`~/.ssh/id_ed25519_github`); Windows git cannot push, see §8
- [x] **`terraform apply` succeeded** — 4 namespaces, Sealed Secrets 2.16.2 (pod Running),
      ArgoCD 7.7.11 (4 components on node-2), `argoproj.io` CRDs, root Application created
- [x] Three upstream/bootstrap defects found and fixed in code (§8), committed as `e655b4e`
- [x] `CLAUDE.md` added at the repo root

## 4. Not done

- [ ] **`applicationSet.replicas = 0` is committed but never applied.** The apply was cut
      off by a VPN drop mid-`helm upgrade`. **Before retrying, check
      `helm -n argocd status argocd`** — a release interrupted during upgrade can sit in
      `pending-upgrade`, which makes every later apply fail with a misleading message and
      needs a `helm rollback` to clear. Until this lands, the ApplicationSet controller
      runs with **no requests and no limits** on node-2
- [ ] Root Application last seen `SYNC STATUS: Unknown` — `argocd-repo-server` was still
      `0/1` and had not cloned the repo yet. Unconfirmed since
- [ ] Credentials sealed and committed (5 SealedSecrets, `README.md` → "Secrets")
- [ ] ArgoCD sync: cert-manager, ingress-nginx, CNPG, Postgres ×2, Redis, Keycloak —
      **none of these has ever been deployed**
- [ ] Private CA distributed, hosts entries added
- [ ] Verification checks (§7) — **never run.** `erp_app` does not exist yet, so the
      `rolbypassrls` check is a design target, not an observed fact

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

## 5a. Immediate next step — finish the interrupted apply

The VPN must be up first; `Ethernet 3` reading `Disconnected` is why the cluster is
unreachable, not a cluster fault.

```bash
helm -n argocd status argocd        # FIRST. If it says pending-upgrade, stop and read §4.
cd terraform/bootstrap && terraform plan -out=/tmp/bs.tfplan && terraform apply /tmp/bs.tfplan
kubectl -n argocd get deploy argocd-applicationset-controller   # expect 0/0
kubectl -n argocd get app                                       # root should reach Synced
```

---

## 6. Remaining sequence after that

1. **Seal the credentials** — procedure in `README.md`, "Secrets". Five SealedSecrets;
   `keycloak-db-credentials` is needed in **two** namespaces with the **same** password.
   Record each generated password in a password manager as you go: it cannot be read back
   out of a SealedSecret. Back up the Sealed Secrets controller key; it cannot be rebuilt
   from git.
2. **Let ArgoCD sync, staged.** ~1.5 GB of image pulls on a slow link. Bring up
   cert-manager and ingress-nginx first, then CNPG and the databases, then Keycloak.
3. **Distribute the CA** and add hosts entries for `argocd`/`keycloak`/`api.erp.lan`.
4. **Run the §7 checks**, `erp_app` → `rolbypassrls = f` above all.

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

**A pinned version does not pin the source.** The Sealed Secrets chart repo
`bitnami-labs.github.io/sealed-secrets` now 404s on `index.yaml` — the project moved to
`bitnami/sealed-secrets`, and Helm reports it as "not a valid chart repository or cannot
be reached". Same chart and same pinned 2.16.2 at `https://bitnami.github.io/sealed-secrets`.

**A Helm value that does not exist is accepted in silence.** `applicationSet.enabled` has
no meaning in argo-cd chart 7.7.11; `helm template --set applicationSet.enabled=false`
renders the controller exactly as `=true` does. `dex.enabled` and `notifications.enabled`
are real, which is what made the difference invisible — those two pods were correctly
absent while the ApplicationSet controller ran with **no requests and no limits at all**.
`replicas = 0` is the supported way off. When a component you disabled is still running,
check the key exists before assuming the cluster is wrong.

**The root Application cannot ship inside the argo-cd release.** Helm resolves the kind of
every rendered manifest *before* applying any of them, and this chart keeps its
`argoproj.io` CRDs under `templates/`, not `crds/`. So `Application` is an unknown kind at
mapping time, the entire release is rejected, **nothing is applied, and retrying never
helps** — the CRDs the retry needs are in the release that keeps failing. It is now a
second tiny release, `terraform/bootstrap/charts/root-app`. Do not merge it back in.
`kubernetes_manifest` does not work either: it dry-runs at *plan* time.

**`helm_release` holds one connection open for the whole install when `wait = true`.**
ArgoCD is ~816 MB of images here, and the apply died with `http2: client connection lost`.
`wait = false` submits the manifests and returns, so the pulling happens inside the
cluster where the workstation's VPN is irrelevant. The cost is that Terraform no longer
confirms ArgoCD is healthy — check it separately with `kubectl rollout status`.

**Identical failures are not network failures.** Five applies failed at the same step,
after the same ~40 seconds, with the same message. That consistency ruled the VPN out and
pointed at a deterministic cause. The opposite shape — `dial tcp … i/o timeout`, failing
everywhere at once — is the VPN. A hypothesis worth testing cheaply: a 266 KB POST with
`--dry-run=server` creates nothing and proves whether large writes survive the tunnel.
Here they did, which refuted the HTTP/2 and MTU theories.

**Push from WSL, not from Windows.** The GitHub SSH key lives in WSL
(`~/.ssh/id_ed25519_github`). Windows git fails with `Host key verification failed`, and
over HTTPS it fails differently again: Git Credential Manager cannot prompt from a
non-interactive shell (`/dev/tty: No such device`). Note also that
`http.sslVerify=false` is set in the workstation's global `.gitconfig`, so every git
HTTPS connection on that machine is unverified — a VPN TLS-interception workaround worth
replacing with a proper CA.

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

ArgoCD runs without dex and notifications. The ApplicationSet controller is switched off
with `replicas = 0`, **not** with an `enabled` flag — that flag does not exist in chart
7.7.11 (§8). Re-enabling any of the three costs 150–250 MB that node-2 does not have spare.

Measured on node-2 with ArgoCD running and nothing else deployed yet: **608 Mi requests,
1216 Mi limits** out of 3693 Mi allocatable. The ArgoCD limits above (816 MB) understate
what the chart actually sets — the four components come to 1216 Mi. Everything still to
be placed on node-2 (Keycloak, ingress-nginx, cert-manager, cnpg, pgbouncer) has to fit
in what is left, so verify before adding anything unsized.
