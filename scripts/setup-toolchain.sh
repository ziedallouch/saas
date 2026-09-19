#!/usr/bin/env bash
#
# Installs the toolchain this repo needs, inside WSL Ubuntu.
#
#   bash /mnt/d/NP/erp-deploy/scripts/setup-toolchain.sh
#
# Safe to re-run: every step checks before installing.

set -euo pipefail

NODE1="${NODE1:-192.168.152.230}"
NODE2="${NODE2:-192.168.152.231}"

section() { printf '\n\033[36m=== %s ===\033[0m\n' "$1"; }
say()  { printf '  %s\n' "$1"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -eq 0 ]]; then
  warn "Run this as your normal user, not root. It calls sudo where needed."
  exit 1
fi

section "Repairing any half-configured packages"
# Ubuntu WSL images sometimes ship mid-upgrade: apt then refuses every install
# with "unmet dependencies" because `apt install` may not move held-back packages.
# full-upgrade resolves the whole set at once. All three are no-ops on a clean system.
sudo dpkg --configure -a
sudo apt-get --fix-broken install -y -qq
sudo apt-get update -qq
sudo apt-get full-upgrade -y -qq
say "package state consistent"

section "System packages"
sudo apt-get install -y -qq \
  curl wget unzip git jq ca-certificates gnupg lsb-release \
  software-properties-common python3-pip sshpass
say "base packages present"

section "Ansible"
if have ansible; then
  say "already installed: $(ansible --version | head -1)"
else
  sudo apt-get install -y -qq ansible
  say "installed: $(ansible --version | head -1)"
fi

section "Terraform"
if have terraform; then
  say "already installed: $(terraform version | head -1)"
else
  wget -qO- https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq terraform
  say "installed: $(terraform version | head -1)"
fi

section "kubectl"
# Direct binary, not snap: snapd does not run under WSL by default, and a snap
# install there fails in a way that reads like a network problem.
if have kubectl; then
  say "already installed: $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1 | awk '{print $2}')"
else
  KVER="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
  curl -sSLO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
  say "installed ${KVER}"
fi

section "Helm"
if have helm; then
  say "already installed: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  say "installed: $(helm version --short)"
fi

section "kubeseal"
if have kubeseal; then
  say "already installed: $(kubeseal --version)"
else
  KS_VER="0.27.1"
  curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KS_VER}/kubeseal-${KS_VER}-linux-amd64.tar.gz" \
    | tar xz kubeseal
  sudo install -m 0755 kubeseal /usr/local/bin/kubeseal
  rm -f kubeseal
  say "installed v${KS_VER}"
fi

section "Ansible collections"
ansible-galaxy collection install -r /mnt/d/NP/erp-deploy/ansible/requirements.yml >/dev/null
say "ansible.posix and community.general installed"

section "SSH key"
# The key must live in the WSL filesystem, not /mnt/d. Files on a Windows drive
# report mode 0777, and ssh refuses to use a world-readable private key.
if [[ -f ~/.ssh/id_ed25519 ]]; then
  say "key already exists at ~/.ssh/id_ed25519"
else
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "erp-deploy@wsl"
  say "generated ~/.ssh/id_ed25519"
fi

section "Network reachability"
reachable=true
for ip in "$NODE1" "$NODE2"; do
  if ping -c1 -W2 "$ip" >/dev/null 2>&1; then
    say "$ip reachable"
  else
    warn "$ip NOT reachable from WSL"
    reachable=false
  fi
done

if [[ "$reachable" == false ]]; then
  warn ""
  warn "WSL uses NAT by default and cannot always reach the LAN. Fix by creating"
  warn "C:\\Users\\<you>\\.wslconfig containing:"
  warn ""
  warn "    [wsl2]"
  warn "    networkingMode=mirrored"
  warn ""
  warn "then run 'wsl --shutdown' in PowerShell and reopen Ubuntu."
fi

section "Next steps"
cat <<EOF
  1. Copy your SSH key to both VMs (you will be asked for the root password):

       ssh-copy-id root@${NODE1}
       ssh-copy-id root@${NODE2}

  2. Validate the Terraform before anything else — no cluster needed:

       cd /mnt/d/NP/erp-deploy/terraform/bootstrap
       terraform init
       terraform validate

  3. Fix the cloned identity on node-2, then reboot it:

       cd /mnt/d/NP/erp-deploy
       cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
       ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \\
         --limit erp-node-2 -e regenerate_identity=true

  4. Then the full run. See README.md.
EOF
