#!/usr/bin/env bash
# =============================================================================
# 1-create-ros1-anscer-container.sh — MAIN ORCHESTRATOR
# Run on your Fedora host.
#
# Architecture:
#   Shared home:     Container uses host's ~/  (same as ros1-noetic that works)
#   Container-only:  /opt/ros, /opt/deps, /etc/profile.d  (isolated from host)
#   Workspace:       ~/<ws_name>  (visible from host for VS Code editing)
#   Host ~/.bashrc:  PROTECTED — script cleans any contamination after install
#
# All container config goes to /etc/profile.d/zzz-ros1-custom.sh which only
# loads inside the container. Host shell never sources it.
#
# REQUIRED FILES (same directory):
#   - 2-install-deps.sh
#   - anscer-repos.yaml
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_SCRIPT="$SCRIPT_DIR/2-install-deps.sh"
REPOS_YAML="$SCRIPT_DIR/anscer-repos.yaml"

# --- Colors ---
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'
  NORMAL=$'\e[0m'
  RED=$'\e[31m'
  GREEN=$'\e[32m'
  YELLOW=$'\e[33m'
  BLUE=$'\e[34m'
  CYAN=$'\e[36m'
else
  BOLD=""
  NORMAL=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
fi

info() { echo -e "${BLUE}${BOLD}[INFO]${NORMAL}  $*"; }
ok() { echo -e "${GREEN}${BOLD}[ OK ]${NORMAL}  $*"; }
warn() { echo -e "${YELLOW}${BOLD}[WARN]${NORMAL}  $*"; }
err() { echo -e "${RED}${BOLD}[FAIL]${NORMAL}  $*"; }

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
banner "ROS1 NOETIC CONTAINER BOOTSTRAP"

command -v distrobox &>/dev/null || {
  err "distrobox not found. Run 00-host-setup.sh first."
  exit 1
}
ok "distrobox: $(distrobox --version | head -1)"

HAS_NVIDIA=false
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    HAS_NVIDIA=true
    ok "NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
else
    warn "No NVIDIA GPU detected — container will use software rendering"
fi

[[ -f "$DEPS_SCRIPT" ]] || {
  err "Missing: $DEPS_SCRIPT"
  exit 1
}
[[ -f "$REPOS_YAML" ]] || {
  err "Missing: $REPOS_YAML"
  exit 1
}
ok "Required files found"

# Save a snapshot of host ~/.bashrc BEFORE anything runs
BASHRC_BACKUP="$HOME/.bashrc.pre-ros1-container.bak"
cp "$HOME/.bashrc" "$BASHRC_BACKUP"
ok "Host ~/.bashrc backed up to $BASHRC_BACKUP"

# =============================================================================
# USER INPUT
# =============================================================================
banner "CONFIGURATION"

DEFAULT_WS="anscer_ws"
read -r -p "Workspace name (created at ~/<name>) [$DEFAULT_WS]: " WS_NAME
WS_NAME="${WS_NAME:-$DEFAULT_WS}"
WS_NAME=$(echo "$WS_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_')
[[ -z "$WS_NAME" ]] && {
  err "Invalid workspace name."
  exit 1
}
ok "Workspace: ~/$WS_NAME"

DEFAULT_CONTAINER="ros1-anscer"
read -r -p "Container name [$DEFAULT_CONTAINER]: " CONTAINER_NAME
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER}"
ok "Container: $CONTAINER_NAME"

# Check existing container
if distrobox list 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
  warn "Container '$CONTAINER_NAME' already exists."
  read -r -p "Delete it and start fresh? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    distrobox rm --force "$CONTAINER_NAME" 2>/dev/null || true
    ok "Removed"
  else
    err "Choose a different name or delete manually."
    exit 1
  fi
fi

# =============================================================================
# STEP 1/4 — CREATE CONTAINER
# =============================================================================
banner "STEP 1/4 — CREATE CONTAINER"

info "Shared home (no --home isolation) — same architecture as working ros1-noetic"
NVIDIA_FLAG=""
$HAS_NVIDIA && NVIDIA_FLAG="--nvidia"

if ! distrobox create \
  --name "$CONTAINER_NAME" \
  --hostname "$CONTAINER_NAME" \
  --image ubuntu:20.04 \
  $NVIDIA_FLAG \
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

STAGING_DIR="$HOME/.ros1-${CONTAINER_NAME}-staging"
mkdir -p "$STAGING_DIR"
cp "$DEPS_SCRIPT" "$STAGING_DIR/2-install-deps.sh"
cp "$REPOS_YAML" "$STAGING_DIR/anscer-repos.yaml"
chmod +x "$STAGING_DIR/2-install-deps.sh"
ok "Scripts staged at: $STAGING_DIR"

# =============================================================================
# STEP 4/4 — RUN DEPENDENCY INSTALL
# =============================================================================
banner "STEP 4/4 — RUN DEPENDENCY INSTALL"

info "19 phases: Bootstrap → ROS → Profile → Apt → Source builds"
info "  (libserial, gRPC, MongoDB drivers, Paho MQTT, Cartographer)"
info "  → MongoDB → Node.js → LazyVim → SSH → Clone → CATKIN_IGNORE"
info "  → Sim config → npm install"
echo
info "Estimated time: 45-90 minutes."
echo
read -r -p "Ready? [Y/n] " confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
  info "Cancelled. To resume later:"
  info "  distrobox enter $CONTAINER_NAME"
  info "  bash $STAGING_DIR/2-install-deps.sh $WS_NAME $HAS_NVIDIA"
  exit 0
fi

if ! distrobox enter "$CONTAINER_NAME" -- \
  bash "$STAGING_DIR/2-install-deps.sh" "$WS_NAME" "$HAS_NVIDIA"; then
  err "Dependency install hit an error."
  err "To resume:"
  err "  distrobox enter $CONTAINER_NAME"
  err "  bash $STAGING_DIR/2-install-deps.sh $WS_NAME $HAS_NVIDIA --resume"
fi

# =============================================================================
# CLEAN HOST ~/.bashrc
# =============================================================================
banner "PROTECTING HOST ~/.bashrc"

info "Removing any lines the ROS/nvm installers may have added..."
# Remove ROS source lines
sed -i '/source.*\/opt\/ros\//d' "$HOME/.bashrc"
# Remove carto source lines
sed -i '/source.*carto_ws/d' "$HOME/.bashrc"
# Remove NVM lines (in case PROFILE=/dev/null didn't work)
sed -i '/NVM_DIR/d' "$HOME/.bashrc"
sed -i '/nvm.sh/d' "$HOME/.bashrc"
sed -i '/nvm bash_completion/d' "$HOME/.bashrc"
# Remove empty lines left behind (collapse multiple blank lines)
sed -i '/^$/N;/^\n$/d' "$HOME/.bashrc"

ok "Host ~/.bashrc cleaned"
info "Backup at: $BASHRC_BACKUP"

# =============================================================================
# DONE
# =============================================================================
banner "SETUP COMPLETE"

cat <<EOF

${GREEN}${BOLD}Container '$CONTAINER_NAME' is ready.${NORMAL}

${BOLD}Architecture:${NORMAL}
  Shared home:   ~/ (host ↔ container)
  Container-only: /opt/ros, /opt/deps, /etc/profile.d
  Workspace:     ~/$WS_NAME
  Host ~/.bashrc: ${GREEN}PROTECTED${NORMAL} (backup at $BASHRC_BACKUP)

${BOLD}To enter:${NORMAL}
  distrobox enter $CONTAINER_NAME

${BOLD}Build the workspace (first time):${NORMAL}
  distrobox enter $CONTAINER_NAME
  cd ~/$WS_NAME
  catkin_make

${BOLD}Aliases inside container:${NORMAL}
  ${CYAN}start-mongo${NORMAL}   Start MongoDB
  ${CYAN}stop-mongo${NORMAL}    Stop MongoDB
  ${CYAN}mongo-status${NORMAL}  Check MongoDB
  ${CYAN}111${NORMAL}           Launch ROS simulation
  ${CYAN}222${NORMAL}           Launch Mission Control web UI

${BOLD}Run the simulation:${NORMAL}
  Terminal 1:  start-mongo && 111
  Terminal 2:  222
  Browser:     http://localhost:5173

EOF
