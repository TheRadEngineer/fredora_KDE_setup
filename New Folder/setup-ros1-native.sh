#!/usr/bin/env bash
# =============================================================================
# setup-ros1-native.sh — ROS1 Noetic + ANSCER Simulation Stack
# For: Kubuntu/Ubuntu 20.04 LTS (native install, no containers)
#
# This script sets up everything needed to build and run the ANSCER simulation
# stack directly on the machine. No distrobox, no Docker — just native Ubuntu.
#
# USAGE:
#   ./setup-ros1-native.sh <workspace_name>            # full run
#   ./setup-ros1-native.sh <workspace_name> --resume   # skip done phases
#
# EXAMPLE:
#   ./setup-ros1-native.sh anscer_ws
#
# REQUIRED FILES (same directory):
#   - anscer-repos.yaml
#
# 14 phases:
#   1.  System update + essential tools
#   2.  ROS Noetic
#   3.  Apt packages (ROS + C++ libs + tools)
#   4.  pip packages
#   5.  OpenCV symlinks
#   6.  libserial (from source)
#   7.  gRPC (from source)
#   8.  MongoDB drivers (from source)
#   9.  Paho MQTT (from source)
#  10.  Cartographer (from source)
#  11.  MongoDB server
#  12.  Node.js via nvm + Neovim + LazyVim
#  13.  Clone repos + CATKIN_IGNORE + rosdep
#  14.  Simulation config + npm install + bashrc
# =============================================================================

set -uo pipefail

# --- Arguments ---
WS_NAME="${1:-}"
RESUME=false
[[ "${1:-}" == "--resume" ]] && { RESUME=true; WS_NAME="${2:-}"; }
[[ "${2:-}" == "--resume" ]] && RESUME=true

if [[ -z "$WS_NAME" ]]; then
    echo "ERROR: Workspace name required."
    echo "Usage: $0 <workspace_name> [--resume]"
    echo "   or: $0 --resume <workspace_name>"
    exit 1
fi

# =============================================================================
# EDITABLE PACKAGE LISTS — add/remove packages here
# =============================================================================

APT_PACKAGES=(
    # System utilities
    htop vim net-tools inetutils-ping python3-pip python-is-python3
    nmap fping dialog smartmontools libmodbus-dev libudev-dev
    autoconf libtool pkg-config cmake ninja-build stow doxygen libssl-dev
    libpthread-stubs0-dev python3-wstool python3-rosdep python3-vcstool
    mesa-utils sshfs curl wget git build-essential
    software-properties-common gnupg2 ca-certificates
    ripgrep fd-find

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
STATE_DIR="$HOME/.ros1-native-state"
GRPC_INSTALL_DIR="/opt/grpc"
CARTO_DIR="$BUILD_DIR/carto_ws"
WS_DIR="$HOME/$WS_NAME"
CONFIG_FILE="$WS_DIR/src/anscer_systems/system_config/config/config"
LOG_FILE="$HOME/ros1-native-install.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_YAML="$SCRIPT_DIR/anscer-repos.yaml"

# --- Colors ---
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; NORMAL=$'\e[0m'
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'
else
    BOLD=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

: > "$LOG_FILE"

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
[[ $EUID -eq 0 ]] && { err "Don't run as root. Script uses sudo internally."; exit 1; }

grep -q "Ubuntu" /etc/os-release 2>/dev/null || { err "Not Ubuntu. This script is for Ubuntu/Kubuntu 20.04."; exit 1; }
grep -q "20.04" /etc/os-release 2>/dev/null || warn "Expected Ubuntu 20.04 — proceeding anyway"

sudo -v || { err "Need sudo."; exit 1; }

mkdir -p "$STATE_DIR"
sudo mkdir -p "$BUILD_DIR"
sudo chown -R "$USER:$USER" "$BUILD_DIR"

info "Workspace: $WS_DIR"
info "Repos YAML: $REPOS_YAML"
info "Log: $LOG_FILE"
info "State: $STATE_DIR"
$RESUME && info "Mode: RESUME"

# =============================================================================
# PHASE 1: System update + essential tools
# =============================================================================
if is_done "phase01"; then skip "Phase 1 (system update) done"; else
    phase "PHASE 1/14 — System update + essential tools"
    export DEBIAN_FRONTEND=noninteractive

    # Force IPv4 (avoids IPv6 CDN issues)
    echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 > /dev/null

    sudo apt-get update || { err "apt update failed"; exit 1; }
    sudo apt-get upgrade -y || warn "Some upgrades failed"
    sudo apt-get install -y \
        lsb-release software-properties-common curl gnupg2 ca-certificates \
        wget dirmngr apt-transport-https git build-essential \
        || { err "Essential tools install failed"; exit 1; }

    ok "System updated + essential tools installed"
    mark_done "phase01"
fi

# =============================================================================
# PHASE 2: ROS Noetic (community one-liner)
# =============================================================================
if is_done "phase02"; then skip "Phase 2 (ROS Noetic) done"; else
    phase "PHASE 2/14 — ROS Noetic"
    if [[ ! -d /opt/ros/noetic ]]; then
        cd /tmp
        wget -c https://raw.githubusercontent.com/qboticslabs/ros_install_noetic/master/ros_install_noetic.sh \
            || { err "Failed to download ROS install script"; exit 1; }
        chmod +x ros_install_noetic.sh
        set +u
        ./ros_install_noetic.sh || { set -u; err "ROS install failed"; exit 1; }
        set -u
    fi
    verify /opt/ros/noetic/setup.bash
    ok "ROS Noetic installed"
    mark_done "phase02"
fi

# Source ROS for the rest of this script
set +u; source /opt/ros/noetic/setup.bash; set -u

# =============================================================================
# PHASE 3: Apt packages
# =============================================================================
if is_done "phase03"; then skip "Phase 3 (apt) done"; else
    phase "PHASE 3/14 — Apt packages"
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update || { err "apt update failed"; exit 1; }
    sudo apt-get install -y "${APT_PACKAGES[@]}" \
        || { err "Apt install failed"; exit 1; }
    ok "All apt packages installed"
    mark_done "phase03"
fi

# =============================================================================
# PHASE 4: pip packages
# =============================================================================
if is_done "phase04"; then skip "Phase 4 (pip) done"; else
    phase "PHASE 4/14 — pip packages"
    pip3 install --user "${PIP_PACKAGES[@]}" \
        || { err "Pip install failed"; exit 1; }
    ok "pip packages installed"
    mark_done "phase04"
fi

# =============================================================================
# PHASE 5: OpenCV legacy symlinks
# =============================================================================
if is_done "phase05"; then skip "Phase 5 (OpenCV) done"; else
    phase "PHASE 5/14 — OpenCV legacy symlinks"
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
# PHASE 6: libserial (cmake directly — BUILD_DOCS=OFF)
# =============================================================================
if is_done "phase06"; then skip "Phase 6 (libserial) done"; else
    phase "PHASE 6/14 — libserial"
    cd "$BUILD_DIR"
    [[ ! -d libserial ]] && git clone https://github.com/crayzeewulf/libserial.git
    cd libserial
    mkdir -p build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_DOCS=OFF .. \
        || { err "libserial cmake failed"; exit 1; }
    make -j"$(nproc)" || { err "libserial build failed"; exit 1; }
    sudo make install || { err "libserial install failed"; exit 1; }
    sudo ldconfig
    verify /usr/lib/x86_64-linux-gnu/libserial.so
    mark_done "phase06"
fi

# =============================================================================
# PHASE 7: gRPC (~15 min build)
# =============================================================================
if is_done "phase07"; then skip "Phase 7 (gRPC) done"; else
    phase "PHASE 7/14 — gRPC ${GRPC_VERSION}"
    cd "$BUILD_DIR"
    [[ ! -d grpc ]] && {
        git clone --branch "$GRPC_VERSION" --jobs "$(nproc)" \
            --depth 1 --recurse-submodules --shallow-submodules \
            https://github.com/grpc/grpc \
            || { err "gRPC clone failed"; exit 1; }
    }
    cd grpc && mkdir -p cmake/build && cd cmake/build
    cmake ../.. \
        -DgRPC_INSTALL=ON -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$GRPC_INSTALL_DIR" \
        -DgRPC_ABSL_PROVIDER=module -DgRPC_CARES_PROVIDER=module \
        -DgRPC_PROTOBUF_PROVIDER=module -DgRPC_RE2_PROVIDER=module \
        -DgRPC_SSL_PROVIDER=module -DgRPC_ZLIB_PROVIDER=module \
        || { err "gRPC cmake failed"; exit 1; }
    sudo make -j"$(nproc)" install || { err "gRPC build/install failed"; exit 1; }
    sudo ldconfig
    verify "$GRPC_INSTALL_DIR/lib/libgrpc.a"
    mark_done "phase07"
fi

# =============================================================================
# PHASE 8: MongoDB C + C++ drivers
# =============================================================================
if is_done "phase08"; then skip "Phase 8 (MongoDB drivers) done"; else
    phase "PHASE 8/14 — MongoDB drivers"
    cd "$BUILD_DIR"
    [[ ! -d mongo-c-driver ]] && git clone https://github.com/mongodb/mongo-c-driver.git
    cd mongo-c-driver
    git checkout "$MONGO_C_VERSION" 2>/dev/null || true
    python3 build/calc_release_version.py > VERSION_CURRENT
    mkdir -p cmake-build && cd cmake-build
    cmake -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF .. \
        || { err "mongo-c cmake failed"; exit 1; }
    sudo cmake --build . --target install -- -j"$(nproc)" \
        || { err "mongo-c build failed"; exit 1; }
    sudo ldconfig
    verify /usr/local/lib/libmongoc-1.0.so

    cd "$BUILD_DIR"
    [[ ! -f "mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz" ]] && \
        curl -OL "https://github.com/mongodb/mongo-cxx-driver/releases/download/${MONGO_CXX_VERSION}/mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz"
    tar -xzf "mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz"
    cd "mongo-cxx-driver-${MONGO_CXX_VERSION}/build"
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        || { err "mongo-cxx cmake failed"; exit 1; }
    sudo cmake --build . --target EP_mnmlstc_core \
        || { err "mongo-cxx EP_mnmlstc_core failed"; exit 1; }
    cmake --build . -- -j"$(nproc)" \
        || { err "mongo-cxx build failed"; exit 1; }
    sudo cmake --build . --target install \
        || { err "mongo-cxx install failed"; exit 1; }
    sudo ldconfig
    verify /usr/local/lib/libmongocxx.so
    mark_done "phase08"
fi

# =============================================================================
# PHASE 9: Paho MQTT C + C++
# =============================================================================
if is_done "phase09"; then skip "Phase 9 (Paho MQTT) done"; else
    phase "PHASE 9/14 — Paho MQTT"
    cd "$BUILD_DIR"
    [[ ! -d paho.mqtt.c ]] && git clone https://github.com/eclipse/paho.mqtt.c.git
    cd paho.mqtt.c && git checkout "$PAHO_C_VERSION" 2>/dev/null || true
    mkdir -p build && cd build
    cmake -DPAHO_WITH_SSL=ON -DPAHO_BUILD_SAMPLES=OFF -DCMAKE_INSTALL_PREFIX=/usr/local .. \
        || { err "Paho C cmake failed"; exit 1; }
    make -j"$(nproc)" || { err "Paho C build failed"; exit 1; }
    sudo make install || { err "Paho C install failed"; exit 1; }
    sudo ldconfig
    verify /usr/local/lib/libpaho-mqtt3as.so

    cd "$BUILD_DIR"
    [[ ! -d paho.mqtt.cpp ]] && git clone https://github.com/eclipse/paho.mqtt.cpp.git
    cd paho.mqtt.cpp && git checkout "$PAHO_CPP_VERSION" 2>/dev/null || true
    mkdir -p build && cd build
    cmake -DPAHO_BUILD_DOCUMENTATION=OFF -DPAHO_BUILD_SAMPLES=OFF -DCMAKE_INSTALL_PREFIX=/usr/local .. \
        || { err "Paho C++ cmake failed"; exit 1; }
    make -j"$(nproc)" || { err "Paho C++ build failed"; exit 1; }
    sudo make install || { err "Paho C++ install failed"; exit 1; }
    sudo ldconfig
    verify /usr/local/lib/libpaho-mqttpp3.so
    mark_done "phase09"
fi

# =============================================================================
# PHASE 10: rosdep + Cartographer ROS
# =============================================================================
if is_done "phase10"; then skip "Phase 10 (Cartographer) done"; else
    phase "PHASE 10/14 — rosdep + Cartographer ROS"

    # rosdep first (Cartographer needs it)
    if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        sudo rosdep init || warn "rosdep init may already exist"
    fi
    rosdep update || { err "rosdep update failed"; exit 1; }
    ok "rosdep ready"

    # Cartographer
    mkdir -p "$CARTO_DIR" && cd "$CARTO_DIR"
    rm -rf abseil-cpp

    if [[ ! -d src ]]; then
        wstool init src || { err "wstool init failed"; exit 1; }
        wstool merge -t src https://raw.githubusercontent.com/cartographer-project/cartographer_ros/master/cartographer_ros.rosinstall
        wstool update -t src || { err "wstool update failed"; exit 1; }
    fi

    set +u
    rosdep install --from-paths src --ignore-src --rosdistro=noetic -y \
        --skip-keys=libabsl-dev || warn "Some rosdep keys skipped"
    src/cartographer/scripts/install_abseil.sh || { set -u; err "abseil install failed"; exit 1; }
    catkin_make_isolated --install --use-ninja || { set -u; err "Cartographer build failed"; exit 1; }
    set -u

    rm -rf src/ devel_isolated/ build_isolated/ abseil-cpp/
    verify "$CARTO_DIR/install_isolated/setup.bash"
    mark_done "phase10"
fi

# =============================================================================
# PHASE 11: MongoDB server
# =============================================================================
if is_done "phase11"; then skip "Phase 11 (MongoDB server) done"; else
    phase "PHASE 11/14 — MongoDB server"
    if [[ ! -f /etc/apt/sources.list.d/mongodb-org-6.0.list ]]; then
        wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | sudo apt-key add -
        echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/6.0 multiverse" \
            | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
        sudo apt-get update
    fi
    sudo apt-get install -y mongodb-org || { err "MongoDB install failed"; exit 1; }

    # Create data dirs
    sudo mkdir -p /var/lib/mongodb /var/log/mongodb
    sudo chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb

    # Enable MongoDB service (native Ubuntu has systemd)
    sudo systemctl enable --now mongod || warn "mongod service start failed"

    verify /usr/bin/mongod
    ok "MongoDB server installed and running"
    mark_done "phase11"
fi

# =============================================================================
# PHASE 12: Node.js via nvm + Neovim + LazyVim
# =============================================================================
if is_done "phase12"; then skip "Phase 12 (Node + Neovim + LazyVim) done"; else
    phase "PHASE 12/14 — Node.js + Neovim + LazyVim"

    # Node.js via nvm
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

    # Neovim (latest stable — Ubuntu 20.04's is too old for LazyVim)
    info "Installing latest stable Neovim"
    sudo apt-get remove -y neovim neovim-runtime 2>/dev/null || true
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

    # LazyVim dependencies
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

    # LazyVim starter config
    if [[ -f "$HOME/.config/nvim/.lazyvim-installed" ]]; then
        skip "LazyVim already installed"
    else
        [[ -d "$HOME/.config/nvim" ]] && \
            mv "$HOME/.config/nvim" "$HOME/.config/nvim.backup.$(date +%Y%m%d-%H%M%S)"
        git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" \
            || { err "LazyVim clone failed"; exit 1; }
        rm -rf "$HOME/.config/nvim/.git"
        touch "$HOME/.config/nvim/.lazyvim-installed"
        ok "LazyVim installed"
    fi

    mark_done "phase12"
fi

# =============================================================================
# PHASE 13: SSH check + Clone repos + CATKIN_IGNORE + rosdep
# =============================================================================
if is_done "phase13"; then skip "Phase 13 (clone + config) done"; else
    phase "PHASE 13/14 — SSH + Clone repos + CATKIN_IGNORE"

    # SSH check
    if ls "$HOME"/.ssh/id_* &>/dev/null || [[ -f "$HOME/.ssh/config" ]]; then
        info "SSH keys/config already detected"
    else
        info "No SSH key found. Generating..."
        read -r -p "Email for SSH key: " ssh_email
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -C "$ssh_email" -f "$HOME/.ssh/id_ed25519" -N ""
        ok "Key generated"

        echo
        echo -e "${BOLD}${YELLOW}Add this public key to GitHub → Settings → SSH Keys:${NORMAL}"
        echo
        cat "$HOME/.ssh/id_ed25519.pub"
        echo
        read -r -p "Press Enter after adding the key to GitHub..." _
    fi

    ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

    # Clone repos
    [[ ! -f "$REPOS_YAML" ]] && { err "Repos YAML not found: $REPOS_YAML"; exit 1; }
    mkdir -p "$WS_DIR/src"
    cd "$WS_DIR"
    if [[ -z "$(ls -A src 2>/dev/null)" ]]; then
        vcs import src < "$REPOS_YAML" || { err "vcs import failed"; exit 1; }
        ok "Repos cloned"
    else
        skip "src/ not empty — repos likely already cloned"
    fi

    # CATKIN_IGNORE hardware packages
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

    # Workspace rosdep
    cd "$WS_DIR"
    set +u
    rosdep install --from-paths src --ignore-src --rosdistro=noetic -y \
        --skip-keys=libabsl-dev || warn "Some rosdep keys skipped"
    set -u
    ok "Repos cloned, hardware ignored, rosdep resolved"
    mark_done "phase13"
fi

# =============================================================================
# PHASE 14: Simulation config + npm install + bashrc
# =============================================================================
if is_done "phase14"; then skip "Phase 14 (config + npm + bashrc) done"; else
    phase "PHASE 14/14 — Simulation config + npm + bashrc"

    # Simulation config
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<CONFIG_EOF
# ==============================
# ANSCER SYSTEM CONFIG (SIMULATION)
# Generated by setup-ros1-native.sh
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

    # npm install for web UI
    export NVM_DIR="$HOME/.config/nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm use "$NODE_VERSION"

    UI_DIR="$WS_DIR/src/anscer_iui/mission_control_ui"
    if [[ -d "$UI_DIR" ]]; then
        cd "$UI_DIR"
        rm -rf node_modules package-lock.json
        npm install || { err "npm install failed"; exit 1; }
        ok "npm dependencies installed"
    else
        warn "UI dir not found: $UI_DIR — skipping"
    fi

    # Configure ~/.bashrc
    info "Configuring ~/.bashrc..."

    # Define marker block
    START_MARKER="# --- START ROS1-ANSCER-NATIVE ---"
    END_MARKER="# --- END ROS1-ANSCER-NATIVE ---"

    # Remove existing block if present (prevents duplicates on re-run)
    if grep -qF "$START_MARKER" "$HOME/.bashrc"; then
        sed -i "/$START_MARKER/,/$END_MARKER/d" "$HOME/.bashrc"
    fi

    cat >> "$HOME/.bashrc" <<BASHRC_EOF
$START_MARKER
# ROS Noetic
set +u
source /opt/ros/noetic/setup.bash

# Cartographer
if [ -f $CARTO_DIR/install_isolated/setup.bash ]; then
    source $CARTO_DIR/install_isolated/setup.bash
fi

# Workspace
if [ -f $WS_DIR/devel/setup.bash ]; then
    source $WS_DIR/devel/setup.bash
fi

# Node.js via nvm
export NVM_DIR="\$HOME/.config/nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"

# User local binaries (git-profile, uv, etc.)
export PATH="\$HOME/.local/bin:\$PATH"

# Neovim
export PATH="/opt/nvim-linux-x86_64/bin:\$PATH"

# Simulation aliases
alias 111='set +u; source $WS_DIR/devel/setup.bash; source $CONFIG_FILE; roscd start_anscer && roslaunch launch/start_anscer.launch'
alias 222='cd $WS_DIR && set +u && source devel/setup.bash && source $CONFIG_FILE && cd src/anscer_iui/mission_control_ui && npm run dev'

# Robot SSH + SSHFS Mount
function op() {
    local target="nvidia@192.168.1.3"
    if [ -n "\$1" ]; then
        if [[ "\$1" != *"@"* ]]; then
            target="nvidia@\$1"
        else
            target="\$1"
        fi
    fi

    local host_only="\${target#*@}"
    local mount_dir="\$HOME/robot_fs_\$host_only"
    local socket="/tmp/robot_sock_\$host_only"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

    local fuse_cmd="fusermount"
    command -v fusermount3 &>/dev/null && fuse_cmd="fusermount3"

    \$fuse_cmd -u "\$mount_dir" 2>/dev/null
    rm -f "\$socket"
    mkdir -p "\$mount_dir"

    echo "Connecting to \$target..."
    sshfs -o ControlMaster=yes -o ControlPath="\$socket" \$ssh_opts "\$target":/ "\$mount_dir"
    if [ \$? -ne 0 ]; then
        echo "Failed to connect to \$target."
        return 1
    fi

    sleep 1
    xdg-open "\$mount_dir" </dev/null &>/dev/null &

    echo "Filesystem mounted at \$mount_dir. Dropping into terminal..."
    ssh -o ControlPath="\$socket" \$ssh_opts "\$target"

    echo "Terminal closed. Cleaning up mount for \$host_only..."
    \$fuse_cmd -u "\$mount_dir" 2>/dev/null
    rm -f "\$socket"
}
$END_MARKER
BASHRC_EOF

    ok "~/.bashrc configured"
    mark_done "phase14"
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

export NVM_DIR="$HOME/.config/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
command -v node &>/dev/null && ok "Node.js $(node --version)" || { err "Node.js MISSING"; PASS=false; }

if ls "$HOME"/.ssh/id_* &>/dev/null || [[ -f "$HOME/.ssh/config" ]]; then
    ok "SSH keys/config detected"
else
    warn "No SSH keys — run ssh-manager.sh setup"
fi

[[ -x "$HOME/.local/bin/git-profile" ]] && ok "git-profile" || warn "git-profile not found"

if $PASS; then
    ok "All verifications passed"
else
    err "Some components missing — check above"
    exit 1
fi

# =============================================================================
# DONE
# =============================================================================
phase "ALL 14 PHASES COMPLETE"

cat <<EOF | tee -a "$LOG_FILE"

${GREEN}${BOLD}ROS1 Noetic + ANSCER simulation stack is ready.${NORMAL}

${BOLD}What's installed:${NORMAL}
  ✓ ROS Noetic desktop-full
  ✓ All apt packages (simulation scope)
  ✓ Source builds: libserial, gRPC, MongoDB drivers, Paho MQTT, Cartographer
  ✓ MongoDB server (running via systemd)
  ✓ Node.js ${NODE_VERSION}, Neovim + LazyVim
  ✓ Workspace cloned, CATKIN_IGNORE'd, config written, npm installed

${BOLD}${YELLOW}FINAL STEP — build the workspace:${NORMAL}

  source ~/.bashrc
  cd $WS_DIR
  catkin_make

${BOLD}Then run the simulation:${NORMAL}

  111                    # Terminal 1: ROS stack
  222                    # Terminal 2: Web UI
  Browser: http://localhost:5173

${BOLD}Robot SSH:${NORMAL}
  op                     # connect to default robot (nvidia@192.168.1.3)
  op 10.0.0.5            # connect to custom IP

${BOLD}Git identity:${NORMAL}
  git profile use <work|showcase>

EOF
