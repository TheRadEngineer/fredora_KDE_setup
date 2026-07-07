#!/usr/bin/env bash
# =============================================================================
# 2-install-deps.sh — Runs INSIDE the distrobox container.
# Called by 1-create-ros1-anscer-container.sh, or re-runnable standalone.
#
# Shared home architecture (no --home isolation):
#   ~/             → same as host home
#   ~/<ws_name>    → ROS workspace (visible from host VS Code)
#   /opt/deps/     → container-only build artifacts
#   /etc/profile.d → container-only config
#
# USAGE:
#   ./2-install-deps.sh <workspace_name>              # full run
#   ./2-install-deps.sh <workspace_name> --resume     # skip done phases
#
# All bug fixes from manual walkthroughs baked in (see comments per phase).
# =============================================================================

# NOTE: We use set -o pipefail but NOT set -e, because set -e doesn't work
# inside if/else blocks (bash spec). Instead, every critical command has
# explicit || { err "..."; exit 1; } error handling.
set -uo pipefail

# --- Arguments ---
WS_NAME="${1:-}"
RESUME=false
[[ "${2:-}" == "--resume" ]] && RESUME=true

if [[ -z "$WS_NAME" ]]; then
  echo "ERROR: Workspace name required."
  echo "Usage: $0 <workspace_name> [--resume]"
  exit 1
fi

# =============================================================================
# EDITABLE PACKAGE LISTS — add/remove packages here
# =============================================================================

APT_PACKAGES=(
  # Bootstrap (missing from minimal Ubuntu 20.04)
  lsb-release software-properties-common curl gnupg2 ca-certificates wget
  dirmngr apt-transport-https git build-essential

  # System utilities
  htop vim net-tools inetutils-ping python3-pip python-is-python3
  nmap fping dialog smartmontools libmodbus-dev libudev-dev
  autoconf libtool pkg-config cmake ninja-build stow doxygen libssl-dev
  libpthread-stubs0-dev python3-wstool python3-rosdep python3-vcstool
  mesa-utils

  # C++ libraries
  nlohmann-json3-dev libsdl-image1.2-dev libsdl-dev libfmt-dev libceres-dev
  liblua5.3-dev libdxflib-dev libspdlog-dev libgeographic-dev
  libcurl4-openssl-dev libprotobuf-dev protobuf-compiler libcairo2-dev

  # ROS Noetic packages (simulation scope — no hardware drivers)
  ros-noetic-navigation
  ros-noetic-move-base
  ros-noetic-move-base-msgs
  ros-noetic-mbf-costmap-core
  ros-noetic-mbf-msgs
  ros-noetic-costmap-converter
  ros-noetic-sob-layer
  ros-noetic-teb-local-planner
  ros-noetic-dwa-local-planner
  ros-noetic-ompl
  ros-noetic-rviz-visual-tools
  ros-noetic-tf2-sensor-msgs
  ros-noetic-geographic-msgs
  ros-noetic-joy
  ros-noetic-sound-play
  ros-noetic-pybind11-catkin
  ros-noetic-gtsam
  ros-noetic-mcl-3dl-msgs
  ros-noetic-ackermann-msgs
  ros-noetic-apriltag
  ros-noetic-behaviortree-cpp-v3
  ros-noetic-rosbridge-server
  ros-noetic-bondcpp
  ros-noetic-rqt-gui
  ros-noetic-rqt-gui-py
  ros-noetic-rqt-gui-cpp
  ros-noetic-pcl-ros
  ros-noetic-cmake-modules
  ros-noetic-ddynamic-reconfigure
  ros-noetic-filters
  ros-noetic-eigen-conversions
  ros-noetic-ros-control
  ros-noetic-ros-controllers
  ros-noetic-xacro
  ros-noetic-rosbash
  ros-noetic-gazebo-ros
  ros-noetic-gazebo-ros-pkgs
  ros-noetic-joint-state-publisher
  ros-noetic-robot-state-publisher
  ros-noetic-tf2-web-republisher

  # Python
  python3-tornado python3-pymongo
)

PIP_PACKAGES=(
  pymongo
  tornado
)

# Hardware-only packages to CATKIN_IGNORE (not needed for simulation)
CATKIN_IGNORE_PATHS=(
  "anscer_sensors/zed_driver"
  "anscer_sensors/zed_nodelets"
  "anscer_sensors/zed-ros-interfaces"
  "anscer_sensors/zed_wrapper"
  "anscer_sensors/phidgets_drivers"
)

# Version pins
GRPC_VERSION="v1.61.1"
MONGO_C_VERSION="1.22.1"
MONGO_CXX_VERSION="r3.7.1"
PAHO_C_VERSION="v1.3.8"
PAHO_CPP_VERSION="v1.2.0"
NVM_VERSION="v0.39.7"
NODE_VERSION="20"

# =============================================================================
# INTERNAL CONFIG
# =============================================================================

BUILD_DIR="/opt/deps"
STATE_DIR="/opt/deps/.install-state"
GRPC_INSTALL_DIR="/opt/grpc"
CARTO_DIR="$BUILD_DIR/carto_ws"
WS_DIR="$HOME/$WS_NAME"
CONFIG_FILE="$WS_DIR/src/anscer_systems/system_config/config/config"
PROFILE_FILE="/etc/profile.d/zzz-ros1-custom.sh"
LOG_FILE="/var/log/ros1-anscer-install.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

sudo touch "$LOG_FILE" 2>/dev/null || true
sudo chmod 666 "$LOG_FILE" 2>/dev/null || true

info() { echo -e "${BLUE}${BOLD}[INFO]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
ok() { echo -e "${GREEN}${BOLD}[ OK ]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}${BOLD}[WARN]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}${BOLD}[FAIL]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
skip() { echo -e "${CYAN}${BOLD}[SKIP]${NORMAL}  $*" | tee -a "$LOG_FILE"; }

phase() {
  echo | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}=====================================================${NORMAL}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${NORMAL}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}=====================================================${NORMAL}" | tee -a "$LOG_FILE"
}

is_done() { $RESUME && [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done() { touch "$STATE_DIR/$1.done"; }

# Verify a file exists or exit
verify() {
  if [[ -e "$1" ]]; then
    ok "Verified: $1"
  else
    err "VERIFICATION FAILED: $1 does not exist"
    err "The build for this phase likely failed silently."
    exit 1
  fi
}

# --- Pre-flight ---
[[ $EUID -eq 0 ]] && {
  err "Don't run as root."
  exit 1
}

sudo mkdir -p "$BUILD_DIR" "$STATE_DIR"
sudo chown -R "$USER:$USER" "$BUILD_DIR"

info "Workspace: $WS_DIR"
info "Repos YAML: $REPOS_YAML"
info "Log: $LOG_FILE"
$RESUME && info "Mode: RESUME"

# =============================================================================
# PHASE 1: Bootstrap tools
# =============================================================================
if is_done "phase01"; then skip "Phase 1 (bootstrap) done"; else
  phase "PHASE 1/18 — Bootstrap tools"
  export DEBIAN_FRONTEND=noninteractive
  echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 > /dev/null
  sudo apt-get update || {
    err "apt update failed"
    exit 1
  }
  sudo apt-get install -y \
    lsb-release software-properties-common curl gnupg2 ca-certificates \
    wget dirmngr apt-transport-https git build-essential ||
    {
      err "Bootstrap install failed"
      exit 1
    }
  ok "Bootstrap tools installed"
  mark_done "phase01"
fi

# =============================================================================
# PHASE 2: ROS Noetic (community one-liner)
# NOTE: This script writes to ~/.bashrc — the orchestrator cleans it after.
# =============================================================================
if is_done "phase02"; then skip "Phase 2 (ROS Noetic) done"; else
  phase "PHASE 2/18 — ROS Noetic"
  if [[ ! -d /opt/ros/noetic ]]; then
    cd /tmp
    wget -c https://raw.githubusercontent.com/qboticslabs/ros_install_noetic/master/ros_install_noetic.sh ||
      {
        err "Failed to download ROS install script"
        exit 1
      }
    chmod +x ros_install_noetic.sh
    bash -c "set +u; source /tmp/ros_install_noetic.sh" ||
      {
        err "ROS install failed"
        exit 1
      }
  fi
  verify /opt/ros/noetic/setup.bash
  ok "ROS Noetic installed"
  mark_done "phase02"
fi

# =============================================================================
# PHASE 3: Container profile (/etc/profile.d/ — container-specific)
# This file only loads inside the distrobox. Host shell never sources it.
# CRITICAL: Never use 'set -u' in this file — Ubuntu's .bashrc has unset vars.
# =============================================================================
if is_done "phase03"; then skip "Phase 3 (profile) done"; else
  phase "PHASE 3/18 — Container profile"

  sudo tee "$PROFILE_FILE" >/dev/null <<'PROFILE_EOF'
# =============================================================================
# ROS1 Noetic Distrobox — Container Profile
# This file ONLY runs inside the distrobox container.
# Host shell never sources it (it doesn't exist on the host filesystem).
# =============================================================================

# Colors
export TERM=xterm-256color
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# Prompt (cyan container name + yellow path)
export PS1='\[\033[01;36m\]📦 \u@\h\[\033[00m\]:\[\033[01;33m\]\w\[\033[00m\]\$ '

# NVIDIA GPU (fixes Gazebo/rviz Mesa fallback crash on Xwayland)
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
export LIBGL_ALWAYS_SOFTWARE=0

# Node.js via nvm
export NVM_DIR="$HOME/.config/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# ROS Noetic (set +u because ROS scripts reference unset vars)
set +u
[ -f /opt/ros/noetic/setup.bash ] && source /opt/ros/noetic/setup.bash
[ -f /opt/deps/carto_ws/install_isolated/setup.bash ] && source /opt/deps/carto_ws/install_isolated/setup.bash
PROFILE_EOF

  # Append workspace sourcing and aliases with variable expansion
  sudo tee -a "$PROFILE_FILE" >/dev/null <<PROFILE_DYNAMIC
[ -f $WS_DIR/devel/setup.bash ] && source $WS_DIR/devel/setup.bash

# MongoDB (no systemd in distrobox)
alias start-mongo='mongod --fork --logpath /tmp/mongod.log --dbpath /var/lib/mongodb'
alias stop-mongo='mongosh --eval "db.adminCommand({shutdown: 1})" 2>/dev/null || true'
alias mongo-status='pgrep -a mongod || echo "MongoDB not running"'

# Simulation
alias 111='set +u; source $WS_DIR/devel/setup.bash; source $CONFIG_FILE; roscd start_anscer && roslaunch launch/start_anscer.launch'
alias 222='cd $WS_DIR && set +u && source devel/setup.bash && source $CONFIG_FILE && cd src/anscer_iui/mission_control_ui && npm run dev'
PROFILE_DYNAMIC

  sudo chmod 644 "$PROFILE_FILE"
  ok "Profile written to $PROFILE_FILE"
  mark_done "phase03"
fi

# Source ROS for the rest of this script
set +u
source /opt/ros/noetic/setup.bash
set -u

# =============================================================================
# PHASE 4: Apt packages + pip
# =============================================================================
if is_done "phase04"; then skip "Phase 4 (apt/pip) done"; else
  phase "PHASE 4/18 — Apt packages + pip"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update || {
    err "apt update failed"
    exit 1
  }
  sudo apt-get install -y "${APT_PACKAGES[@]}" ||
    {
      err "Apt install failed"
      exit 1
    }
  pip3 install --user "${PIP_PACKAGES[@]}" ||
    {
      err "Pip install failed"
      exit 1
    }
  ok "All apt + pip packages installed"
  mark_done "phase04"
fi

# =============================================================================
# PHASE 5: OpenCV legacy symlinks
# =============================================================================
if is_done "phase05"; then skip "Phase 5 (OpenCV) done"; else
  phase "PHASE 5/18 — OpenCV legacy symlinks"
  if [[ -d /usr/include/opencv4/opencv2 ]]; then
    sudo ln -sf /usr/include/opencv4/opencv2/ /usr/include/opencv
    sudo ln -sf /usr/include/opencv4/opencv2/ /usr/include/opencv2
    ok "Symlinks created"
  else
    warn "opencv4 headers not found"
  fi
  mark_done "phase05"
fi

# =============================================================================
# PHASE 6: libserial (cmake directly — BUILD_DOCS=OFF avoids sphinx crash)
# =============================================================================
if is_done "phase06"; then skip "Phase 6 (libserial) done"; else
  phase "PHASE 6/18 — libserial"
  cd "$BUILD_DIR"
  [[ ! -d libserial ]] && git clone https://github.com/crayzeewulf/libserial.git
  cd libserial
  mkdir -p build && cd build
  cmake -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_DOCS=OFF .. ||
    {
      err "libserial cmake failed"
      exit 1
    }
  make -j"$(nproc)" || {
    err "libserial build failed"
    exit 1
  }
  sudo make install || {
    err "libserial install failed"
    exit 1
  }
  sudo ldconfig
  verify /usr/lib/x86_64-linux-gnu/libserial.so
  mark_done "phase06"
fi

# =============================================================================
# PHASE 7: gRPC (~15 min build)
# =============================================================================
if is_done "phase07"; then skip "Phase 7 (gRPC) done"; else
  phase "PHASE 7/18 — gRPC ${GRPC_VERSION}"
  cd "$BUILD_DIR"
  [[ ! -d grpc ]] && {
    git clone --branch "$GRPC_VERSION" --jobs "$(nproc)" \
      --depth 1 --recurse-submodules --shallow-submodules \
      https://github.com/grpc/grpc ||
      {
        err "gRPC clone failed"
        exit 1
      }
  }
  cd grpc && mkdir -p cmake/build && cd cmake/build
  cmake ../.. \
    -DgRPC_INSTALL=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$GRPC_INSTALL_DIR" \
    -DgRPC_ABSL_PROVIDER=module -DgRPC_CARES_PROVIDER=module \
    -DgRPC_PROTOBUF_PROVIDER=module -DgRPC_RE2_PROVIDER=module \
    -DgRPC_SSL_PROVIDER=module -DgRPC_ZLIB_PROVIDER=module ||
    {
      err "gRPC cmake failed"
      exit 1
    }
  sudo make -j"$(nproc)" install || {
    err "gRPC build/install failed"
    exit 1
  }
  sudo ldconfig
  verify "$GRPC_INSTALL_DIR/lib/libgrpc.a"
  mark_done "phase07"
fi

# =============================================================================
# PHASE 8: MongoDB C + C++ drivers
# =============================================================================
if is_done "phase08"; then skip "Phase 8 (MongoDB drivers) done"; else
  phase "PHASE 8/18 — MongoDB drivers"
  cd "$BUILD_DIR"
  [[ ! -d mongo-c-driver ]] && git clone https://github.com/mongodb/mongo-c-driver.git
  cd mongo-c-driver
  git checkout "$MONGO_C_VERSION" 2>/dev/null || true
  python3 build/calc_release_version.py >VERSION_CURRENT
  mkdir -p cmake-build && cd cmake-build
  cmake -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF .. ||
    {
      err "mongo-c cmake failed"
      exit 1
    }
  sudo cmake --build . --target install -- -j"$(nproc)" ||
    {
      err "mongo-c build failed"
      exit 1
    }
  sudo ldconfig
  verify /usr/local/lib/libmongoc-1.0.so

  cd "$BUILD_DIR"
  [[ ! -f "mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz" ]] &&
    curl -OL "https://github.com/mongodb/mongo-cxx-driver/releases/download/${MONGO_CXX_VERSION}/mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz"
  tar -xzf "mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz"
  cd "mongo-cxx-driver-${MONGO_CXX_VERSION}/build"
  cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local ||
    {
      err "mongo-cxx cmake failed"
      exit 1
    }
  sudo cmake --build . --target EP_mnmlstc_core ||
    {
      err "mongo-cxx EP_mnmlstc_core failed"
      exit 1
    }
  cmake --build . -- -j"$(nproc)" ||
    {
      err "mongo-cxx build failed"
      exit 1
    }
  sudo cmake --build . --target install ||
    {
      err "mongo-cxx install failed"
      exit 1
    }
  sudo ldconfig
  verify /usr/local/lib/libmongocxx.so
  mark_done "phase08"
fi

# =============================================================================
# PHASE 9: Paho MQTT C + C++
# =============================================================================
if is_done "phase09"; then skip "Phase 9 (Paho MQTT) done"; else
  phase "PHASE 9/18 — Paho MQTT"
  cd "$BUILD_DIR"
  [[ ! -d paho.mqtt.c ]] && git clone https://github.com/eclipse/paho.mqtt.c.git
  cd paho.mqtt.c && git checkout "$PAHO_C_VERSION" 2>/dev/null || true
  mkdir -p build && cd build
  cmake -DPAHO_WITH_SSL=ON -DPAHO_BUILD_SAMPLES=OFF -DCMAKE_INSTALL_PREFIX=/usr/local .. ||
    {
      err "Paho C cmake failed"
      exit 1
    }
  make -j"$(nproc)" || {
    err "Paho C build failed"
    exit 1
  }
  sudo make install || {
    err "Paho C install failed"
    exit 1
  }
  sudo ldconfig
  verify /usr/local/lib/libpaho-mqtt3as.so

  cd "$BUILD_DIR"
  [[ ! -d paho.mqtt.cpp ]] && git clone https://github.com/eclipse/paho.mqtt.cpp.git
  cd paho.mqtt.cpp && git checkout "$PAHO_CPP_VERSION" 2>/dev/null || true
  mkdir -p build && cd build
  cmake -DPAHO_BUILD_DOCUMENTATION=OFF -DPAHO_BUILD_SAMPLES=OFF -DCMAKE_INSTALL_PREFIX=/usr/local .. ||
    {
      err "Paho C++ cmake failed"
      exit 1
    }
  make -j"$(nproc)" || {
    err "Paho C++ build failed"
    exit 1
  }
  sudo make install || {
    err "Paho C++ install failed"
    exit 1
  }
  sudo ldconfig
  verify /usr/local/lib/libpaho-mqttpp3.so
  mark_done "phase09"
fi

# =============================================================================
# PHASE 10: rosdep init + update (BEFORE Cartographer)
# =============================================================================
if is_done "phase10"; then skip "Phase 10 (rosdep) done"; else
  phase "PHASE 10/18 — rosdep"
  [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]] &&
    { sudo rosdep init || warn "rosdep init may already exist"; }
  rosdep update || {
    err "rosdep update failed"
    exit 1
  }
  ok "rosdep ready"
  mark_done "phase10"
fi

# =============================================================================
# PHASE 11: Cartographer ROS (~15 min build)
# =============================================================================
if is_done "phase11"; then skip "Phase 11 (Cartographer) done"; else
  phase "PHASE 11/18 — Cartographer ROS"
  mkdir -p "$CARTO_DIR" && cd "$CARTO_DIR"
  rm -rf abseil-cpp

  if [[ ! -d src ]]; then
    wstool init src || {
      err "wstool init failed"
      exit 1
    }
    wstool merge -t src https://raw.githubusercontent.com/cartographer-project/cartographer_ros/master/cartographer_ros.rosinstall
    wstool update -t src || {
      err "wstool update failed"
      exit 1
    }
  fi

  set +u
  rosdep install --from-paths src --ignore-src --rosdistro=noetic -y \
    --skip-keys=libabsl-dev || warn "Some rosdep keys skipped"
  src/cartographer/scripts/install_abseil.sh || {
    set -u
    err "abseil install failed"
    exit 1
  }
  catkin_make_isolated --install --use-ninja || {
    set -u
    err "Cartographer build failed"
    exit 1
  }
  set -u

  rm -rf src/ devel_isolated/ build_isolated/ abseil-cpp/
  verify "$CARTO_DIR/install_isolated/setup.bash"
  mark_done "phase11"
fi

# =============================================================================
# PHASE 12: MongoDB server
# =============================================================================
if is_done "phase12"; then skip "Phase 12 (MongoDB server) done"; else
  phase "PHASE 12/18 — MongoDB server"
  if [[ ! -f /etc/apt/sources.list.d/mongodb-org-6.0.list ]]; then
    wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | sudo apt-key add -
    echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/6.0 multiverse" |
      sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
    sudo apt-get update
  fi
  sudo apt-get install -y mongodb-org || {
    err "MongoDB install failed"
    exit 1
  }
  sudo mkdir -p /var/lib/mongodb /var/log/mongodb
  sudo chown -R "$USER:$USER" /var/lib/mongodb /var/log/mongodb
  verify /usr/bin/mongod
  mark_done "phase12"
fi

# =============================================================================
# PHASE 13: Node.js via nvm
# =============================================================================
if is_done "phase13"; then skip "Phase 13 (Node.js) done"; else
  phase "PHASE 13/18 — Node.js ${NODE_VERSION} via nvm"
  export NVM_DIR="$HOME/.config/nvm"
  if [[ ! -d "$NVM_DIR" ]]; then
    PROFILE=/dev/null bash -c \
      "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash" ||
      {
        err "nvm install failed"
        exit 1
      }
  fi
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm install "$NODE_VERSION" || {
    err "Node install failed"
    exit 1
  }
  nvm alias default "$NODE_VERSION"
  nvm use "$NODE_VERSION"
  ok "Node $(node --version) + npm $(npm --version)"
  mark_done "phase13"
fi

# =============================================================================
# PHASE 14: SSH key
# =============================================================================
if is_done "phase14"; then skip "Phase 14 (SSH key) done"; else
  phase "PHASE 14/18 — SSH key for GitHub"
  if [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_rsa" ]]; then
    info "SSH key already exists"
  else
    info "No SSH key found. Generating..."
    read -r -p "Email for SSH key: " ssh_email
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "$ssh_email" -f "$HOME/.ssh/id_ed25519" -N ""
    ok "Key generated"
  fi

  echo
  echo -e "${BOLD}${YELLOW}Add this public key to GitHub → Settings → SSH Keys:${NORMAL}"
  echo
  cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || cat "$HOME/.ssh/id_rsa.pub"
  echo
  read -r -p "Press Enter after adding the key to GitHub..." _

  info "Testing GitHub SSH..."
  if ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | grep -q "successfully authenticated"; then
    ok "GitHub SSH working"
  else
    warn "SSH test unclear — continuing."
  fi
  mark_done "phase14"
fi

# =============================================================================
# PHASE 15: Clone repos via vcstool
# =============================================================================
if is_done "phase15"; then skip "Phase 15 (clone) done"; else
  phase "PHASE 15/18 — Clone workspace repos"
  [[ ! -f "$REPOS_YAML" ]] && {
    err "Repos YAML not found: $REPOS_YAML"
    exit 1
  }
  mkdir -p "$WS_DIR/src"
  cd "$WS_DIR"
  if [[ -z "$(ls -A src 2>/dev/null)" ]]; then
    vcs import src <"$REPOS_YAML" || {
      err "vcs import failed"
      exit 1
    }
    ok "Repos cloned"
  else
    skip "src/ not empty — repos likely already cloned"
  fi
  mark_done "phase15"
fi

# =============================================================================
# PHASE 16: CATKIN_IGNORE hardware + workspace rosdep
# =============================================================================
if is_done "phase16"; then skip "Phase 16 (CATKIN_IGNORE + rosdep) done"; else
  phase "PHASE 16/18 — CATKIN_IGNORE hardware + workspace rosdep"
  for pkg_path in "${CATKIN_IGNORE_PATHS[@]}"; do
    full="$WS_DIR/src/$pkg_path"
    if [[ -d "$full" ]]; then
      touch "$full/CATKIN_IGNORE"
      [[ -f "$full/package.xml" ]] && mv "$full/package.xml" "$full/package.xml.ignored"
      info "  Ignored: $pkg_path"
    else
      warn "  Not found: $pkg_path"
    fi
  done
  ok "Hardware packages ignored"

  cd "$WS_DIR"
  set +u
  rosdep install --from-paths src --ignore-src --rosdistro=noetic -y \
    --skip-keys=libabsl-dev || warn "Some rosdep keys skipped"
  set -u
  ok "Workspace rosdep resolved"
  mark_done "phase16"
fi

# =============================================================================
# PHASE 17: Simulation config (environment variables)
# =============================================================================
if is_done "phase17"; then skip "Phase 17 (sim config) done"; else
  phase "PHASE 17/18 — Simulation config"
  mkdir -p "$(dirname "$CONFIG_FILE")"

  cat >"$CONFIG_FILE" <<CONFIG_EOF
# ==============================
# ANSCER SYSTEM CONFIG (SIMULATION)
# Generated by 2-install-deps.sh
# ==============================

export ANSCER_BRINGUP=simulation

export ROBOT_MODEL=amr
export ROBOT_PAYLOAD=500

export ENABLE_FMS=true
export FMS_BROKER_IP=192.168.0.100
export FMS_BROKER_PORT=1883

# MongoDB
export DB_ADDRESS=localhost
export DB_PORT=27017
export DB_URI="mongodb://localhost:27017"
export LOCAL_DB_URI="mongodb://localhost:27017"
export USER_NAME=dummy
export PASSWORD=dummy

# Paths
export HOME_DIRECTORY=$HOME
export ROS_BAG_PATH=$HOME
export MAX_LOCATION=$HOME

# Robot limits
export MAX_LOAD_MASS=250

# Simulation
export ANSCER_SIMULATION=gazebo

# UI + Navigation
export ENABLE_GUI=true
export ENABLE_UI=true
export ANSCER_NAVIGATION=mwp
export ANSCER_GRAPH_FRAME=map
export DEFAULT_GRAPH=default
export USE_ASTAR=true
export USE_ANSCER_PLANNER=true
export ANSCER_LOCALIZATION=amcl

# Robot footprint
export ROBOT_FOOTPRINT='[[0.45,0.30],[0.45,-0.30],[-0.45,-0.30],[-0.45,0.30]]'
export ROBOT_LENGTH=0.9
export ROBOT_WIDTH=0.6
export TROLLEY_FOOTPRINT='[[0.25,0.25],[0.25,-0.25],[-0.25,-0.25],[-0.25,0.25]]'

# Sensors
export NO_OF_LIDAR=2
export LIDAR_TYPE=2D
CONFIG_EOF

  ok "Simulation config at $CONFIG_FILE"
  mark_done "phase18"
fi

# =============================================================================
# PHASE 19: npm install for Mission Control UI
# =============================================================================
if is_done "phase18"; then skip "Phase 18 (npm) done"; else
  phase "PHASE 18/18 — npm install"
  export NVM_DIR="$HOME/.config/nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm use "$NODE_VERSION"

  UI_DIR="$WS_DIR/src/anscer_iui/mission_control_ui"
  if [[ -d "$UI_DIR" ]]; then
    cd "$UI_DIR"
    rm -rf node_modules package-lock.json
    npm install || {
      err "npm install failed"
      exit 1
    }
    ok "npm dependencies installed"
  else
    warn "UI dir not found: $UI_DIR — skipping"
  fi
  mark_done "phase18"
fi

# =============================================================================
# FINAL VERIFICATION
# =============================================================================
phase "FINAL VERIFICATION"

PASS=true
checks=(
  "/opt/ros/noetic/setup.bash:ROS Noetic"
  "/usr/lib/x86_64-linux-gnu/libserial.so:libserial"
  "$GRPC_INSTALL_DIR/lib/libgrpc.a:gRPC"
  "/usr/local/lib/libmongoc-1.0.so:mongo-c-driver"
  "/usr/local/lib/libmongocxx.so:mongo-cxx-driver"
  "/usr/local/lib/libpaho-mqtt3as.so:Paho MQTT C"
  "/usr/local/lib/libpaho-mqttpp3.so:Paho MQTT C++"
  "$CARTO_DIR/install_isolated/setup.bash:Cartographer"
  "/usr/bin/mongod:MongoDB server"
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
if command -v node &>/dev/null; then
  ok "Node.js $(node --version)"
else
  err "Node.js MISSING"
  PASS=false
fi

if $PASS; then
  ok "All verifications passed"
else
  err "Some components are missing — check above"
  err "Re-run with --resume after fixing the issues"
  exit 1
fi

# =============================================================================
# DONE
# =============================================================================
phase "ALL 18 PHASES COMPLETE"

cat <<EOF | tee -a "$LOG_FILE"

${GREEN}${BOLD}Container is ready for catkin_make.${NORMAL}

${BOLD}What's installed:${NORMAL}
  ✓ Ubuntu 20.04 + ROS Noetic desktop-full
  ✓ All apt packages (simulation scope, ${#APT_PACKAGES[@]} packages)
  ✓ Source builds: libserial, gRPC, MongoDB drivers, Paho MQTT, Cartographer
  ✓ MongoDB server, Node.js ${NODE_VERSION}
  ✓ Workspace cloned, CATKIN_IGNORE'd, system_config generated
  ✓ Simulation config written, npm installed

${BOLD}${YELLOW}FINAL STEP — build the full workspace:${NORMAL}

  exit
  distrobox enter $(hostname)
  cd $WS_DIR
  catkin_make

${BOLD}Then run the simulation:${NORMAL}

  start-mongo
  111                    # Terminal 1: ROS stack
  222                    # Terminal 2: Web UI
  Browser: http://localhost:5173

EOF
