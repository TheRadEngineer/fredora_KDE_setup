#!/usr/bin/env bash
# =============================================================================
# 1-host-setup.sh  —  Fedora 44/45 KDE host bootstrap (robotics workstation)
# Target: ASUS ROG Strix SCAR 16 (i9-14900HX + RTX 4080). Hardware-aware:
# NVIDIA / ASUS stages skip themselves on other machines.
# Version: 5.0
#
# Stages:
#   1  System upgrade + RPM Fusion (+ reboot if kernel changed)
#   2  NVIDIA driver (akmod-nvidia-open + CUDA runtime)
#   3  ASUS ROG stack (asusctl, supergfxctl, Hybrid GPU)
#   4  SELinux logind/DRM policy module
#   5  Docker CE + Compose + Buildx (overlay2 store) + NVIDIA CDI for containers
#   6  CLI tools + fonts + Nerd Font
#   7  Steam + ProtonUp-Qt + MongoDB Compass
#
# Containers (ros1/ros2) live in /opt/ros-containers — see that repo's README.
#
# TWO-PHASE: stage 1/2 may reboot. Re-run the script; finished stages are skipped.
#
# USAGE:
#   ./1-host-setup.sh                 standard run
#   ./1-host-setup.sh --verbose       show all command output
#   ./1-host-setup.sh --skip-nvidia   skip NVIDIA driver + container GPU support
#   ./1-host-setup.sh --skip-asus     skip ASUS stack
#   ./1-host-setup.sh --reset-state   forget progress, start fresh
# =============================================================================

set -uo pipefail

CLI_PACKAGES=(
    git gh curl wget htop btop tree jq ripgrep unzip zip xz tar
)
FONT_PACKAGES=(
    jetbrains-mono-fonts-all fira-code-fonts google-noto-fonts-common
    google-noto-color-emoji-fonts fontawesome-6-free-fonts
)

LOG_FILE="${LOG_FILE:-$HOME/fedora-setup.log}"
STATE_DIR="$HOME/.fedora-setup-state"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP_DELAY="${STEP_DELAY:-1}"
BANNER_DELAY="${BANNER_DELAY:-2}"
MIN_FEDORA=44

SKIP_NVIDIA=false; SKIP_ASUS=false; VERBOSE=false; RESET_STATE=false
for arg in "$@"; do
    case "$arg" in
        --skip-nvidia) SKIP_NVIDIA=true ;;
        --skip-asus)   SKIP_ASUS=true ;;
        --verbose)     VERBOSE=true ;;
        --reset-state) RESET_STATE=true ;;
        --help|-h)     sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; NORMAL=$'\e[0m'
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'
else
    BOLD=""; DIM=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"
$RESET_STATE && { rm -f "$STATE_DIR"/*; echo "State reset."; }
: > "$LOG_FILE"

is_done()   { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done() { touch "$STATE_DIR/$1.done"; }

info()  { echo -e "${BLUE}${BOLD}[INFO]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}${BOLD}[ OK ]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}${BOLD}[WARN]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}${BOLD}[FAIL]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
skip()  { echo -e "${CYAN}${BOLD}[SKIP]${NORMAL}  $*" | tee -a "$LOG_FILE"; }

banner() {
    { echo
      echo -e "${BOLD}${BLUE}================================================================${NORMAL}"
      echo -e "${BOLD}${BLUE}  $1${NORMAL}"
      echo -e "${BOLD}${BLUE}================================================================${NORMAL}"; } | tee -a "$LOG_FILE"
    sleep "$BANNER_DELAY"
}
step() { echo | tee -a "$LOG_FILE"; echo -e "${BOLD}${CYAN}--> $*${NORMAL}" | tee -a "$LOG_FILE"; sleep "$STEP_DELAY"; }

run() {
    if $VERBOSE; then "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"
    else "$@" >> "$LOG_FILE" 2>&1; return $?; fi
}

has_nvidia() { lspci 2>/dev/null | grep -qi 'nvidia'; }

reboot_prompt() {
    read -r -p "Reboot now? [Y/n] " ans
    [[ "$ans" =~ ^[Nn]$ ]] && { info "Reboot manually, then re-run: cd $SCRIPT_DIR && ./$(basename "$0")"; exit 0; }
    info "Rebooting in 3s..."; sleep 3; sudo systemctl reboot; exit 0
}

# =============================================================================
preflight() {
    banner "PRE-FLIGHT CHECKS"

    step "Checking Fedora >= $MIN_FEDORA"
    local ver; ver=$(. /etc/os-release 2>/dev/null && [[ "${ID:-}" == "fedora" ]] && echo "${VERSION_ID:-0}" || echo 0)
    [[ "$ver" =~ ^[0-9]+$ && "$ver" -ge "$MIN_FEDORA" ]] || { err "Needs Fedora $MIN_FEDORA or newer (found: $ver)."; exit 1; }
    ok "Fedora $ver"

    step "Checking not root"
    [[ $EUID -ne 0 ]] || { err "Don't run as root."; exit 1; }
    ok "User: $USER"

    step "Checking sudo"
    sudo -v || { err "Need sudo."; exit 1; }
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT
    ok "Sudo kept alive"

    step "Checking network"
    curl -s --head --connect-timeout 5 https://fedoraproject.org >/dev/null || { err "No network."; exit 1; }
    ok "Network OK"

    if [[ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]]; then
        info "Resuming — finished: $(ls "$STATE_DIR" | sed 's/\.done//' | tr '\n' ' ')"
    else
        info "Fresh run"
    fi
}

# =============================================================================
stage_1_system_and_rpmfusion() {
    is_done "stage_1" && { banner "STAGE 1 — SYSTEM + RPM FUSION (done — skipping)"; return; }
    banner "STAGE 1 — SYSTEM UPGRADE + RPM FUSION"

    step "dnf: parallel downloads"
    grep -q "^max_parallel_downloads=" /etc/dnf/dnf.conf 2>/dev/null \
        && skip "already set" \
        || { echo "max_parallel_downloads=10" | sudo tee -a /etc/dnf/dnf.conf >/dev/null; ok "max_parallel_downloads=10"; }

    step "Full system upgrade"
    run sudo dnf upgrade --refresh -y && ok "Upgraded" || { err "Upgrade failed (see $LOG_FILE)"; exit 1; }

    step "RPM Fusion (free + nonfree)"
    if rpm -q rpmfusion-free-release &>/dev/null && rpm -q rpmfusion-nonfree-release &>/dev/null; then
        skip "already installed"
    else
        run sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
            && ok "Installed" || { err "RPM Fusion failed (is it published for Fedora $(rpm -E %fedora) yet?)"; exit 1; }
    fi

    step "Core group + appstream metadata"
    run sudo dnf group upgrade -y core || warn "Group upgrade nonzero (usually harmless)"

    step "Verifying RPM Fusion repos"
    dnf repolist 2>/dev/null | grep -qi rpmfusion && ok "Confirmed" || { err "RPM Fusion not visible"; exit 1; }

    mark_done "stage_1"

    step "Kernel check"
    local running newest
    running=$(uname -r)
    newest=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)
    info "Running: $running | Installed: $newest"
    if [[ "$running" != "$newest" ]]; then
        warn "Kernel mismatch — reboot needed before the NVIDIA driver build."
        reboot_prompt
    fi
    ok "Kernel matches"
}

# =============================================================================
stage_2_nvidia() {
    if $SKIP_NVIDIA; then banner "STAGE 2 — NVIDIA (SKIPPED)"; mark_done "stage_2"; return; fi
    is_done "stage_2" && { banner "STAGE 2 — NVIDIA (done — skipping)"; return; }
    banner "STAGE 2 — NVIDIA DRIVER (OPEN KERNEL MODULE)"

    step "Checking for NVIDIA GPU"
    has_nvidia || { warn "No NVIDIA GPU. Skipping."; mark_done "stage_2"; return; }
    ok "Found: $(lspci | grep -i nvidia | head -1)"

    step "Installing akmod-nvidia-open + CUDA runtime"
    if rpm -q akmod-nvidia-open &>/dev/null; then skip "already installed"
    else run sudo dnf install -y akmod-nvidia-open xorg-x11-drv-nvidia-cuda && ok "Installed" || { err "Install failed"; exit 1; }
    fi

    step "Waiting for kernel module build (up to 5 min)"
    local w=0 built=false
    while [[ $w -lt 300 ]]; do
        modinfo -F version nvidia &>/dev/null && { ok "Built: $(modinfo -F version nvidia)"; built=true; break; }
        sleep 10; w=$((w+10)); info "  ...${w}s / 300s"
    done
    if ! $built; then
        warn "Module still building in the background. Reboot to load it."
        mark_done "stage_2"
        reboot_prompt
    fi

    step "Secure Boot check"
    local sb; sb=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    info "Secure Boot: $sb"
    [[ "$sb" == *"enabled"* ]] && warn "MOK enrollment may be needed" || ok "No MOK needed"

    mark_done "stage_2"
}

# =============================================================================
stage_3_asus() {
    if $SKIP_ASUS; then banner "STAGE 3 — ASUS (SKIPPED)"; mark_done "stage_3"; return; fi
    is_done "stage_3" && { banner "STAGE 3 — ASUS (done — skipping)"; return; }
    banner "STAGE 3 — ASUS ROG HARDWARE STACK"

    step "Detecting ASUS hardware"
    grep -qi 'asus' /sys/class/dmi/id/board_vendor 2>/dev/null || { warn "Not ASUS. Skipping."; mark_done "stage_3"; return; }
    ok "Found: $(cat /sys/class/dmi/id/product_name 2>/dev/null)"

    step "Enabling asus-linux COPR"
    if dnf copr list --enabled 2>/dev/null | grep -q lukenukem/asus-linux; then skip "already enabled"
    else run sudo dnf copr enable -y lukenukem/asus-linux && ok "Enabled" \
        || { err "COPR enable failed (not published for this Fedora yet?). Skipping ASUS stage."; return; }
    fi

    step "Installing asusctl, ROG Control Center, supergfxctl"
    local pkgs=(asusctl asusctl-rog-gui supergfxctl) need=() p
    for p in "${pkgs[@]}"; do rpm -q "$p" &>/dev/null || need+=("$p"); done
    if [[ ${#need[@]} -eq 0 ]]; then skip "all installed"
    else run sudo dnf install -y "${need[@]}" && ok "Installed: ${need[*]}" \
        || { err "Install failed. Skipping ASUS stage."; return; }
    fi

    # asusd-user.service deliberately NOT created — crashes on this hardware
    step "Enabling supergfxd + asus-shutdown"
    run sudo systemctl daemon-reload
    local svc
    for svc in supergfxd.service asus-shutdown.service; do
        if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
            run sudo systemctl enable --now "$svc" && ok "Enabled $svc" || warn "Failed $svc"
        else skip "$svc not found"; fi
    done

    step "GPU mode: Hybrid"
    if command -v supergfxctl &>/dev/null; then
        local m; m=$(timeout 10 supergfxctl -g 2>/dev/null || echo "unknown")
        case "$m" in
            Hybrid)  skip "already Hybrid" ;;
            unknown) warn "supergfxctl not responding — set after reboot: sudo supergfxctl -m Hybrid" ;;
            *)       run sudo supergfxctl -m Hybrid && ok "Hybrid requested" || warn "May need reboot" ;;
        esac
    fi

    step "Reloading udev"
    run sudo udevadm control --reload; run sudo udevadm trigger; ok "Done"
    mark_done "stage_3"
}

# =============================================================================
stage_4_selinux() {
    is_done "stage_4" && { banner "STAGE 4 — SELINUX (done — skipping)"; return; }
    banner "STAGE 4 — SELINUX POLICY"

    step "SELinux tooling"
    command -v checkmodule &>/dev/null && skip "present" \
        || run sudo dnf install -y policycoreutils-python-utils checkpolicy || warn "Failed"

    step "logind/DRM policy module"
    if sudo semodule -l | grep -q "^my-systemdlogind$"; then
        skip "already loaded"
    else
        local d; d="$(mktemp -d)"
        cat > "$d/my-systemdlogind.te" <<'POLICY'
module my-systemdlogind 1.0;
require {
    type xserver_misc_device_t;
    type systemd_logind_t;
    class chr_file { read write };
}
allow systemd_logind_t xserver_misc_device_t:chr_file { read write };
POLICY
        ( cd "$d" \
          && run checkmodule -M -m -o my-systemdlogind.mod my-systemdlogind.te \
          && run semodule_package -o my-systemdlogind.pp -m my-systemdlogind.mod \
          && run sudo semodule -X 300 -i my-systemdlogind.pp ) \
            && ok "Installed at priority 300" || warn "Failed"
        rm -rf "$d"
    fi
    mark_done "stage_4"
}

# =============================================================================
# STAGE 5 — Docker. Matches the ros-containers README ("Host setup"):
#   * overlay2 store (containerd-snapshotter OFF) — much faster commits
#   * NVIDIA via CDI (nvidia-ctk cdi generate), not the legacy runtime hook
# =============================================================================
stage_5_docker() {
    is_done "docker" && { banner "STAGE 5 — DOCKER (done — skipping)"; return; }
    banner "STAGE 5 — DOCKER + COMPOSE + NVIDIA CDI"

    step "Docker CE repo"
    if [[ -f /etc/yum.repos.d/docker-ce.repo ]]; then skip "already configured"
    else
        run sudo dnf install -y dnf-plugins-core
        run sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
            && ok "Added" || { err "Could not add Docker repo"; return; }
    fi

    step "Docker CE + Compose + Buildx"
    if rpm -q docker-ce &>/dev/null; then skip "already installed"
    else
        run sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
            && ok "Installed" \
            || { err "Install failed — Docker may not publish packages for Fedora $(rpm -E %fedora) yet (see $LOG_FILE)"; return; }
    fi

    step "Storage driver: classic overlay2 (containerd-snapshotter off)"
    local dj=/etc/docker/daemon.json
    command -v jq &>/dev/null || run sudo dnf install -y jq
    sudo mkdir -p /etc/docker
    [[ -f "$dj" ]] || echo '{}' | sudo tee "$dj" >/dev/null
    if sudo jq -e '.features["containerd-snapshotter"] == false' "$dj" &>/dev/null; then
        skip "already set"
    else
        sudo jq '.features = ((.features // {}) + {"containerd-snapshotter": false})' "$dj" \
            | sudo tee "$dj.new" >/dev/null \
            && sudo mv "$dj.new" "$dj" && ok "daemon.json updated" \
            || { err "Could not update $dj"; sudo rm -f "$dj.new"; }
        sudo systemctl is-active --quiet docker && run sudo systemctl restart docker
    fi

    step "Enable Docker"
    run sudo systemctl enable --now docker && ok "Running" || warn "Failed to start docker"
    info "Storage driver: $(sudo docker info --format '{{.Driver}}' 2>/dev/null || echo unknown) (want overlay2)"

    step "Add $USER to docker group"
    if id -nG "$USER" | grep -qw docker; then skip "already in group"
    else run sudo usermod -aG docker "$USER"; warn "Log out/in (or reboot) for the group to apply"; fi

    # ---- NVIDIA for containers (only on NVIDIA machines) ----
    if $SKIP_NVIDIA || ! has_nvidia; then
        skip "No NVIDIA GPU (or --skip-nvidia): skipping NVIDIA Container Toolkit"
        info "Remove ':compose.nvidia.yaml' from COMPOSE_FILE in the ros .env files on this machine"
    else
        step "NVIDIA Container Toolkit repo"
        if [[ -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]]; then skip "already configured"
        else
            curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
                | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null \
                && ok "Added" || warn "Failed"
        fi

        step "NVIDIA Container Toolkit"
        if rpm -q nvidia-container-toolkit &>/dev/null; then skip "already installed"
        else run sudo dnf install -y nvidia-container-toolkit && ok "Installed" || warn "Failed"; fi

        step "CDI spec (/etc/cdi/nvidia.yaml)"
        if command -v nvidia-ctk &>/dev/null; then
            if nvidia-smi &>/dev/null; then
                sudo mkdir -p /etc/cdi
                run sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml \
                    && ok "Generated: $(nvidia-ctk cdi list 2>/dev/null | head -1)" || warn "CDI generate failed"
            else
                warn "NVIDIA driver not loaded yet (reboot first). After reboot run:"
                warn "  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
            fi
            if systemctl list-unit-files 2>/dev/null | grep -q '^nvidia-cdi-refresh'; then
                run sudo systemctl enable nvidia-cdi-refresh.path nvidia-cdi-refresh.service \
                    && ok "nvidia-cdi-refresh enabled (regenerates after driver updates)" \
                    || warn "Could not enable nvidia-cdi-refresh"
            else
                warn "No nvidia-cdi-refresh unit: re-run 'sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' after EVERY NVIDIA driver update"
            fi
        fi
    fi

    step "Host avahi (mDNS) for robot.local names inside containers"
    systemctl is-active --quiet avahi-daemon && ok "avahi-daemon running" \
        || { run sudo dnf install -y avahi && run sudo systemctl enable --now avahi-daemon && ok "avahi enabled" || warn "avahi not running"; }

    mark_done "docker"
}

# =============================================================================
stage_6_cli_baseline() {
    is_done "cli" && { banner "STAGE 6 — CLI + FONTS (done — skipping)"; return; }
    banner "STAGE 6 — CLI TOOLS + FONTS"

    step "CLI tools"
    run sudo dnf install -y "${CLI_PACKAGES[@]}" && ok "Installed" || warn "Partial failure"

    step "Programming fonts"
    run sudo dnf install -y "${FONT_PACKAGES[@]}" && ok "Installed" || warn "Partial failure"

    step "JetBrainsMono Nerd Font (icons in Konsole/LazyVim — fonts must live on the host)"
    local dir="$HOME/.local/share/fonts/NerdFonts"
    if ls "$dir"/*.ttf &>/dev/null; then skip "already installed"
    else
        mkdir -p "$dir"
        local tmp; tmp="$(mktemp -d)"
        curl -fL -o "$tmp/jb.tar.xz" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz" \
            && tar -xf "$tmp/jb.tar.xz" -C "$dir" && fc-cache -f "$dir" \
            && ok "Installed — set Konsole font to 'JetBrainsMono Nerd Font'" \
            || warn "Failed — get it from https://www.nerdfonts.com"
        rm -rf "$tmp"
    fi
    mark_done "cli"
}

# =============================================================================
stage_7_extras() {
    is_done "extras" && { banner "STAGE 7 — STEAM + EXTRAS (done — skipping)"; return; }
    banner "STAGE 7 — STEAM + PROTONUP-QT + MONGODB COMPASS"

    step "Steam"
    rpm -q steam &>/dev/null && skip "already installed" || { run sudo dnf install -y steam && ok "Installed" || warn "Failed"; }

    step "steam-devices (controller udev rules)"
    rpm -q steam-devices &>/dev/null && skip "already installed" || { run sudo dnf install -y steam-devices && ok "Installed" || warn "Failed"; }

    step "Flathub (user)"
    if flatpak --user remotes --columns=name 2>/dev/null | grep -qx flathub; then skip "already configured"
    else run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo && ok "Added" || warn "Failed"; fi

    step "ProtonUp-Qt"
    if flatpak info --user net.davidotek.pupgui2 &>/dev/null || flatpak info net.davidotek.pupgui2 &>/dev/null; then skip "already installed"
    else run flatpak install --user -y --noninteractive flathub net.davidotek.pupgui2 && ok "Installed" || warn "Failed"; fi

    step "MongoDB Compass"
    rpm -q mongodb-compass &>/dev/null && skip "already installed" \
        || { run sudo dnf install -y https://downloads.mongodb.com/compass/mongodb-compass-1.49.8.x86_64.rpm && ok "Installed" || warn "Failed"; }

    mark_done "extras"
}

# =============================================================================
finalize() {
    banner "SETUP COMPLETE"
    cat <<MSG | tee -a "$LOG_FILE"
${GREEN}${BOLD}Host setup finished.${NORMAL}  Log: $LOG_FILE   State: $STATE_DIR

${BOLD}Next (ROS containers):${NORMAL}
  sudo mkdir -p /opt/ros-containers && sudo chown "\$USER:\$USER" /opt/ros-containers
  # put the repo there, then for each of ros1 / ros2:
  cd /opt/ros-containers/ros1 && ./install.sh --enable && ./build.sh

${YELLOW}${BOLD}REBOOT required to:${NORMAL}
  - Activate the docker group for $USER
  - Load the NVIDIA module / apply Hybrid GPU mode
  After reboot, if the CDI spec was not generated:
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
MSG
    reboot_prompt
}

main() {
    banner "FEDORA ${MIN_FEDORA}+ KDE — HOST BOOTSTRAP v5.0"
    info "Verbose: $VERBOSE | Skip NVIDIA: $SKIP_NVIDIA | Skip ASUS: $SKIP_ASUS"
    preflight
    stage_1_system_and_rpmfusion
    stage_2_nvidia
    stage_3_asus
    stage_4_selinux
    stage_5_docker
    stage_6_cli_baseline
    stage_7_extras
    finalize
}

main
