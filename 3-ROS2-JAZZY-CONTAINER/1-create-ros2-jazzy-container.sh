#!/usr/bin/env bash
# =============================================================================
# 1-create-ros2-jazzy-container.sh — MAIN ORCHESTRATOR
# Run on your Fedora host.
#
# Architecture:
#   Shared home:     ~/  (host ↔ container, same as ROS1 that works)
#   Container-only:  /opt/ros, /etc/profile.d
#   Dedicated dir:   ~/ros2-CONTAINER/  (created if not exists)
#   Host ~/.bashrc:  PROTECTED — cleaned after install
#
# REQUIRED FILES (same directory):
#   - 2-install-ros2-deps.sh
#
# USAGE:
#   ./1-create-ros2-jazzy-container.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_SCRIPT="$SCRIPT_DIR/2-install-ros2-deps.sh"

# --- Colors ---
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; NORMAL=$'\e[0m'
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'
else
    BOLD=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

info()  { echo -e "${BLUE}${BOLD}[INFO]${NORMAL}  $*"; }
ok()    { echo -e "${GREEN}${BOLD}[ OK ]${NORMAL}  $*"; }
warn()  { echo -e "${YELLOW}${BOLD}[WARN]${NORMAL}  $*"; }
err()   { echo -e "${RED}${BOLD}[FAIL]${NORMAL}  $*"; }

banner() {
    echo
    echo -e "${BOLD}${BLUE}================================================================${NORMAL}"
    echo -e "${BOLD}${BLUE}  $1${NORMAL}"
    echo -e "${BOLD}${BLUE}================================================================${NORMAL}"
    echo
}

# =============================================================================
# PRE-FLIGHT
# =============================================================================
banner "ROS2 JAZZY CONTAINER BOOTSTRAP"

command -v distrobox &>/dev/null || { err "distrobox not found. Run 1-host-setup.sh first."; exit 1; }
ok "distrobox: $(distrobox --version | head -1)"

command -v nvidia-smi &>/dev/null || { err "nvidia-smi not found. Run 1-host-setup.sh first."; exit 1; }
nvidia-smi &>/dev/null || { err "nvidia-smi failed."; exit 1; }
ok "NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

[[ -f "$DEPS_SCRIPT" ]] || { err "Missing: $DEPS_SCRIPT"; exit 1; }
ok "Required files found"

# Save host ~/.bashrc
BASHRC_BACKUP="$HOME/.bashrc.pre-ros2-container.bak"
cp "$HOME/.bashrc" "$BASHRC_BACKUP"
ok "Host ~/.bashrc backed up to $BASHRC_BACKUP"

# =============================================================================
# USER INPUT
# =============================================================================
banner "CONFIGURATION"

DEFAULT_CONTAINER="ros2-jazzy"
read -r -p "Container name [$DEFAULT_CONTAINER]: " CONTAINER_NAME
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER}"
ok "Container: $CONTAINER_NAME"

CONTAINER_DIR="$HOME/ros2-CONTAINER"
info "Dedicated directory: $CONTAINER_DIR"

# Check existing container
if distrobox list 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
    warn "Container '$CONTAINER_NAME' already exists."
    read -r -p "Delete it and start fresh? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        distrobox rm --force "$CONTAINER_NAME" 2>/dev/null || true
        ok "Removed"
    else
        err "Choose a different name or delete manually."; exit 1
    fi
fi

# =============================================================================
# STEP 1/4 — CREATE CONTAINER
# =============================================================================
banner "STEP 1/4 — CREATE CONTAINER"

if ! distrobox create \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --image ubuntu:24.04 \
    --nvidia \
    --yes; then
    err "Container creation failed."
    exit 1
fi
ok "Container created"

# =============================================================================
# STEP 2/4 — FIRST-TIME ENTRY
# =============================================================================
banner "STEP 2/4 — FIRST-TIME ENTRY"

if ! distrobox enter "$CONTAINER_NAME" -- bash -c "echo 'Distrobox integration complete'"; then
    err "Container entry failed."
    exit 1
fi
ok "Integration set up"

# =============================================================================
# STEP 3/4 — STAGE FILES
# =============================================================================
banner "STEP 3/4 — STAGE FILES"

STAGING_DIR="$HOME/.ros2-${CONTAINER_NAME}-staging"
mkdir -p "$STAGING_DIR"
cp "$DEPS_SCRIPT" "$STAGING_DIR/2-install-ros2-deps.sh"
chmod +x "$STAGING_DIR/2-install-ros2-deps.sh"
ok "Scripts staged at: $STAGING_DIR"

# =============================================================================
# STEP 4/4 — RUN DEPENDENCY INSTALL
# =============================================================================
banner "STEP 4/4 — RUN DEPENDENCY INSTALL"

info "8 phases: Bootstrap → ROS2 Jazzy → Profile → Dev tools"
info "  → Node.js → Neovim + LazyVim → rosdep → Directory setup"
echo
info "Estimated time: 15-20 minutes."
echo
read -r -p "Ready? [Y/n] " confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    info "Cancelled. To resume later:"
    info "  distrobox enter $CONTAINER_NAME"
    info "  bash $STAGING_DIR/2-install-ros2-deps.sh"
    exit 0
fi

if ! distrobox enter "$CONTAINER_NAME" -- \
    bash "$STAGING_DIR/2-install-ros2-deps.sh"; then
    err "Dependency install hit an error."
    err "To resume:"
    err "  distrobox enter $CONTAINER_NAME"
    err "  bash $STAGING_DIR/2-install-ros2-deps.sh --resume"
fi

# =============================================================================
# CLEAN HOST ~/.bashrc
# =============================================================================
banner "PROTECTING HOST ~/.bashrc"

info "Removing any lines installers may have added..."
sed -i '/source.*\/opt\/ros\//d' "$HOME/.bashrc"
sed -i '/NVM_DIR/d' "$HOME/.bashrc"
sed -i '/nvm.sh/d' "$HOME/.bashrc"
sed -i '/nvm bash_completion/d' "$HOME/.bashrc"
sed -i '/^$/N;/^\n$/d' "$HOME/.bashrc"

ok "Host ~/.bashrc cleaned"

# =============================================================================
# DONE
# =============================================================================
banner "SETUP COMPLETE"

cat <<EOF

${GREEN}${BOLD}Container '$CONTAINER_NAME' is ready for ROS2 development.${NORMAL}

${BOLD}Architecture:${NORMAL}
  Shared home:     ~/
  Dedicated dir:   $CONTAINER_DIR
  Container-only:  /opt/ros/jazzy, /etc/profile.d
  Host ~/.bashrc:  ${GREEN}PROTECTED${NORMAL}

${BOLD}To enter:${NORMAL}
  distrobox enter $CONTAINER_NAME

${BOLD}Workflow:${NORMAL}
  distrobox enter $CONTAINER_NAME
  cd ~/ros2-CONTAINER
  mkdir -p my_project_ws/src && cd my_project_ws
  ros2 pkg create --build-type ament_cmake my_package
  colcon build
  source install/setup.bash

${BOLD}Available inside:${NORMAL}
  ros2, colcon, rviz2, gazebo, nvim (LazyVim)
  git profile use <work|personal|showcase>

EOF
