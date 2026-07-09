#!/usr/bin/env bash
# =============================================================================
# 00-host-setup.sh  —  Fedora 44 KDE Post-Install Bootstrap
# Target: ASUS ROG Strix SCAR 16 G634JZR (i9-14900HX + RTX 4080 Laptop)
# Version: 3.0
#
# TWO-PHASE EXECUTION:
#   Run 1: Stages 1 upgrades kernel → detects mismatch → reboots.
#   Run 2: Script resumes from Stage 2 onward (state tracked in ~/.fedora-setup-state).
#
# USAGE:
#   ./00-host-setup.sh                   # standard run
#   ./00-host-setup.sh --verbose         # show all command output live
#   ./00-host-setup.sh --skip-nvidia     # skip NVIDIA driver install
#   ./00-host-setup.sh --skip-asus       # skip ASUS ROG stack
#   ./00-host-setup.sh --reset-state     # clear state, force fresh run
#
# See README.md for full documentation.
# =============================================================================

set -uo pipefail

# =============================================================================
# CONFIGURATION — EDIT THESE LISTS TO ADD/REMOVE PACKAGES
# =============================================================================

# ---- CLI tools (installed via dnf) ----
# Add or remove tools here. One package name per line. Comments are ignored.
CLI_PACKAGES=(
    git                     # version control
    gh                      # GitHub CLI
    curl                    # HTTP client
    wget                    # file downloader
    htop                    # process monitor (classic)
    btop                    # process monitor (modern)
    tree                    # directory tree viewer
    jq                      # JSON parser (industry standard)
    ripgrep                 # fast recursive grep
    unzip                   # .zip extraction
    zip                     # .zip creation
    xz                      # .xz compression
    tar                     # archive tool
)

# ---- Programming fonts (installed via dnf) ----
FONT_PACKAGES=(
    jetbrains-mono-fonts-all
    fira-code-fonts
    google-noto-fonts-common
    google-noto-color-emoji-fonts         # emoji support
    fontawesome-6-free-fonts              # FontAwesome icons
)

# Nerd Fonts are required for LazyVim icons in Konsole.
# They are not in Fedora repos — installed separately in Stage 8.

# =============================================================================
# INTERNAL CONFIGURATION — usually no need to edit below this line
# =============================================================================

LOG_FILE="${LOG_FILE:-$HOME/fedora-setup.log}"
STATE_DIR="$HOME/.fedora-setup-state"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALLPAPER_SOURCE="${SCRIPT_DIR}/wallpaper.jpg"
STEP_DELAY="${STEP_DELAY:-1}"
BANNER_DELAY="${BANNER_DELAY:-2}"

SKIP_NVIDIA=false
SKIP_ASUS=false
VERBOSE=false
RESET_STATE=false
REPLACE_FIREFOX=false

for arg in "$@"; do
    case "$arg" in
        --skip-nvidia)  SKIP_NVIDIA=true ;;
        --skip-asus)    SKIP_ASUS=true ;;
        --verbose)      VERBOSE=true ;;
        --reset-state)  RESET_STATE=true ;;
        --help|-h)
            grep -E '^# ' "$0" | head -20
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; NORMAL=$'\e[0m'
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'
else
    BOLD=""; DIM=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$STATE_DIR"
if $RESET_STATE; then rm -f "$STATE_DIR"/*; echo "State reset."; fi
: > "$LOG_FILE"

is_done()   { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done() { touch "$STATE_DIR/$1.done"; }

log()   { echo -e "${DIM}[$(date +%H:%M:%S)]${NORMAL} $*" | tee -a "$LOG_FILE" ; }
info()  { echo -e "${BLUE}${BOLD}[INFO]${NORMAL}  $*" | tee -a "$LOG_FILE" ; }
ok()    { echo -e "${GREEN}${BOLD}[ OK ]${NORMAL}  $*" | tee -a "$LOG_FILE" ; }
warn()  { echo -e "${YELLOW}${BOLD}[WARN]${NORMAL}  $*" | tee -a "$LOG_FILE" ; }
err()   { echo -e "${RED}${BOLD}[FAIL]${NORMAL}  $*" | tee -a "$LOG_FILE" ; }
skip()  { echo -e "${CYAN}${BOLD}[SKIP]${NORMAL}  $*" | tee -a "$LOG_FILE" ; }

banner() {
    echo | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}================================================================${NORMAL}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}  $1${NORMAL}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}================================================================${NORMAL}" | tee -a "$LOG_FILE"
    sleep "$BANNER_DELAY"
}

step() {
    echo | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}--> $*${NORMAL}" | tee -a "$LOG_FILE"
    sleep "$STEP_DELAY"
}

run() {
    if $VERBOSE; then
        "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"
    else
        "$@" >> "$LOG_FILE" 2>&1; return $?
    fi
}

# =============================================================================
# PRE-FLIGHT
# =============================================================================
preflight() {
    banner "PRE-FLIGHT CHECKS"

    step "Checking Fedora 44"
    grep -q "Fedora Linux 44" /etc/os-release 2>/dev/null || { err "Not Fedora 44."; exit 1; }
    ok "Fedora 44 confirmed"

    step "Checking not root"
    [[ $EUID -ne 0 ]] || { err "Don't run as root."; exit 1; }
    ok "Running as user: $USER"

    step "Checking sudo access"
    sudo -v || { err "Need sudo."; exit 1; }
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT
    ok "Sudo kept alive"

    step "Checking network"
    curl -s --head --connect-timeout 5 https://fedoraproject.org >/dev/null || { err "No network."; exit 1; }
    ok "Network OK"

    step "Log: $LOG_FILE | State: $STATE_DIR"
    if [[ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]]; then
        info "Resuming — found state files: $(ls "$STATE_DIR" | tr '\n' ' ')"
    else
        info "Fresh run"
    fi

    step "Browser preference"
    if ! is_done "stage_5"; then
        read -r -p "Replace Firefox with Zen browser? [y/N] " browser_choice
        [[ "$browser_choice" =~ ^[Yy]$ ]] && REPLACE_FIREFOX=true
    fi
}

# =============================================================================
# STAGE 1 — System upgrade + RPM Fusion + kernel reboot
# =============================================================================
stage_1_system_and_rpmfusion() {
    if is_done "stage_1"; then
        banner "STAGE 1 — SYSTEM + RPM FUSION (done — skipping)"
        return
    fi

    banner "STAGE 1 — SYSTEM UPGRADE + RPM FUSION"

    step "Configuring dnf for faster mirrors and parallel downloads"
    grep -q "^fastestmirror=True" /etc/dnf/dnf.conf 2>/dev/null \
        && skip "fastestmirror already set" \
        || { echo "fastestmirror=True" | sudo tee -a /etc/dnf/dnf.conf >/dev/null; ok "Enabled fastestmirror"; }
    grep -q "^max_parallel_downloads=" /etc/dnf/dnf.conf 2>/dev/null \
        && skip "max_parallel_downloads already set" \
        || { echo "max_parallel_downloads=10" | sudo tee -a /etc/dnf/dnf.conf >/dev/null; ok "Set max_parallel_downloads=10"; }

    step "Full system upgrade"
    run sudo dnf upgrade --refresh -y && ok "Upgraded" || { err "Upgrade failed"; exit 1; }

    step "Installing RPM Fusion (free + nonfree)"
    if rpm -q rpmfusion-free-release &>/dev/null && rpm -q rpmfusion-nonfree-release &>/dev/null; then
        skip "RPM Fusion already installed"
    else
        run sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
            && ok "RPM Fusion installed" || { err "RPM Fusion failed"; exit 1; }
    fi

    step "Core group + appstream metadata"
    run sudo dnf group upgrade -y core || warn "Group upgrade nonzero (usually harmless)"
    ok "Done"

    step "Verifying RPM Fusion repos"
    dnf repolist 2>/dev/null | grep -qi rpmfusion && ok "Confirmed" || { err "RPM Fusion not visible"; exit 1; }

    mark_done "stage_1"

    # ---- Kernel reboot detection ----
    step "Checking kernel version"
    local running newest
    running=$(uname -r)
    newest=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)
    info "Running: $running | Installed: $newest"

    if [[ "$running" != "$newest" ]]; then
        warn "==============================================================="
        warn " KERNEL MISMATCH — reboot needed before NVIDIA install"
        warn " After reboot, re-run: cd $SCRIPT_DIR && ./$(basename "$0")"
        warn "==============================================================="
        read -r -p "Reboot now? [Y/n] " ans
        [[ "$ans" =~ ^[Nn]$ ]] && { err "Cannot continue. Reboot manually."; exit 1; }
        info "Rebooting in 3 seconds..."
        sleep 3
        sudo systemctl reboot
        exit 0
    fi
    ok "Kernel matches — continuing"
}

# =============================================================================
# STAGE 2 — NVIDIA
# =============================================================================
stage_2_nvidia() {
    if $SKIP_NVIDIA; then banner "STAGE 2 — NVIDIA (SKIPPED)"; mark_done "stage_2"; return; fi
    if is_done "stage_2"; then banner "STAGE 2 — NVIDIA (done — skipping)"; return; fi

    banner "STAGE 2 — NVIDIA DRIVER (OPEN KERNEL MODULE)"

    step "Checking for NVIDIA GPU"
    lspci | grep -qi 'nvidia' || { warn "No NVIDIA GPU. Skipping."; mark_done "stage_2"; return; }
    ok "Found: $(lspci | grep -i nvidia | head -1)"

    step "Installing akmod-nvidia-open + CUDA runtime"
    if rpm -q akmod-nvidia-open &>/dev/null; then
        skip "Already installed"
    else
        run sudo dnf install -y akmod-nvidia-open xorg-x11-drv-nvidia-cuda \
            && ok "Installed" || { err "Install failed"; exit 1; }
    fi

    step "Waiting for kernel module build (up to 5 min)"
    local w=0
    while [[ $w -lt 300 ]]; do
        modinfo -F version nvidia &>/dev/null && { ok "Built: $(modinfo -F version nvidia)"; break; }
        sleep 10; w=$((w+10)); info "  ...${w}s / 300s"
    done
    if [[ $w -ge 300 ]]; then
        warn "Timeout waiting for akmod. This is normal on first install."
        warn "The module will finish building in the background."
        mark_done "stage_2"
        warn "==============================================================="
        warn " REBOOT NOW — the NVIDIA module needs a reboot to load."
        warn " After reboot, re-run: cd $SCRIPT_DIR && ./$(basename "$0")"
        warn "==============================================================="
        read -r -p "Reboot now? [Y/n] " ans
        [[ "$ans" =~ ^[Nn]$ ]] && { info "Reboot manually when ready."; exit 0; }
        info "Rebooting in 3s..."; sleep 3; sudo systemctl reboot; exit 0
    fi

    step "Secure Boot check"
    local sb; sb=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    info "Secure Boot: $sb"
    [[ "$sb" == *"enabled"* ]] && warn "MOK enrollment may be needed" || ok "Disabled — no MOK needed"

    mark_done "stage_2"
}

# =============================================================================
# STAGE 3 — ASUS ROG
# =============================================================================
stage_3_asus() {
    if $SKIP_ASUS; then banner "STAGE 3 — ASUS (SKIPPED)"; mark_done "stage_3"; return; fi
    if is_done "stage_3"; then banner "STAGE 3 — ASUS (done — skipping)"; return; fi

    banner "STAGE 3 — ASUS ROG HARDWARE STACK"

    step "Detecting ASUS hardware"
    grep -qi 'asus' /sys/class/dmi/id/board_vendor 2>/dev/null \
        || { warn "Not ASUS. Skipping."; mark_done "stage_3"; return; }
    ok "Found: $(cat /sys/class/dmi/id/product_name 2>/dev/null)"

    step "Enabling asus-linux COPR"
    dnf copr list --enabled 2>/dev/null | grep -q lukenukem/asus-linux \
        && skip "Already enabled" \
        || { run sudo dnf copr enable -y lukenukem/asus-linux && ok "Enabled" || err "Failed"; }

    step "Installing asusctl, ROG Control Center, supergfxctl"
    local pkgs=(asusctl asusctl-rog-gui supergfxctl) need=()
    for p in "${pkgs[@]}"; do rpm -q "$p" &>/dev/null || need+=("$p"); done
    [[ ${#need[@]} -eq 0 ]] && skip "All installed" \
        || { run sudo dnf install -y "${need[@]}" && ok "Installed: ${need[*]}" || err "Failed"; }

    # NOTE: asusd-user.service deliberately NOT created — crashes on this hardware
    step "Enabling supergfxd + asus-shutdown"
    run sudo systemctl daemon-reload
    for svc in supergfxd.service asus-shutdown.service; do
        systemctl list-unit-files "$svc" &>/dev/null \
            && { run sudo systemctl enable --now "$svc" && ok "Enabled $svc" || warn "Failed $svc"; } \
            || skip "$svc not found"
    done

    step "Setting GPU to Hybrid mode"
        if command -v supergfxctl &>/dev/null; then
            local m; m=$(timeout 10 supergfxctl -g 2>/dev/null || echo "unknown")
            if [[ "$m" == "Hybrid" ]]; then
                skip "Already Hybrid"
            elif [[ "$m" == "unknown" ]]; then
                warn "supergfxctl not responding — will be configured after reboot"
            else
                run sudo supergfxctl -m Hybrid && ok "Hybrid requested" || warn "May need reboot"
            fi
        fi

    step "Reloading udev"
    run sudo udevadm control --reload; run sudo udevadm trigger; ok "Done"

    mark_done "stage_3"
}

# =============================================================================
# STAGE 4 — SELinux
# =============================================================================
stage_4_selinux() {
    if is_done "stage_4"; then banner "STAGE 4 — SELINUX (done — skipping)"; return; fi

    banner "STAGE 4 — SELINUX POLICY"

    step "Installing SELinux tooling"
    command -v audit2allow &>/dev/null && skip "Present" \
        || { run sudo dnf install -y policycoreutils-python-utils checkpolicy || warn "Failed"; }

    step "Installing logind/DRM policy module"
    if sudo semodule -l | grep -q "^my-systemdlogind$"; then
        skip "Already loaded"
    else
        local d="/tmp/fedora-setup-selinux"; mkdir -p "$d"
        cat > "$d/my-systemdlogind.te" <<'POLICY'
module my-systemdlogind 1.0;
require {
    type xserver_misc_device_t;
    type systemd_logind_t;
    class chr_file { read write };
}
allow systemd_logind_t xserver_misc_device_t:chr_file { read write };
POLICY
        pushd "$d" >/dev/null
        run checkmodule -M -m -o my-systemdlogind.mod my-systemdlogind.te \
            && run semodule_package -o my-systemdlogind.pp -m my-systemdlogind.mod \
            && run sudo semodule -X 300 -i my-systemdlogind.pp \
            && ok "Installed at priority 300" || warn "Failed"
        popd >/dev/null
    fi

    mark_done "stage_4"
}

# =============================================================================
# STAGE 5 — Browser
# =============================================================================
stage_5_browser() {
    if is_done "stage_5"; then banner "STAGE 5 — BROWSER (done — skipping)"; return; fi
    if ! $REPLACE_FIREFOX; then banner "STAGE 5 — BROWSER (keeping Firefox)"; mark_done "stage_5"; return; fi

    banner "STAGE 5 — REPLACE FIREFOX WITH ZEN"

    step "Enabling Flathub (user scope)"
    flatpak --user remotes 2>/dev/null | grep -q flathub \
        && skip "Already configured" \
        || { run flatpak remote-add --user --if-not-exists flathub \
                https://dl.flathub.org/repo/flathub.flatpakrepo \
            && ok "Added (user)" \
            || { run sudo flatpak remote-add --if-not-exists flathub \
                    https://dl.flathub.org/repo/flathub.flatpakrepo \
                && ok "Added (system)" || warn "Both failed"; }; }

    step "Removing Firefox"
    rpm -q firefox &>/dev/null \
        && { run sudo dnf remove -y firefox && ok "Removed" || warn "Failed"; } \
        || skip "Not installed"

    step "Installing Zen browser (user Flatpak)"
    if flatpak --user list --app 2>/dev/null | grep -q "app.zen_browser.zen" \
        || flatpak list --app 2>/dev/null | grep -q "app.zen_browser.zen"; then
        skip "Already installed"
    else
        run flatpak install --user -y --noninteractive flathub app.zen_browser.zen \
            && ok "Installed" || warn "Failed — install manually"
    fi

    step "Setting Zen as default browser"
    sleep 2
    run xdg-settings set default-web-browser app.zen_browser.zen.desktop \
        && ok "Set as default" || warn "Set manually via KDE Settings > Default Applications"

    mark_done "stage_5"
}

# =============================================================================
# STAGE 6 — Containers
# =============================================================================
stage_6_containers() {
    if is_done "stage_6"; then banner "STAGE 6 — CONTAINERS (done — skipping)"; return; fi

    banner "STAGE 6 — DOCKER + NVIDIA CONTAINER TOOLKIT + DISTROBOX"

    step "Adding Docker CE repo"
    [[ -f /etc/yum.repos.d/docker-ce.repo ]] && skip "Already configured" || {
        run sudo dnf install -y dnf-plugins-core
        run sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
            && ok "Added" || { err "Failed"; return; }
    }

    step "Installing Docker CE + Compose + Buildx"
    rpm -q docker-ce &>/dev/null && skip "Already installed" || {
        run sudo dnf install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin \
            && ok "Installed" || { err "Failed"; return; }
    }

    step "Enabling Docker"
    run sudo systemctl enable --now docker && ok "Running" || warn "Failed"

    step "Adding $USER to docker group"
    id -nG "$USER" | grep -qw docker && skip "Already in group" || {
        run sudo usermod -aG docker "$USER"
        warn "Reboot needed for group membership"
    }

    step "Adding NVIDIA Container Toolkit repo"
    [[ -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]] && skip "Already configured" || {
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
            | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null \
            && ok "Added" || warn "Failed"
    }

    step "Installing NVIDIA Container Toolkit"
    rpm -q nvidia-container-toolkit &>/dev/null && skip "Already installed" || {
        run sudo dnf install -y nvidia-container-toolkit && ok "Installed" || warn "Failed"
    }

    step "Configuring Docker NVIDIA runtime"
    if command -v nvidia-ctk &>/dev/null; then
        run sudo nvidia-ctk runtime configure --runtime=docker \
            && run sudo systemctl restart docker \
            && ok "Configured" || warn "Failed"
    fi

    step "Installing Podman + Distrobox"
    rpm -q distrobox &>/dev/null && skip "Already installed" || {
        run sudo dnf install -y distrobox podman && ok "Installed" || warn "Failed"
    }

    mark_done "stage_6"
}

# =============================================================================
# STAGE 7 — Snapper
# =============================================================================
stage_7_snapshots() {
    if is_done "stage_7"; then banner "STAGE 7 — SNAPPER (done — skipping)"; return; fi

    banner "STAGE 7 — BTRFS SNAPSHOTS (Snapper)"

    step "Checking filesystem"
    local fs; fs=$(findmnt -no FSTYPE /)
    [[ "$fs" == "btrfs" ]] && ok "Root is btrfs" || { warn "Not btrfs. Skipping."; mark_done "stage_7"; return; }

    step "Installing snapper + dnf plugin"
    rpm -q snapper &>/dev/null && skip "Already installed" || {
        run sudo dnf install -y snapper python3-dnf-plugin-snapper && ok "Installed" || warn "Failed"
    }

    step "Creating root config"
    sudo snapper -c root list &>/dev/null && skip "Already exists" || {
        run sudo snapper -c root create-config / && ok "Created" || { warn "Failed"; mark_done "stage_7"; return; }
    }

    step "Configuring policy (pre/post only, keep 5 pairs)"
    sudo snapper -c root set-config TIMELINE_CREATE="no"
    sudo snapper -c root set-config NUMBER_CLEANUP="yes"
    sudo snapper -c root set-config NUMBER_LIMIT="10"
    sudo snapper -c root set-config NUMBER_LIMIT_IMPORTANT="5"
    sudo snapper -c root set-config NUMBER_MIN_AGE="1800"
    sudo snapper -c root set-config EMPTY_PRE_POST_CLEANUP="yes"
    ok "Policy set"

    step "Disabling timeline timer"
    run sudo systemctl disable --now snapper-timeline.timer 2>/dev/null || true; ok "Done"

    step "Enabling cleanup timer"
    run sudo systemctl enable --now snapper-cleanup.timer && ok "Enabled" || warn "Failed"

    mark_done "stage_7"
}

# =============================================================================
# STAGE 8 — CLI baseline + fonts + Node
# =============================================================================
stage_8_cli_baseline() {
    if is_done "stage_8"; then banner "STAGE 8 — CLI (done — skipping)"; return; fi

    banner "STAGE 8 — CLI BASELINE + FONTS + NODE.JS"

    step "Installing CLI tools"
    run sudo dnf install -y "${CLI_PACKAGES[@]}" && ok "Installed" || warn "Partial failure"

    step "Installing programming fonts"
    run sudo dnf install -y "${FONT_PACKAGES[@]}" && ok "Installed" || warn "Partial failure"

    step "Installing JetBrainsMono Nerd Font (required for LazyVim icons in Konsole)"
    local NERD_FONT_DIR="$HOME/.local/share/fonts/NerdFonts"
    if [[ -d "$NERD_FONT_DIR" ]] && ls "$NERD_FONT_DIR"/*.ttf &>/dev/null 2>&1; then
        skip "Already installed"
    else
        mkdir -p "$NERD_FONT_DIR"
        local NF_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz"
        curl -Lo /tmp/JetBrainsMono.tar.xz "$NF_URL" \
            && tar -xf /tmp/JetBrainsMono.tar.xz -C "$NERD_FONT_DIR" \
            && fc-cache -fv "$NERD_FONT_DIR" \
            && rm -f /tmp/JetBrainsMono.tar.xz \
            && ok "JetBrainsMono Nerd Font installed" \
            || warn "Failed — install manually from https://www.nerdfonts.com"
        info "Set Konsole font to 'JetBrainsMono Nerd Font' for LazyVim icons"
    fi

    step "Installing Node.js + npm"
    command -v node &>/dev/null && skip "Already installed ($(node --version))" || {
        run sudo dnf install -y nodejs npm && ok "Installed" || warn "Failed"
    }

    mark_done "stage_8"
}

# =============================================================================
# STAGE 9 — Zed Editor
# =============================================================================
stage_9_zed() {
    if is_done "stage_9"; then banner "STAGE 9 — ZED (done — skipping)"; return; fi

    banner "STAGE 9 — ZED EDITOR"

    step "Installing Zed"
    if command -v zed &>/dev/null || [[ -x "$HOME/.local/bin/zed" ]]; then
        skip "Already installed"
    else
        run bash -c 'curl -f https://zed.dev/install.sh | sh' \
            && ok "Installed" || warn "Failed — install manually: curl -f https://zed.dev/install.sh | sh"
    fi

    info "AI integration: Open Zed → AI panel (Ctrl+?) → add Anthropic API key"
    mark_done "stage_9"
}


# =============================================================================
# STAGE 10 — Steam
# =============================================================================
stage_10_steam() {
    if is_done "stage_10"; then banner "STAGE 10 — STEAM (done — skipping)"; return; fi

    banner "STAGE 10 — STEAM + CONTROLLER + PROTONUP-QT"

    step "Installing Steam"
    rpm -q steam &>/dev/null && skip "Already installed" || {
        run sudo dnf install -y steam && ok "Installed" || warn "Failed"
    }

    step "Installing steam-devices (controller udev rules)"
    rpm -q steam-devices &>/dev/null && skip "Already installed" || {
        run sudo dnf install -y steam-devices && ok "Installed" || warn "Failed"
    }

    step "Ensuring Flathub remote (user scope)"

    if flatpak --user remotes --columns=name 2>/dev/null | grep -qx flathub; then
        skip "Flathub already configured (user)"
    else
        run flatpak remote-add --user --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo \
            && ok "Flathub added (user)" \
            || warn "Failed to add Flathub"
    fi

    step "Installing ProtonUp-Qt (user Flatpak)"

    if flatpak info --user net.davidotek.pupgui2 >/dev/null 2>&1 \
        || flatpak info net.davidotek.pupgui2 >/dev/null 2>&1; then
        skip "Already installed"
    else
        run flatpak install --user -y --noninteractive flathub net.davidotek.pupgui2 \
            && ok "Installed" \
            || warn "Failed"
    fi

    step "Installing MongoDB Compass"
    rpm -q mongodb-compass &>/dev/null && skip "Already installed" || {
        run sudo dnf install -y https://downloads.mongodb.com/compass/mongodb-compass-1.49.8.x86_64.rpm \
            && ok "Installed" || warn "Failed"
    }

    mark_done "stage_10"
}

# =============================================================================
# STAGE 11 — Git config
# =============================================================================
stage_11_git_config() {
    if is_done "stage_11"; then banner "STAGE 11 — GIT (done — skipping)"; return; fi

    banner "STAGE 11 — GIT CONFIGURATION"

    step "Setting up primary identity"
    local name email
    name=$(git config --global user.name 2>/dev/null || echo "")
    email=$(git config --global user.email 2>/dev/null || echo "")

    if [[ -n "$name" && -n "$email" ]]; then
        info "Already configured: $name <$email>"
        read -r -p "Overwrite? [y/N] " ow
        [[ "$ow" =~ ^[Yy]$ ]] || { skip "Kept existing"; mark_done "stage_11"; return; }
    fi

    read -r -p "Git user.name: " name
    read -r -p "Git user.email: " email
    [[ -z "$name" || -z "$email" ]] && { warn "Empty — skipping"; mark_done "stage_11"; return; }

    git config --global user.name "$name"
    git config --global user.email "$email"
    git config --global init.defaultBranch main
    git config --global pull.rebase false
    ok "Configured: $name <$email>"

    mark_done "stage_11"
}

# =============================================================================
# STAGE 12 — Wallpaper
# =============================================================================
stage_12_wallpaper() {
    if is_done "stage_12"; then banner "STAGE 12 — WALLPAPER (done — skipping)"; return; fi

    banner "STAGE 12 — WALLPAPER"

    [[ -f "$WALLPAPER_SOURCE" ]] || { skip "No wallpaper.jpg next to script"; mark_done "stage_12"; return; }

    step "Copying wallpaper"
    mkdir -p "$HOME/Pictures/wallpapers"
    cp "$WALLPAPER_SOURCE" "$HOME/Pictures/wallpapers/setup-wallpaper.jpg"
    ok "Copied"

    step "Applying via KDE Plasma"
    local qd; qd=$(command -v qdbus6 || command -v qdbus || echo "")
    [[ -n "$qd" ]] && {
        "$qd" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
            var allDesktops = desktops();
            for (var i = 0; i < allDesktops.length; i++) {
                d = allDesktops[i];
                d.wallpaperPlugin = 'org.kde.image';
                d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
                d.writeConfig('Image', 'file://$HOME/Pictures/wallpapers/setup-wallpaper.jpg');
            }" 2>&1 | tee -a "$LOG_FILE"
        ok "Applied"
    } || warn "qdbus not found — set manually"

    mark_done "stage_12"
}

# =============================================================================
# Finalize
# =============================================================================
finalize() {
    banner "SETUP COMPLETE"

    cat <<EOF | tee -a "$LOG_FILE"
${GREEN}${BOLD}Post-install setup finished.${NORMAL}
Log:   ${BOLD}$LOG_FILE${NORMAL}
State: ${BOLD}$STATE_DIR${NORMAL} (delete for fresh run)

See ${BOLD}README.md${NORMAL} for:
  - Post-reboot verification commands
  - Steam + Proton setup guide (controllers, dGPU, Proton GE)
  - Multi-account git setup
  - Snapper rollback commands
  - How to customize the CLI tool list

${YELLOW}${BOLD}REBOOT required to:${NORMAL}
  - Activate docker group for $USER
  - Apply Hybrid GPU mode via supergfxctl
EOF

    read -r -p "Reboot now? [Y/n] " ans
    [[ "$ans" =~ ^[Nn]$ ]] \
        && info "Run 'sudo systemctl reboot' when ready." \
        || { info "Rebooting in 3s..."; sleep 3; sudo systemctl reboot; }
}

# =============================================================================
# Main
# =============================================================================
main() {
    banner "FEDORA 44 KDE — HOST BOOTSTRAP v4.0"
    info "Log: $LOG_FILE | State: $STATE_DIR"
    info "Verbose: $VERBOSE | Skip NVIDIA: $SKIP_NVIDIA | Skip ASUS: $SKIP_ASUS"

    preflight
    stage_1_system_and_rpmfusion
    stage_2_nvidia
    stage_3_asus
    stage_4_selinux
    stage_5_browser
    stage_6_containers
    stage_7_snapshots
    stage_8_cli_baseline
    stage_9_zed
    stage_10_steam
    stage_11_git_config
    stage_12_wallpaper
    finalize
}

main
