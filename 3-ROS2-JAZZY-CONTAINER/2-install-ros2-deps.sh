#!/usr/bin/env bash
# =============================================================================
# 2-install-ros2-deps.sh — Runs INSIDE the ros2-jazzy distrobox container.
# Called by 1-create-ros2-jazzy-container.sh, or re-runnable standalone.
#
# 8 phases — lightweight, no source builds:
#   1. Bootstrap tools
#   2. ROS2 Jazzy desktop-full
#   3. Container profile (prompt, NVIDIA, ROS2, colcon, PATH)
#   4. Dev tools (C++, Python, pip, colcon extensions)
#   5. Node.js via nvm (for Mason LSPs)
#   6. Neovim (latest stable) + LazyVim
#   7. rosdep init + update
#   8. Create dedicated directory + verify
#
# USAGE:
#   ./2-install-ros2-deps.sh              # full run
#   ./2-install-ros2-deps.sh --resume     # skip done phases
# =============================================================================

set -uo pipefail

RESUME=false
[[ "${1:-}" == "--resume" ]] && RESUME=true

# =============================================================================
# EDITABLE CONFIGURATION
# =============================================================================

APT_PACKAGES=(
    # Build essentials
    build-essential cmake ninja-build gcc g++ gdb valgrind
    pkg-config clang clang-tools-extra
    autoconf libtool

    # Python
    python3-pip python3-venv python3-dev

    # ROS2 development tools
    python3-colcon-common-extensions
    python3-rosdep
    python3-vcstool
    python3-argcomplete

    # ROS2 additional packages (simulation + visualization)
    ros-jazzy-rviz2
    ros-jazzy-rqt
    ros-jazzy-rqt-common-plugins
    ros-jazzy-gazebo-ros-pkgs
    ros-jazzy-joint-state-publisher
    ros-jazzy-robot-state-publisher
    ros-jazzy-xacro
    ros-jazzy-tf2-tools
    ros-jazzy-ros2bag
    ros-jazzy-rosbag2-storage-default-plugins

    # System utilities
    htop vim net-tools curl wget git
    ripgrep fd-find
    mesa-utils
)

PIP_PACKAGES=(
    setuptools
)

# Version pins
NVM_VERSION="v0.39.7"
NODE_VERSION="20"

# =============================================================================
# INTERNAL CONFIG
# =============================================================================

STATE_DIR="/opt/ros2-state"
CONTAINER_DIR="$HOME/ros2-CONTAINER"
PROFILE_FILE="/etc/profile.d/zzz-ros2-custom.sh"
LOG_FILE="/var/log/ros2-jazzy-install.log"

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
# PHASE 1: Bootstrap tools + force IPv4
# =============================================================================
if is_done "phase01"; then skip "Phase 1 (bootstrap) done"; else
    phase "PHASE 1/8 — Bootstrap tools"
    export DEBIAN_FRONTEND=noninteractive

    # Force IPv4 for apt (avoids IPv6 CDN issues in India)
    echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 > /dev/null

    sudo apt-get update || { err "apt update failed"; exit 1; }
    sudo apt-get install -y \
        software-properties-common curl gnupg2 ca-certificates \
        wget git build-essential locales \
        || { err "Bootstrap failed"; exit 1; }

    # Ensure UTF-8 locale
    sudo locale-gen en_US.UTF-8 2>/dev/null || true
    ok "Bootstrap tools installed"
    mark_done "phase01"
fi

# =============================================================================
# PHASE 2: ROS2 Jazzy (via official Ubuntu 24.04 packages)
# =============================================================================
if is_done "phase02"; then skip "Phase 2 (ROS2 Jazzy) done"; else
    phase "PHASE 2/8 — ROS2 Jazzy"

    if [[ ! -d /opt/ros/jazzy ]]; then
        # Add ROS2 apt repo
        sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
            -o /usr/share/keyrings/ros-archive-keyring.gpg \
            || { err "Failed to download ROS2 key"; exit 1; }
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
            | sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null

        sudo apt-get update || { err "apt update failed after adding ROS2 repo"; exit 1; }
        sudo apt-get install -y ros-jazzy-desktop-full \
            || { err "ROS2 Jazzy install failed"; exit 1; }
    fi

    verify /opt/ros/jazzy/setup.bash
    ok "ROS2 Jazzy installed"
    mark_done "phase02"
fi

# =============================================================================
# PHASE 3: Container profile
# CRITICAL: Never use 'set -u' in this file.
# =============================================================================
if is_done "phase03"; then skip "Phase 3 (profile) done"; else
    phase "PHASE 3/8 — Container profile"

    sudo tee "$PROFILE_FILE" > /dev/null <<'PROFILE_EOF'
# =============================================================================
# ROS2 Jazzy Distrobox — Container Profile
# Container-specific — does NOT affect host or other containers.
# =============================================================================

# Colors
export TERM=xterm-256color
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# Prompt (green container name + yellow path — distinct from ROS1's cyan)
export PS1='\[\033[01;32m\]📦 \u@\h\[\033[00m\]:\[\033[01;33m\]\w\[\033[00m\]\$ '

# NVIDIA GPU (fixes Gazebo/rviz2 Mesa fallback crash)
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
export LIBGL_ALWAYS_SOFTWARE=0

# User local binaries (for git-profile and other tools)
export PATH="$HOME/.local/bin:$PATH"

# Node.js via nvm
export NVM_DIR="$HOME/.config/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# ROS2 Jazzy
set +u
[ -f /opt/ros/jazzy/setup.bash ] && source /opt/ros/jazzy/setup.bash

# Colcon tab completion
[ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ] && \
    source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash

# ROS2 domain ID — isolate from ROS1 and other ROS2 instances
export ROS_DOMAIN_ID=42

# Colcon defaults (build in parallel, colorized output)
export COLCON_LOG_LEVEL=warning
PROFILE_EOF

    sudo chmod 644 "$PROFILE_FILE"
    ok "Profile written to $PROFILE_FILE"
    mark_done "phase03"
fi

# Source ROS2 for the rest of this script
set +u
source /opt/ros/jazzy/setup.bash 2>/dev/null || true
set -u

# =============================================================================
# PHASE 4: Dev tools + apt packages
# =============================================================================
if is_done "phase04"; then skip "Phase 4 (dev tools) done"; else
    phase "PHASE 4/8 — Dev tools + apt packages"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update || { err "apt update failed"; exit 1; }
    sudo apt-get install -y "${APT_PACKAGES[@]}" \
        || { err "Apt install failed"; exit 1; }
    pip3 install --user --break-system-packages "${PIP_PACKAGES[@]}" \
        || { err "Pip install failed"; exit 1; }
    ok "All dev tools installed"
    mark_done "phase04"
fi

# =============================================================================
# PHASE 5: Node.js via nvm (for Mason LSPs in LazyVim)
# =============================================================================
if is_done "phase05"; then skip "Phase 5 (Node.js) done"; else
    phase "PHASE 5/8 — Node.js ${NODE_VERSION} via nvm"
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
    mark_done "phase05"
fi

# =============================================================================
# PHASE 6: Neovim (latest stable) + LazyVim
# Ubuntu 24.04 ships Neovim 0.9.x which may work, but latest stable is safer.
# =============================================================================
if is_done "phase06"; then skip "Phase 6 (Neovim + LazyVim) done"; else
    phase "PHASE 6/8 — Neovim + LazyVim"

    step_label="Installing latest stable Neovim"
    info "$step_label"
    sudo apt-get remove -y neovim neovim-runtime 2>/dev/null || true

    if [[ -x /usr/local/bin/nvim ]]; then
        info "Already installed: $(/usr/local/bin/nvim --version | head -1)"
    else
        cd /tmp
        curl -LO https://github.com/neovim/neovim/releases/download/stable/nvim-linux64.tar.gz \
            || { err "Failed to download Neovim"; exit 1; }
        sudo rm -rf /opt/nvim-linux64
        sudo tar -xzf nvim-linux64.tar.gz -C /opt/ \
            || { err "Failed to extract Neovim"; exit 1; }
        sudo ln -sf /opt/nvim-linux64/bin/nvim /usr/local/bin/nvim
        rm -f nvim-linux64.tar.gz
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
        skip "Already installed"
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
    info "Mason auto-installs LSPs on first file open (clangd, pyright, etc.)"
    mark_done "phase06"
fi

# =============================================================================
# PHASE 7: rosdep init + update
# =============================================================================
if is_done "phase07"; then skip "Phase 7 (rosdep) done"; else
    phase "PHASE 7/8 — rosdep"
    if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        sudo rosdep init || warn "rosdep init may already exist"
    fi
    rosdep update || { err "rosdep update failed"; exit 1; }
    ok "rosdep ready"
    mark_done "phase07"
fi

# =============================================================================
# PHASE 8: Create dedicated directory + final verification
# =============================================================================
if is_done "phase08"; then skip "Phase 8 (directory + verify) done"; else
    phase "PHASE 8/8 — Directory setup + verification"

    mkdir -p "$CONTAINER_DIR"
    ok "Created: $CONTAINER_DIR"

    # Final verification
    info "Verifying installation..."
    PASS=true
    checks=(
        "/opt/ros/jazzy/setup.bash:ROS2 Jazzy"
        "/usr/local/bin/nvim:Neovim"
    )

    for check in "${checks[@]}"; do
        path="${check%%:*}"
        name="${check##*:}"
        if [[ -e "$path" ]]; then
            ok "$name"
        else
            err "$name MISSING ($path)"
            PASS=false
        fi
    done

    # Check Node.js
    export NVM_DIR="$HOME/.config/nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    command -v node &>/dev/null && ok "Node.js $(node --version)" || { err "Node.js MISSING"; PASS=false; }

    # Check ROS2 CLI
    set +u
    source /opt/ros/jazzy/setup.bash 2>/dev/null
    command -v ros2 &>/dev/null && ok "ros2 CLI" || { err "ros2 CLI MISSING"; PASS=false; }
    command -v colcon &>/dev/null && ok "colcon" || { err "colcon MISSING"; PASS=false; }
    set -u

    # Check SSH (multi-account aware)
    if ls "$HOME"/.ssh/id_* &>/dev/null || [[ -f "$HOME/.ssh/config" ]]; then
        ok "SSH keys/config detected"
    else
        warn "No SSH keys found — run ssh-manager.sh setup to configure GitHub accounts"
    fi

    # Check git-profile
    if [[ -x "$HOME/.local/bin/git-profile" ]]; then
        ok "git-profile command available"
    else
        warn "git-profile not found — run ssh-manager.sh setup"
    fi

    if $PASS; then
        ok "All verifications passed"
    else
        err "Some components missing — check above"
        exit 1
    fi

    mark_done "phase08"
fi

# =============================================================================
# DONE
# =============================================================================
phase "ALL 8 PHASES COMPLETE"

cat <<EOF | tee -a "$LOG_FILE"

${GREEN}${BOLD}ROS2 Jazzy development environment is ready.${NORMAL}

${BOLD}What's installed:${NORMAL}
  ✓ Ubuntu 24.04 + ROS2 Jazzy desktop-full
  ✓ C++ toolchain (gcc, cmake, gdb, valgrind, clang)
  ✓ Python 3 + pip
  ✓ Neovim (latest stable) + LazyVim
  ✓ colcon, rosdep, vcstool
  ✓ rviz2, rqt, Gazebo
  ✓ ROS_DOMAIN_ID=42 (isolated from ROS1)

${BOLD}To start developing:${NORMAL}

  exit
  distrobox enter $(hostname)
  cd ~/ros2-CONTAINER
  mkdir -p my_project_ws/src && cd my_project_ws
  ros2 pkg create --build-type ament_cmake my_package
  colcon build
  source install/setup.bash

${BOLD}Git identity:${NORMAL}
  git profile use <work|personal|showcase>
  git profile show

EOF
