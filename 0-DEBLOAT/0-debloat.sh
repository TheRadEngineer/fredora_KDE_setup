#!/usr/bin/env bash
# =============================================================================
# 00a-debloat.sh  —  Fedora 44 KDE Plasma Debloat  (v2)
# Run this BEFORE 00-host-setup.sh on a fresh Fedora 44 KDE install.
#
# Removes pre-installed apps AND cleans up every trace they leave behind:
# config dirs, cache, data dirs, desktop entries, icon cache, menu database.
# After running, it's as if these apps were never installed.
#
# KEY DESIGN CHOICE: Each package is removed individually, not as a group
# transaction. If one package is dependency-protected (can't be removed
# without breaking the desktop), it's skipped gracefully and doesn't block
# the rest of the category.
#
# USAGE:
#   ./00a-debloat.sh                 # interactive (shows list, asks to proceed)
#   ./00a-debloat.sh --yes           # skip confirmation
#   ./00a-debloat.sh --dry-run       # show what would happen, touch nothing
#
# CUSTOMIZATION:
#   Edit the REMOVE_* arrays below. Comment out any package you want to keep.
#
# See README-debloat.md for full documentation.
# =============================================================================

set -uo pipefail

LOG_FILE="${LOG_FILE:-$HOME/fedora-debloat.log}"
AUTO_YES=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y)    AUTO_YES=true ;;
        --dry-run)   DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--yes] [--dry-run] [--help]"
            exit 0
            ;;
        *)  echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; NORMAL=$'\e[0m'
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'
else
    BOLD=""; DIM=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

: > "$LOG_FILE"

info()  { echo -e "${BLUE}${BOLD}[INFO]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}${BOLD}[ OK ]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}${BOLD}[WARN]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}${BOLD}[FAIL]${NORMAL}  $*" | tee -a "$LOG_FILE"; }
skip()  { echo -e "${CYAN}${BOLD}[SKIP]${NORMAL}  $*" | tee -a "$LOG_FILE"; }

# =============================================================================
# PACKAGES TO REMOVE — edit these arrays to customize
# Comment out (prefix with #) any package you want to keep.
#
# IMPORTANT: Do NOT add packages that are dependencies of plasma-desktop or
# plasma-workspace. The script will skip them gracefully if you do, but it's
# cleaner to not list them at all. Known protected packages (do not add):
#   - knighttime        (provides libKNightTime.so for plasma-workspace-libs)
#   - plasma-setup      (provides libs for plasma-desktop)
#   - plasma-welcome    (dependency of plasma-setup)
#   - flite             (dep chain: flite → libavfilter → kpipewire → plasma)
# =============================================================================

# ---- Office suite (LibreOffice) ~350 MB ----
REMOVE_OFFICE=(
    libreoffice-calc
    libreoffice-core
    libreoffice-draw
    libreoffice-impress
    libreoffice-math
    libreoffice-writer
    libreoffice-help-en
)

# ---- KDE PIM (email, calendar, contacts, RSS) ~170 MB ----
REMOVE_PIM=(
    kmail
    kmail-libs
    kmail-account-wizard
    kmailtransport
    kontact
    kontactinterface
    kontact-libs
    korganizer
    korganizer-libs
    kaddressbook
    kaddressbook-libs
    akregator
    akregator-libs
    akonadi-calendar
    akonadi-contacts
    akonadi-import-wizard
    akonadi-mime
    akonadi-search
    akonadi-server
    kdepim-runtime
    kdepim-runtime-libs
    kdepim-addons
    libkdepim
    libksieve
    grantlee-editor
    pim-data-exporter
    pim-sieve-editor
    messagelib
)

# ---- KDE games ~15 MB ----
REMOVE_GAMES=(
    kmahjongg
    kmines
    kpat
    libkdegames
    libkmahjongg
    libkmahjongg-data
)

# ---- Apps you'll never use ~60 MB ----
# NOTE: knighttime, plasma-welcome, plasma-welcome-fedora, plasma-setup are
# NOT listed here — they are plasma-desktop dependencies and cannot be removed.
REMOVE_APPS=(
    dragon                  # video player
    kamoso                  # webcam app
    kmouth                  # speech synthesis frontend
    kolourpaint             # basic paint app
    kolourpaint-libs
    kwrite                  # simple text editor
    kcharselect             # unicode character picker
    skanpage                # scanner app
    khelpcenter             # KDE help browser
    neochat                 # Matrix chat client
    kleopatra               # certificate/encryption manager
    krdc                    # remote desktop client
    krdp                    # remote desktop protocol
    krfb                    # remote desktop server
    qrca                    # QR code scanner
    elisa-player            # music player
    kcalc                   # calculator
    kdebugsettings          # KDE debug logging config
)

# ---- Database server ~70 MB ----
REMOVE_DATABASE=(
    mariadb
    mariadb-server
    mariadb-backup
)

# ---- Printer drivers (no printer) ~65 MB ----
# NOTE: plasma-print-manager is KEPT for print-to-PDF.
REMOVE_PRINTER=(
    hplip
    gutenprint
)

# ---- Accessibility / speech ~70 MB ----
# NOTE: flite is NOT listed — it's a dependency of libavfilter-free which is
# needed by kpipewire which is needed by plasma-desktop. Cannot be removed.
REMOVE_ACCESSIBILITY=(
    orca
    speech-dispatcher
    speech-dispatcher-utils
    espeak-ng
)

# ---- Input methods (ibus) ~156 MB ----
REMOVE_INPUT_METHODS=(
    ibus
    ibus-anthy
    ibus-chewing
    ibus-hangul
    ibus-libpinyin
    ibus-m17n
    ibus-panel
    ibus-setup
    ibus-table
    ibus-typing-booster
    im-chooser
    imsettings
    imsettings-plasma
    anthy-unicode
    libpinyin-data
)

# ---- VM guest tools ~5 MB ----
REMOVE_VM=(
    open-vm-tools-desktop
    virtualbox-guest-additions
    spice-vdagent
)

# ---- Installer leftovers ~15 MB ----
REMOVE_INSTALLER=(
    anaconda-core
    anaconda-live
    anaconda-webui
    mediawriter
)

# ---- Misc ~55 MB ----
REMOVE_MISC=(
    gnome-abrt
    abrt-gui
    toolbox
)

# =============================================================================
# LEFTOVER TRACES TO CLEAN
# =============================================================================

CONFIG_DIRS_TO_CLEAN=(
    libreoffice
    akonadi akonadi-migrationagent akonadiconsole
    kaddressbookrc kmail2rc kmailrc kontact kontactrc
    korganizer korganizerrc akregator akregatorrc
    akonadi_newmailnotifier_agentrc akonadi_archivemail_agentrc
    akonadi_followupreminder_agentrc akonadi_mailfilter_agentrc
    akonadi_sendlater_agentrc akonadi_unifiedmailbox_agentrc
    kmahjonggrc kminesrc kpatrc
    dragonplayerrc kamosorc kmouthrc kolourpaintrc
    kwriterc elisarc elisa-playerrc neochatrc
    kleopatrarc skanpagerc kcalcrc kcharselectrc
    kdebugsettingsrc krdcrc krfbrc
    ibus mariadb abrt
)

DATA_DIRS_TO_CLEAN=(
    akonadi akonadi_migration_agent kmail2 kontact
    korganizer kaddressbook akregator
    pim-data-exporter pim-sieve-editor
    kmahjongg kmines kpat
    dragon kamoso kmouth kolourpaint kwrite
    elisa neochat kleopatra skanpage kcalc
    kcharselect krdc krfb qrca
    ibus libreoffice mariadb mysql
    abrt gnome-abrt plasma-welcome
)

CACHE_DIRS_TO_CLEAN=(
    akonadi kmail2 kontact korganizer akregator
    libreoffice ibus elisa neochat
    dragon kamoso kolourpaint mariadb
    skanpage kleopatra
)

SYSTEM_DIRS_TO_CLEAN=(
    /var/lib/mysql
    /var/lib/mariadb
    /var/log/mariadb
    /etc/my.cnf.d
    /var/lib/akonadi
    /etc/xdg/autostart/org.kde.kmail2.desktop
)

# =============================================================================
# MAIN LOGIC
# =============================================================================

echo
echo -e "${BOLD}${BLUE}================================================================${NORMAL}"
echo -e "${BOLD}${BLUE}  FEDORA 44 KDE — DEBLOAT (v2)${NORMAL}"
echo -e "${BOLD}${BLUE}================================================================${NORMAL}"
echo

if [[ $EUID -eq 0 ]]; then
    err "Don't run as root. The script uses sudo internally."
    exit 1
fi

# Combine all removal lists
ALL_REMOVE=(
    "${REMOVE_OFFICE[@]}"
    "${REMOVE_PIM[@]}"
    "${REMOVE_GAMES[@]}"
    "${REMOVE_APPS[@]}"
    "${REMOVE_DATABASE[@]}"
    "${REMOVE_PRINTER[@]}"
    "${REMOVE_ACCESSIBILITY[@]}"
    "${REMOVE_INPUT_METHODS[@]}"
    "${REMOVE_VM[@]}"
    "${REMOVE_INSTALLER[@]}"
    "${REMOVE_MISC[@]}"
)

# Filter to installed only
INSTALLED_REMOVE=()
for pkg in "${ALL_REMOVE[@]}"; do
    rpm -q "$pkg" &>/dev/null && INSTALLED_REMOVE+=("$pkg")
done

# Count trace dirs
TRACE_COUNT=0
for d in "${CONFIG_DIRS_TO_CLEAN[@]}"; do [[ -e "$HOME/.config/$d" ]] && TRACE_COUNT=$((TRACE_COUNT + 1)); done
for d in "${DATA_DIRS_TO_CLEAN[@]}"; do [[ -e "$HOME/.local/share/$d" ]] && TRACE_COUNT=$((TRACE_COUNT + 1)); done
for d in "${CACHE_DIRS_TO_CLEAN[@]}"; do [[ -e "$HOME/.cache/$d" ]] && TRACE_COUNT=$((TRACE_COUNT + 1)); done

if [[ ${#INSTALLED_REMOVE[@]} -eq 0 && $TRACE_COUNT -eq 0 ]]; then
    ok "Nothing to do — all listed packages already removed and no traces found."
    exit 0
fi

# --- Display ---
show_group() {
    local label="$1"; shift
    local pkgs=("$@")
    local found=()
    for pkg in "${pkgs[@]}"; do
        rpm -q "$pkg" &>/dev/null && found+=("$pkg")
    done
    if [[ ${#found[@]} -gt 0 ]]; then
        echo -e "  ${CYAN}${BOLD}$label${NORMAL}" | tee -a "$LOG_FILE"
        for pkg in "${found[@]}"; do
            local size size_mb
            size=$(rpm -q --queryformat '%{SIZE}' "$pkg" 2>/dev/null || echo 0)
            size_mb=$((size / 1024 / 1024))
            echo -e "    ${pkg}  ${DIM}(${size_mb} MB)${NORMAL}" | tee -a "$LOG_FILE"
        done
        echo | tee -a "$LOG_FILE"
    fi
}

echo -e "${BOLD}Packages to remove:${NORMAL}" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

show_group "Office (LibreOffice)"       "${REMOVE_OFFICE[@]}"
show_group "KDE PIM (email/calendar)"   "${REMOVE_PIM[@]}"
show_group "KDE Games"                  "${REMOVE_GAMES[@]}"
show_group "Unnecessary Apps"           "${REMOVE_APPS[@]}"
show_group "Database Server"            "${REMOVE_DATABASE[@]}"
show_group "Printer Drivers"            "${REMOVE_PRINTER[@]}"
show_group "Accessibility/Speech"       "${REMOVE_ACCESSIBILITY[@]}"
show_group "Input Methods (ibus)"       "${REMOVE_INPUT_METHODS[@]}"
show_group "VM Guest Tools"             "${REMOVE_VM[@]}"
show_group "Installer Leftovers"        "${REMOVE_INSTALLER[@]}"
show_group "Miscellaneous"              "${REMOVE_MISC[@]}"

echo -e "${BOLD}Packages to remove: ${#INSTALLED_REMOVE[@]}${NORMAL}" | tee -a "$LOG_FILE"
echo -e "${BOLD}Leftover traces to clean: ${TRACE_COUNT} directories${NORMAL}" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

# --- Dry run ---
if $DRY_RUN; then
    if [[ $TRACE_COUNT -gt 0 ]]; then
        echo -e "${BOLD}Trace directories that would be cleaned:${NORMAL}" | tee -a "$LOG_FILE"
        for d in "${CONFIG_DIRS_TO_CLEAN[@]}"; do [[ -e "$HOME/.config/$d" ]] && echo "    ~/.config/$d" | tee -a "$LOG_FILE"; done
        for d in "${DATA_DIRS_TO_CLEAN[@]}"; do [[ -e "$HOME/.local/share/$d" ]] && echo "    ~/.local/share/$d" | tee -a "$LOG_FILE"; done
        for d in "${CACHE_DIRS_TO_CLEAN[@]}"; do [[ -e "$HOME/.cache/$d" ]] && echo "    ~/.cache/$d" | tee -a "$LOG_FILE"; done
        for d in "${SYSTEM_DIRS_TO_CLEAN[@]}"; do sudo test -e "$d" 2>/dev/null && echo "    $d (system)" | tee -a "$LOG_FILE"; done
        echo | tee -a "$LOG_FILE"
    fi
    info "Dry run — nothing was changed."
    exit 0
fi

# --- Confirmation ---
if ! $AUTO_YES; then
    echo -e "${YELLOW}${BOLD}This will:${NORMAL}"
    echo "  1. Remove ${#INSTALLED_REMOVE[@]} packages (each individually — dep-protected ones are skipped)"
    echo "  2. Delete config/cache/data left behind by removed apps"
    echo "  3. Rebuild desktop menu and icon caches"
    echo "  4. Stop and disable services from removed apps"
    echo
    echo -e "${YELLOW}Core desktop (Plasma, Dolphin, Konsole, etc.) will NOT be affected.${NORMAL}"
    echo
    read -r -p "Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
fi

echo | tee -a "$LOG_FILE"
info "Checking sudo access..."
sudo -v || { err "Need sudo."; exit 1; }

# =============================================================================
# PHASE 1: Stop services
# =============================================================================
echo | tee -a "$LOG_FILE"
echo -e "${CYAN}--> Phase 1: Stopping services${NORMAL}" | tee -a "$LOG_FILE"

command -v akonadictl &>/dev/null && { akonadictl stop >> "$LOG_FILE" 2>&1 || true; ok "Akonadi stopped"; }
systemctl is-active mariadb &>/dev/null && { sudo systemctl stop mariadb >> "$LOG_FILE" 2>&1; sudo systemctl disable mariadb >> "$LOG_FILE" 2>&1; ok "MariaDB stopped"; }
systemctl --user is-active ibus &>/dev/null 2>&1 && { systemctl --user stop ibus >> "$LOG_FILE" 2>&1 || true; ok "ibus stopped"; }

# =============================================================================
# PHASE 2: Remove packages (INDIVIDUALLY — so dep-protected ones don't block others)
# =============================================================================
echo | tee -a "$LOG_FILE"
echo -e "${CYAN}--> Phase 2: Removing packages${NORMAL}" | tee -a "$LOG_FILE"

total_removed=0
total_skipped=0
dep_protected=()

remove_group() {
    local label="$1"; shift
    local pkgs=("$@")
    local group_removed=0
    local group_skipped=0

    # Check if any are installed
    local has_any=false
    for pkg in "${pkgs[@]}"; do rpm -q "$pkg" &>/dev/null && { has_any=true; break; }; done
    $has_any || return

    echo -e "  ${BOLD}$label${NORMAL}" | tee -a "$LOG_FILE"

    for pkg in "${pkgs[@]}"; do
        # Skip if not installed
        rpm -q "$pkg" &>/dev/null || continue

        # Try removing individually
        if sudo dnf remove -y "$pkg" >> "$LOG_FILE" 2>&1; then
            echo -e "    ${GREEN}✓${NORMAL} $pkg" | tee -a "$LOG_FILE"
            group_removed=$((group_removed + 1))
            total_removed=$((total_removed + 1))
        else
            echo -e "    ${YELLOW}✗${NORMAL} $pkg ${DIM}(dependency-protected, kept)${NORMAL}" | tee -a "$LOG_FILE"
            dep_protected+=("$pkg")
            group_skipped=$((group_skipped + 1))
            total_skipped=$((total_skipped + 1))
        fi
    done

    if [[ $group_skipped -eq 0 ]]; then
        ok "  $label: all $group_removed removed"
    else
        ok "  $label: $group_removed removed, $group_skipped kept (dep-protected)"
    fi
    echo | tee -a "$LOG_FILE"
}

remove_group "KDE PIM + Akonadi"    "${REMOVE_PIM[@]}"
remove_group "LibreOffice"          "${REMOVE_OFFICE[@]}"
remove_group "KDE Games"            "${REMOVE_GAMES[@]}"
remove_group "Apps"                 "${REMOVE_APPS[@]}"
remove_group "Database Server"      "${REMOVE_DATABASE[@]}"
remove_group "Printer Drivers"      "${REMOVE_PRINTER[@]}"
remove_group "Accessibility/Speech" "${REMOVE_ACCESSIBILITY[@]}"
remove_group "Input Methods"        "${REMOVE_INPUT_METHODS[@]}"
remove_group "VM Guest Tools"       "${REMOVE_VM[@]}"
remove_group "Installer Leftovers"  "${REMOVE_INSTALLER[@]}"
remove_group "Misc"                 "${REMOVE_MISC[@]}"

echo -e "${BOLD}Removal summary: $total_removed removed, $total_skipped dependency-protected${NORMAL}" | tee -a "$LOG_FILE"
if [[ ${#dep_protected[@]} -gt 0 ]]; then
    info "Kept (needed by plasma/desktop): ${dep_protected[*]}"
fi

# =============================================================================
# PHASE 3: Autoremove orphaned dependencies
# =============================================================================
echo | tee -a "$LOG_FILE"
echo -e "${CYAN}--> Phase 3: Removing orphaned dependencies${NORMAL}" | tee -a "$LOG_FILE"

sudo dnf autoremove -y >> "$LOG_FILE" 2>&1 && ok "Autoremove complete" || warn "Autoremove had issues"

# =============================================================================
# PHASE 4: Clean leftover traces
# =============================================================================
echo | tee -a "$LOG_FILE"
echo -e "${CYAN}--> Phase 4: Cleaning leftover traces${NORMAL}" | tee -a "$LOG_FILE"

cleaned=0

for d in "${CONFIG_DIRS_TO_CLEAN[@]}"; do
    target="$HOME/.config/$d"
    [[ -e "$target" ]] && { rm -rf "$target"; cleaned=$((cleaned + 1)); echo "    Removed ~/.config/$d" >> "$LOG_FILE"; }
done

for d in "${DATA_DIRS_TO_CLEAN[@]}"; do
    target="$HOME/.local/share/$d"
    [[ -e "$target" ]] && { rm -rf "$target"; cleaned=$((cleaned + 1)); echo "    Removed ~/.local/share/$d" >> "$LOG_FILE"; }
done

for d in "${CACHE_DIRS_TO_CLEAN[@]}"; do
    target="$HOME/.cache/$d"
    [[ -e "$target" ]] && { rm -rf "$target"; cleaned=$((cleaned + 1)); echo "    Removed ~/.cache/$d" >> "$LOG_FILE"; }
done

for d in "${SYSTEM_DIRS_TO_CLEAN[@]}"; do
    sudo test -e "$d" 2>/dev/null && { sudo rm -rf "$d"; cleaned=$((cleaned + 1)); echo "    Removed $d (system)" >> "$LOG_FILE"; }
done

# Clean stale autostart entries
for f in "$HOME/.config/autostart/"*; do
    [[ -f "$f" ]] || continue
    exec_line=$(grep -oP '^Exec=\K\S+' "$f" 2>/dev/null || echo "")
    if [[ -n "$exec_line" ]] && ! command -v "$(basename "$exec_line")" &>/dev/null; then
        rm -f "$f"; cleaned=$((cleaned + 1))
        echo "    Removed stale autostart: $(basename "$f")" >> "$LOG_FILE"
    fi
done

ok "Cleaned $cleaned leftover directories/files"

# =============================================================================
# PHASE 5: Clean stale user systemd units
# =============================================================================
echo | tee -a "$LOG_FILE"
echo -e "${CYAN}--> Phase 5: Cleaning stale user systemd units${NORMAL}" | tee -a "$LOG_FILE"

stale_units=0
for unit_dir in "$HOME/.config/systemd/user" "$HOME/.local/share/systemd/user"; do
    [[ -d "$unit_dir" ]] || continue
    for unit_file in "$unit_dir"/*; do
        [[ -f "$unit_file" ]] || continue
        unit_name=$(basename "$unit_file")
        exec_line=$(grep -oP '^ExecStart=\K\S+' "$unit_file" 2>/dev/null || echo "")
        if [[ -n "$exec_line" ]] && ! [[ -x "$exec_line" ]]; then
            systemctl --user disable --now "$unit_name" 2>/dev/null || true
            rm -f "$unit_file"; stale_units=$((stale_units + 1))
            echo "    Removed stale unit: $unit_name" >> "$LOG_FILE"
        fi
    done
done
systemctl --user daemon-reload 2>/dev/null || true
[[ $stale_units -gt 0 ]] && ok "Removed $stale_units stale user units" || skip "No stale user units"

# =============================================================================
# PHASE 6: Rebuild desktop and icon caches
# =============================================================================
echo | tee -a "$LOG_FILE"
echo -e "${CYAN}--> Phase 6: Rebuilding caches${NORMAL}" | tee -a "$LOG_FILE"

# Desktop database
command -v update-desktop-database &>/dev/null && {
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    sudo update-desktop-database /usr/share/applications >> "$LOG_FILE" 2>&1 || true
    ok "Desktop database rebuilt"
}

# MIME database
command -v update-mime-database &>/dev/null && {
    # Create the dir if it doesn't exist (fixes the "does not exist" warning)
    mkdir -p "$HOME/.local/share/mime/packages"
    update-mime-database "$HOME/.local/share/mime" 2>/dev/null || true
    ok "MIME database rebuilt"
}

# Icon cache
command -v gtk-update-icon-cache &>/dev/null && {
    for theme_dir in /usr/share/icons/*/; do
        [[ -f "${theme_dir}index.theme" ]] || continue
        sudo gtk-update-icon-cache -f -t "$theme_dir" >> "$LOG_FILE" 2>&1 || true
    done
    ok "Icon cache rebuilt"
}

# Baloo (file indexer)
if command -v balooctl6 &>/dev/null; then
    balooctl6 purge 2>/dev/null || true
    ok "Baloo index purged"
elif command -v balooctl &>/dev/null; then
    balooctl purge 2>/dev/null || true
    ok "Baloo index purged"
fi

# KDE KSycoca (the master app/service database — this is the key one)
if command -v kbuildsycoca6 &>/dev/null; then
    kbuildsycoca6 --noincremental >> "$LOG_FILE" 2>&1 || true
    ok "KDE app database rebuilt (KSycoca6)"
elif command -v kbuildsycoca5 &>/dev/null; then
    kbuildsycoca5 --noincremental >> "$LOG_FILE" 2>&1 || true
    ok "KDE app database rebuilt (KSycoca5)"
fi

# =============================================================================
# DONE
# =============================================================================
echo | tee -a "$LOG_FILE"
echo -e "${BOLD}${BLUE}================================================================${NORMAL}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${BLUE}  DEBLOAT COMPLETE${NORMAL}" | tee -a "$LOG_FILE"
echo -e "${BOLD}${BLUE}================================================================${NORMAL}" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

echo -e "${BOLD}Summary:${NORMAL}" | tee -a "$LOG_FILE"
echo "  Packages removed:           $total_removed" | tee -a "$LOG_FILE"
echo "  Dependency-protected (kept): $total_skipped" | tee -a "$LOG_FILE"
echo "  Trace dirs cleaned:          $cleaned" | tee -a "$LOG_FILE"
echo "  Stale systemd units cleaned: $stale_units" | tee -a "$LOG_FILE"
echo "  Log: $LOG_FILE" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

info "Removed apps will no longer appear in your application menu."
info "If any phantom entries persist, log out and back in."
echo | tee -a "$LOG_FILE"
info "Next step: ./00-host-setup.sh --verbose"
