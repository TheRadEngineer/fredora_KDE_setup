#!/usr/bin/env bash
# =============================================================================
# 2-install-dev-deps.sh — Runs INSIDE the dev distrobox container.
# Called by 1-create-dev-container.sh, or re-runnable standalone.
#
# 10 phases:
#   1. Bootstrap + locale + IPv4
#   2. Container profile
#   3. C++ toolchain
#   4. CUDA toolkit + cuDNN
#   5. Python + uv
#   6. Go
#   7. Rust (rustup)
#   8. Node.js via nvm
#   9. Neovim (latest stable) + LazyVim
#  10. Directory structure + final verification
#
# USAGE:
#   ./2-install-dev-deps.sh              # full run
#   ./2-install-dev-deps.sh --resume     # skip done phases
# =============================================================================

set -uo pipefail

HAS_NVIDIA="${1:-false}"
RESUME=false
[[ "${1:-}" == "--resume" ]] && RESUME=true
[[ "${2:-}" == "--resume" ]] && RESUME=true

# =============================================================================
# EDITABLE CONFIGURATION
# =============================================================================

CPP_PACKAGES=(
    build-essential gcc g++ make cmake ninja-build
    gdb valgrind
    clangd clang
    pkg-config
    autoconf libtool
    libssl-dev
)

PYTHON_PACKAGES=(
    python3 python3-pip python3-venv python3-dev
)

SYSTEM_PACKAGES=(
    curl wget git
    htop vim net-tools
    ripgrep fd-find
    unzip zip tar xz-utils
    mesa-utils
    software-properties-common
    locales
    ca-certificates gnupg2
)

PIP_PACKAGES=(
    setuptools
)

NVM_VERSION="v0.39.7"
NODE_VERSION="20"

# =============================================================================
# INTERNAL CONFIG
# =============================================================================

STATE_DIR="/opt/dev-state"
CONTAINER_DIR="$HOME/dev-CONTAINER"
PROFILE_FILE="/etc/profile.d/zzz-dev-custom.sh"
LOG_FILE="/var/log/dev-container-install.log"

# --- Colors ---
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; NORMAL=$'\e[0m'
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'
else
    BOLD=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

sudo touch "$LOG_FILE" 2>/dev/null || true
sudo chmod 666 "$LOG_FILE" 2>/dev/null || true

info()  { echo -e "${BLUE}${BOLD}[INFO]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}${BOLD}[ OK ]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}${BOLD}[WARN]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}${BOLD}[FAIL]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
skip()  { echo -e "${CYAN}${BOLD}[SKIP]${NORMAL}  $*" | tee -a "$LOG_FILE"; }

phase() {
    echo | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}=====================================================${NORMAL}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}  $*${NORMAL}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}=====================================================${NORMAL}" | tee -a "$LOG_FILE"
}

is_done()   { $RESUME && [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done() { touch "$STATE_DIR/$1.done"; }

verify() {
    if [[ -e "$1" ]]; then
        ok "Verified: $1"
    else
        err "VERIFICATION FAILED: $1 does not exist"
        exit 1
    fi
}

# --- Pre-flight ---
[[ $EUID -eq 0 ]] && { err "Don't run as root."; exit 1; }

sudo mkdir -p "$STATE_DIR"
sudo chown -R "$USER:$USER" "$STATE_DIR"

info "Container dir: $CONTAINER_DIR"
info "Log: $LOG_FILE"
$RESUME && info "Mode: RESUME"

# =============================================================================
# PHASE 1: Bootstrap + locale + IPv4
# =============================================================================
if is_done "phase01"; then skip "Phase 1 (bootstrap) done"; else
    phase "PHASE 1/10 — Bootstrap"
    export DEBIAN_FRONTEND=noninteractive

    # Force IPv4 (avoids IPv6 CDN issues)
    echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 > /dev/null

    sudo apt-get update || { err "apt update failed"; exit 1; }
    sudo apt-get install -y "${SYSTEM_PACKAGES[@]}" \
        || { err "Bootstrap failed"; exit 1; }

    # Ensure UTF-8 locale
    sudo locale-gen en_US en_US.UTF-8
    sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    export LANG=en_US.UTF-8

    ok "Bootstrap complete"
    mark_done "phase01"
fi

# =============================================================================
# PHASE 2: Container profile
# CRITICAL: Never use 'set -u' in profile content.
# =============================================================================
if is_done "phase02"; then skip "Phase 2 (profile) done"; else
    phase "PHASE 2/10 — Container profile"

    sudo tee "$PROFILE_FILE" > /dev/null <<'PROFILE_EOF'
# =============================================================================
# Dev Container — Container Profile
# Container-specific — does NOT affect host or other containers.
# =============================================================================

# Colors
export TERM=xterm-256color
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# Prompt (magenta container name + cyan path — distinct from ROS containers)
export PS1='\[\033[01;35m\]📦 \u@\h\[\033[00m\]:\[\033[01;36m\]\w\[\033[00m\]\$ '

# NVIDIA GPU (only set if NVIDIA is available)
if command -v nvidia-smi &>/dev/null 2>&1; then
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    export LIBGL_ALWAYS_SOFTWARE=0
fi

# User local binaries (for git-profile, uv, and other tools)
export PATH="$HOME/.local/bin:$PATH"

# Node.js via nvm
export NVM_DIR="$HOME/.config/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Go
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin:/usr/local/go/bin"

# Rust
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# CUDA
if [ -d /usr/local/cuda ]; then
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi
PROFILE_EOF

    sudo chmod 644 "$PROFILE_FILE"
    ok "Profile written to $PROFILE_FILE"
    mark_done "phase02"
fi

# =============================================================================
# PHASE 3: C++ toolchain
# =============================================================================
if is_done "phase03"; then skip "Phase 3 (C++) done"; else
    phase "PHASE 3/10 — C++ toolchain"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update || { err "apt update failed"; exit 1; }
    sudo apt-get install -y "${CPP_PACKAGES[@]}" \
        || { err "C++ toolchain install failed"; exit 1; }

    # Verify
    command -v gcc &>/dev/null && ok "gcc $(gcc --version | head -1)" || err "gcc missing"
    command -v cmake &>/dev/null && ok "cmake $(cmake --version | head -1)" || err "cmake missing"
    command -v gdb &>/dev/null && ok "gdb found" || err "gdb missing"
    command -v clangd &>/dev/null && ok "clangd found" || warn "clangd missing (Mason will provide fallback)"

    mark_done "phase03"
fi

# =============================================================================
# PHASE 4: CUDA toolkit + cuDNN
# =============================================================================
if is_done "phase04"; then skip "Phase 4 (CUDA) done"; else
    phase "PHASE 4/10 — CUDA toolkit + cuDNN"

    if [[ "$HAS_NVIDIA" != "true" ]]; then
        warn "No NVIDIA GPU — skipping CUDA installation"
        mark_done "phase04"
    else
        if command -v nvcc &>/dev/null; then
            info "CUDA already installed: $(nvcc --version | grep release)"
        else
            # Add NVIDIA CUDA repo for Ubuntu 24.04
            info "Adding NVIDIA CUDA repository..."
            CUDA_KEYRING="cuda-keyring_1.1-1_all.deb"
            curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/${CUDA_KEYRING}" \
                -o "/tmp/${CUDA_KEYRING}" \
                || { err "Failed to download CUDA keyring"; exit 1; }
            sudo dpkg -i "/tmp/${CUDA_KEYRING}" \
                || { err "Failed to install CUDA keyring"; exit 1; }
            rm -f "/tmp/${CUDA_KEYRING}"

            sudo apt-get update || { err "apt update failed after CUDA repo"; exit 1; }

            info "Installing CUDA toolkit (this may take a few minutes)..."
            sudo apt-get install -y cuda-toolkit \
                || { err "CUDA toolkit install failed"; exit 1; }

            info "Installing cuDNN..."
            sudo apt-get install -y libcudnn9-cuda-12 libcudnn9-dev-cuda-12 \
                || warn "cuDNN install failed — may need manual install"
        fi

        # Verify
        export PATH="/usr/local/cuda/bin:$PATH"
        if command -v nvcc &>/dev/null; then
            ok "CUDA: $(nvcc --version | grep release)"
        else
            warn "nvcc not on PATH — check /usr/local/cuda/bin"
        fi
    fi

    mark_done "phase04"
fi

# =============================================================================
# PHASE 5: Python + uv
# =============================================================================
if is_done "phase05"; then skip "Phase 5 (Python) done"; else
    phase "PHASE 5/10 — Python + uv"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get install -y "${PYTHON_PACKAGES[@]}" \
        || { err "Python install failed"; exit 1; }
    pip3 install --user --break-system-packages "${PIP_PACKAGES[@]}" \
        || warn "pip install partial failure"

    # Install uv (modern Python package manager)
    if command -v uv &>/dev/null || [[ -x "$HOME/.local/bin/uv" ]]; then
        info "uv already installed"
    else
        curl -LsSf https://astral.sh/uv/install.sh | sh \
            || { err "uv install failed"; exit 1; }
    fi

    ok "Python $(python3 --version) + pip + uv"
    mark_done "phase05"
fi

# =============================================================================
# PHASE 6: Go
# =============================================================================
if is_done "phase06"; then skip "Phase 6 (Go) done"; else
    phase "PHASE 6/10 — Go"

    if command -v go &>/dev/null; then
        info "Go already installed: $(go version)"
    else
        sudo apt-get install -y golang \
            || { err "Go install failed"; exit 1; }
    fi

    export GOPATH="$HOME/go"
    export PATH="$PATH:$GOPATH/bin:/usr/local/go/bin"
    mkdir -p "$GOPATH/bin"
    ok "Go $(go version)"
    mark_done "phase06"
fi

# =============================================================================
# PHASE 7: Rust (via rustup)
# =============================================================================
if is_done "phase07"; then skip "Phase 7 (Rust) done"; else
    phase "PHASE 7/10 — Rust"

    if command -v rustup &>/dev/null || [[ -x "$HOME/.cargo/bin/rustup" ]]; then
        info "Rust already installed"
        [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
    else
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable \
            || { err "Rust install failed"; exit 1; }
        source "$HOME/.cargo/env"
    fi

    # Install rust-analyzer (LSP)
    rustup component add rust-analyzer 2>/dev/null || warn "rust-analyzer component not available"

    ok "Rust $(rustc --version)"
    mark_done "phase07"
fi

# =============================================================================
# PHASE 8: Node.js via nvm
# =============================================================================
if is_done "phase08"; then skip "Phase 8 (Node.js) done"; else
    phase "PHASE 8/10 — Node.js ${NODE_VERSION} via nvm"
    export NVM_DIR="$HOME/.config/nvm"
    if [[ ! -d "$NVM_DIR" ]]; then
        PROFILE=/dev/null bash -c \
            "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash" \
            || { err "nvm install failed"; exit 1; }
    fi
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION" || { err "Node install failed"; exit 1; }
    nvm alias default "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    ok "Node $(node --version) + npm $(npm --version)"
    mark_done "phase08"
fi

# =============================================================================
# PHASE 9: Neovim (latest stable) + LazyVim
# =============================================================================
if is_done "phase09"; then skip "Phase 9 (Neovim + LazyVim) done"; else
    phase "PHASE 9/10 — Neovim + LazyVim"

    info "Removing old Neovim (if any)"
    sudo apt-get remove -y neovim neovim-runtime 2>/dev/null || true

    info "Installing latest stable Neovim"
    if [[ -x /usr/local/bin/nvim ]]; then
        info "Already installed: $(/usr/local/bin/nvim --version | head -1)"
    else
        cd /tmp
        curl -LO https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz \
            || { err "Failed to download Neovim"; exit 1; }
        sudo rm -rf /opt/nvim-linux-x86_64
        sudo tar -xzf nvim-linux-x86_64.tar.gz -C /opt/ \
            || { err "Failed to extract Neovim"; exit 1; }
        sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
        rm -f nvim-linux-x86_64.tar.gz
        ok "Neovim $(/usr/local/bin/nvim --version | head -1)"
    fi

    info "Installing LazyVim dependencies"
    sudo apt-get install -y ripgrep fd-find 2>/dev/null || true
    if ! command -v lazygit &>/dev/null; then
        LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*' 2>/dev/null || echo "")
        if [[ -n "$LAZYGIT_VERSION" ]]; then
            curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
                && sudo tar -xzf /tmp/lazygit.tar.gz -C /usr/local/bin lazygit \
                && rm -f /tmp/lazygit.tar.gz \
                && ok "lazygit installed" || warn "lazygit install failed (optional)"
        fi
    fi

    info "Installing LazyVim starter config"
    if [[ -f "$HOME/.config/nvim/.lazyvim-installed" ]]; then
        skip "Already installed (shared from another container)"
    else
        [[ -d "$HOME/.config/nvim" ]] && \
            mv "$HOME/.config/nvim" "$HOME/.config/nvim.backup.$(date +%Y%m%d-%H%M%S)"
        git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" \
            || { err "LazyVim clone failed"; exit 1; }
        rm -rf "$HOME/.config/nvim/.git"
        touch "$HOME/.config/nvim/.lazyvim-installed"
        ok "LazyVim installed"
    fi

    info "First 'nvim' launch will auto-install plugins (~30s)"
    info "Mason auto-installs LSPs on first file open (clangd, pyright, rust-analyzer, gopls, etc.)"
    mark_done "phase09"
fi

# =============================================================================
# PHASE 10: Directory structure + final verification
# =============================================================================
if is_done "phase10"; then skip "Phase 10 (directories + verify) done"; else
    phase "PHASE 10/10 — Directory structure + verification"

    # Create project directories
    for dir in cpp python go rust cuda playground; do
        mkdir -p "$CONTAINER_DIR/$dir"
    done
    ok "Created: $CONTAINER_DIR/{cpp,python,go,rust,cuda,playground}"

    # Final verification
    info "Verifying installation..."
    PASS=true

    # C++
    command -v gcc &>/dev/null && ok "gcc" || { err "gcc MISSING"; PASS=false; }
    command -v cmake &>/dev/null && ok "cmake" || { err "cmake MISSING"; PASS=false; }
    command -v gdb &>/dev/null && ok "gdb" || { err "gdb MISSING"; PASS=false; }

    # CUDA
    export PATH="/usr/local/cuda/bin:$PATH"
    command -v nvcc &>/dev/null && ok "CUDA (nvcc)" || { warn "nvcc not found — check CUDA install"; }

    # Python
    command -v python3 &>/dev/null && ok "Python $(python3 --version 2>&1 | awk '{print $2}')" || { err "Python MISSING"; PASS=false; }
    command -v uv &>/dev/null || [[ -x "$HOME/.local/bin/uv" ]] && ok "uv" || warn "uv not found"

    # Go
    command -v go &>/dev/null && ok "Go $(go version 2>&1 | awk '{print $3}')" || { err "Go MISSING"; PASS=false; }

    # Rust
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
    command -v rustc &>/dev/null && ok "Rust $(rustc --version 2>&1 | awk '{print $2}')" || { err "Rust MISSING"; PASS=false; }
    command -v cargo &>/dev/null && ok "cargo" || { err "cargo MISSING"; PASS=false; }

    # Node.js
    export NVM_DIR="$HOME/.config/nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    command -v node &>/dev/null && ok "Node $(node --version)" || { err "Node MISSING"; PASS=false; }

    # Neovim
    [[ -x /usr/local/bin/nvim ]] && ok "Neovim" || { err "Neovim MISSING"; PASS=false; }

    # SSH (multi-account aware)
    if ls "$HOME"/.ssh/id_* &>/dev/null || [[ -f "$HOME/.ssh/config" ]]; then
        ok "SSH keys/config detected"
    else
        warn "No SSH keys — run ssh-manager.sh setup to configure GitHub accounts"
    fi

    # git-profile
    [[ -x "$HOME/.local/bin/git-profile" ]] && ok "git-profile" || warn "git-profile not found — run ssh-manager.sh setup"

    if $PASS; then
        ok "All verifications passed"
    else
        err "Some components missing — check above"
        exit 1
    fi

    mark_done "phase10"
fi

# =============================================================================
# DONE
# =============================================================================
phase "ALL 10 PHASES COMPLETE"

cat <<EOF | tee -a "$LOG_FILE"

${GREEN}${BOLD}Dev container is ready.${NORMAL}

${BOLD}Languages:${NORMAL}
  ✓ C/C++ (gcc, cmake, gdb, valgrind, clangd)
  ✓ CUDA (nvcc, cuda toolkit, cuDNN)
  ✓ Python (python3, pip, uv)
  ✓ Go (golang)
  ✓ Rust (rustc, cargo, rust-analyzer)
  ✓ Node.js ${NODE_VERSION}
  ✓ Neovim + LazyVim (Mason auto-installs LSPs)

${BOLD}Project directories:${NORMAL}
  $CONTAINER_DIR/cpp/
  $CONTAINER_DIR/python/
  $CONTAINER_DIR/go/
  $CONTAINER_DIR/rust/
  $CONTAINER_DIR/cuda/
  $CONTAINER_DIR/playground/

${BOLD}Quick start:${NORMAL}

  exit
  distrobox enter $(hostname)
  cd ~/dev-CONTAINER/rust
  cargo init my_project && cd my_project
  nvim src/main.rs
  cargo run

${BOLD}Git identity:${NORMAL}
  git profile use <work|personal|showcase>

EOF
