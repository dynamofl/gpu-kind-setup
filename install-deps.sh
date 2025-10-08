#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
K8S_MINOR=${K8S_MINOR:-v1.34}      # change to v1.35 etc. if you want a different minor
ORAS_VERSION=${ORAS_VERSION:-1.2.0}
K8S_LIST=/etc/apt/sources.list.d/kubernetes.list
K8S_KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg

APT_PACKAGES=(
  curl
  git
  jq
  apt-transport-https
  ca-certificates
  gnupg
  lsb-release
  software-properties-common
)

# ===== Helpers =====
require_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_keyrings_dir() {
  sudo install -d -m 0755 /etc/apt/keyrings
}

clean_legacy_k8s_repos() {
  # Remove stale/legacy Kubernetes repos that cause NO_PUBKEY errors
  sudo rm -f /etc/apt/sources.list.d/kubernetes* \
             /etc/apt/sources.list.d/isv:kubernetes*.list || true
  # Remove any lines referencing the old prod-cdn host or old pkgs entries
  sudo sed -i '/prod-cdn\.packages\.k8s\.io/d;/pkgs\.k8s\.io/d' /etc/apt/sources.list || true
}

add_k8s_repo() {
  ensure_keyrings_dir
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | sudo gpg --dearmor -o "${K8S_KEYRING}"
  sudo chmod 0644 "${K8S_KEYRING}"
  echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    | sudo tee "${K8S_LIST}" >/dev/null
  sudo chmod 0644 "${K8S_LIST}"
}

append_profile_once() {
  local line="$1"
  local profile="${HOME}/.profile"
  grep -qxF "$line" "$profile" 2>/dev/null || echo "$line" >> "$profile"
}

ensure_go_path_on_path() {
  # Ensure ~/go/bin (default GOPATH bin) is on PATH for future shells
  append_profile_once 'export GOPATH="${GOPATH:-$HOME/go}"'
  append_profile_once 'export PATH="$PATH:$GOPATH/bin"'
  # Also export for current session (so subsequent steps can find go-installed tools)
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$PATH:$GOPATH/bin"
}

# ===== Start =====
echo "[deps] Cleaning legacy Kubernetes APT sources (preempt GPG errors)"
clean_legacy_k8s_repos

echo "[deps] Updating apt metadata (first pass, without k8s repo)"
sudo apt-get update -y

echo "[deps] Ensuring base APT packages"
for pkg in "${APT_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    sudo apt-get install -y "$pkg"
  fi
done

# --- Docker ---
if ! require_cmd docker; then
  echo "[deps] Installing Docker Engine (Ubuntu package)"
  sudo apt-get install -y docker.io
  sudo systemctl enable --now docker
  if ! groups "$USER" | grep -q '\bdocker\b'; then
    sudo usermod -aG docker "$USER"
    echo "[deps] Added $USER to docker group (log out/in to apply)"
  fi
else
  echo "[deps] Docker already installed"
fi

# --- AWS CLI ---
if ! require_cmd aws; then
  echo "[deps] Installing AWS CLI"
  sudo apt-get install -y awscli
else
  echo "[deps] AWS CLI already installed"
fi

# --- Go ---
if ! require_cmd go; then
  echo "[deps] Installing Go (Ubuntu package)"
  # Ubuntu 24.04 (noble) ships Go >= 1.22, sufficient for nvkind
  sudo apt-get install -y golang-go
  ensure_go_path_on_path
else
  echo "[deps] Go already installed"
  ensure_go_path_on_path
fi

# --- kubectl ---
if ! require_cmd kubectl; then
  echo "[deps] Installing kubectl from pkgs.k8s.io (${K8S_MINOR})"
  clean_legacy_k8s_repos
  sudo apt-get install -y ca-certificates curl gnupg apt-transport-https
  add_k8s_repo
  sudo apt-get update
  sudo apt-get install -y kubectl
else
  # Still fix host APT state so future updates don't break
  echo "[deps] kubectl already installed; normalizing repo/key to pkgs.k8s.io (${K8S_MINOR})"
  clean_legacy_k8s_repos
  add_k8s_repo
  sudo apt-get update
fi

# --- Helm ---
if ! require_cmd helm; then
  echo "[deps] Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "[deps] Helm already installed"
fi

# --- kind ---
if ! require_cmd kind; then
  echo "[deps] Installing kind"
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64"
  sudo install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
else
  echo "[deps] kind already installed"
fi

# --- ORAS ---
if ! require_cmd oras; then
  echo "[deps] Installing ORAS CLI (${ORAS_VERSION})"
  curl -fsSLo /tmp/oras.tar.gz "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
  tar -xzf /tmp/oras.tar.gz -C /tmp oras
  sudo install -o root -g root -m 0755 /tmp/oras /usr/local/bin/oras
else
  echo "[deps] ORAS CLI already installed"
fi

# --- nvkind ---
if ! require_cmd nvkind; then
  echo "[deps] Installing nvkind CLI"
  if ! require_cmd go; then
    echo "[deps] ERROR: go command not found after install; skipping nvkind." >&2
  else
    GOBIN="$(go env GOPATH)/bin"
    go install github.com/NVIDIA/nvkind/cmd/nvkind@latest
    sudo install -o root -g root -m 0755 "${GOBIN}/nvkind" /usr/local/bin/nvkind
  fi
else
  echo "[deps] nvkind already installed"
fi

echo "[deps] All requested dependencies are present."
echo "[deps] If this is your first time installing Docker, log out/in so your docker group change takes effect."

