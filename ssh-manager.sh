#!/usr/bin/env bash
# =============================================================================
# ssh-manager.sh — Multi-account GitHub SSH + Git Profile + Robot SSH Manager
#
# Lives at: fedora_KDE_setup/ssh-manager.sh
# Works on: host, distrobox containers, docker containers (if home is mounted)
#
# Sets up:
#   1. Named SSH keys per GitHub account (default: personal + work)
#   2. Optional additional profiles (prompted interactively)
#   3. ~/.ssh/config with Host aliases for each account
#   4. Robot SSH config (skips host key checking for robot IPs)
#   5. git-profile command for switching git identity per-repo
#
# USAGE:
#   ./ssh-manager.sh setup          # Interactive setup
#   ./ssh-manager.sh list           # Show configured profiles
#   ./ssh-manager.sh test           # Test SSH connections
#   ./ssh-manager.sh robot-clear    # Clear known_hosts for robot IPs
#
# After setup, in any repo:
#   git profile clone <link>        # Clone any GitHub link; asks personal/work
#   git profile clone <link> work   # ...or name the profile
#   git profile use work            # Switch identity + fix remote of this repo
#   git profile show                # Show current identity
#
# Clone with specific accounts:
#   git clone git@github-work:company/repo.git
#   git clone git@github.com:user/repo.git           (personal = default)
#
# Robot SSH (no host key issues):
#   ssh user@192.168.1.3            # Just works, no key conflicts
# =============================================================================

set -uo pipefail

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
GIT_PROFILE_BIN="$HOME/.local/bin/git-profile"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

# =============================================================================
# EDITABLE CONFIGURATION
# =============================================================================

# Default profiles — always set up. Format: name:description
# The FIRST profile listed becomes the default (maps to github.com)
DEFAULT_PROFILES=(
    "personal:Personal GitHub (DEFAULT — git@github.com URLs)"
    "work:Work GitHub (git@github-work URLs)"
)

# Robot IP subnet — SSH to these IPs will skip host key checking
# This prevents "REMOTE HOST IDENTIFICATION HAS CHANGED" when switching robots
ROBOT_SUBNET="192.168.1.*"

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

# =============================================================================
# Profile storage
# =============================================================================
declare -A ALL_PROFILES
DEFAULT_PROFILE_NAME=""

load_default_profiles() {
    for entry in "${DEFAULT_PROFILES[@]}"; do
        IFS=':' read -r name desc <<< "$entry"
        ALL_PROFILES["$name"]="$desc"
        [[ -z "$DEFAULT_PROFILE_NAME" ]] && DEFAULT_PROFILE_NAME="$name"
    done

    # Also pick up extra profiles created in earlier runs, so re-running setup
    # (or list/test) does not drop them from ~/.ssh/config.
    local f n
    for f in "$SSH_DIR"/git-profile-*; do
        [[ -f "$f" ]] || continue
        n="${f##*/git-profile-}"
        [[ -n "${ALL_PROFILES[$n]+x}" ]] || ALL_PROFILES["$n"]="(added earlier)"
    done
}

# =============================================================================
# setup_account
# =============================================================================
setup_account() {
    local profile="$1"
    local description="${ALL_PROFILES[$profile]}"
    local key_file="$SSH_DIR/id_ed25519_github_${profile}"

    echo
    echo -e "${BOLD}${CYAN}--- Setting up: $profile ---${NORMAL}"
    echo -e "${BOLD}$description${NORMAL}"
    echo

    if [[ -f "$key_file" ]]; then
        info "SSH key already exists: $key_file"
        read -r -p "Regenerate? [y/N] " regen
        if [[ ! "$regen" =~ ^[Yy]$ ]]; then
            ok "Kept existing key"
        else
            read -r -p "Email for this account: " email
            ssh-keygen -t ed25519 -C "$email" -f "$key_file" -N "" \
                || { err "Key generation failed"; return 1; }
            ok "Key regenerated"
        fi
    else
        read -r -p "Email for this account: " email
        ssh-keygen -t ed25519 -C "$email" -f "$key_file" -N "" \
            || { err "Key generation failed"; return 1; }
        ok "Key generated: $key_file"
    fi

    local git_name git_email
    read -r -p "Git user.name for '$profile': " git_name
    read -r -p "Git user.email for '$profile': " git_email

    local profile_file="$SSH_DIR/git-profile-${profile}"
    cat > "$profile_file" <<EOF
GIT_PROFILE_NAME="$git_name"
GIT_PROFILE_EMAIL="$git_email"
GIT_PROFILE_KEY="$key_file"
EOF
    chmod 600 "$profile_file"
    ok "Git identity saved for '$profile'"
}

# =============================================================================
# write_ssh_config
# =============================================================================
write_ssh_config() {
    info "Writing SSH config..."

    [[ -f "$SSH_CONFIG" ]] && cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

    cat > "$SSH_CONFIG" <<HEADER
# =============================================================================
# SSH Configuration
# Generated by ssh-manager.sh
# =============================================================================

# --- Robot SSH ---
# Skips host key checking for robot IPs (prevents conflicts when switching
# between robots that share the same IP address)
Host $ROBOT_SUBNET
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR

HEADER

    for profile in "${!ALL_PROFILES[@]}"; do
        local key_file="$SSH_DIR/id_ed25519_github_${profile}"
        [[ ! -f "$key_file" ]] && continue

        if [[ "$profile" == "$DEFAULT_PROFILE_NAME" ]]; then
            cat >> "$SSH_CONFIG" <<EOF
# $profile (DEFAULT — git@github.com URLs use this; git@github-${profile} also works)
Host github.com github-${profile}
    HostName github.com
    User git
    IdentityFile $key_file
    IdentitiesOnly yes

EOF
        else
            cat >> "$SSH_CONFIG" <<EOF
# $profile (use git@github-${profile}:user/repo.git)
Host github-${profile}
    HostName github.com
    User git
    IdentityFile $key_file
    IdentitiesOnly yes

EOF
        fi
    done

    chmod 600 "$SSH_CONFIG"
    ok "SSH config written to $SSH_CONFIG"

    ssh-keyscan github.com >> "$KNOWN_HOSTS" 2>/dev/null
    ok "GitHub added to known_hosts"
}

# =============================================================================
# install_git_profile
# =============================================================================
install_git_profile() {
    info "Installing git-profile command..."

    mkdir -p "$(dirname "$GIT_PROFILE_BIN")"

    cat > "$GIT_PROFILE_BIN" <<'GITPROFILE'
#!/usr/bin/env bash
# git-profile — switch git identity / clone with the right account
#   git profile clone <link> [profile] [dir]   clone, rewriting the link for the profile
#   git profile use <profile> [-g]             set identity (+ fix origin) for this repo
#   git profile show | list
set -uo pipefail

SSH_DIR="$HOME/.ssh"
DEFAULT_PROFILE_NAME="__DEFAULT_PROFILE__"

profile_names() {
    local f
    for f in "$SSH_DIR"/git-profile-*; do
        [[ -f "$f" ]] && basename "$f" | sed 's/^git-profile-//'
    done
}

host_for() {   # profile -> ssh host alias
    if [[ "$1" == "$DEFAULT_PROFILE_NAME" ]]; then echo "github.com"; else echo "github-$1"; fi
}

case "${1:-}" in
    clone)
        url="${2:-}"; profile="${3:-}"
        [[ -z "$url" ]] && { echo "Usage: git profile clone <link> [profile] [dir]"; exit 1; }

        # Ask which profile if not given
        if [[ -z "$profile" ]]; then
            mapfile -t names < <(profile_names)
            [[ ${#names[@]} -eq 0 ]] && { echo "No profiles. Run: ssh-manager.sh setup"; exit 1; }
            echo "Clone as which profile?"
            PS3="Choose number: "
            select profile in "${names[@]}"; do [[ -n "$profile" ]] && break; done
            [[ -z "$profile" ]] && exit 1
        fi
        profile_file="$SSH_DIR/git-profile-${profile}"
        [[ ! -f "$profile_file" ]] && { echo "Profile '$profile' not found. Run: ssh-manager.sh list"; exit 1; }

        # Reduce any form of link to "owner/repo":
        #   https://github.com/o/r(.git)  git@github.com:o/r.git  git@github-work:o/r.git
        #   ssh://git@github.com/o/r      github.com/o/r          o/r
        path="$url"
        path="${path#ssh://}"; path="${path#git@}"; path="${path#https://}"; path="${path#http://}"
        case "$path" in
            github.com[:/]*|github-*[:/]*) path="${path#*[:/]}" ;;
        esac
        path="$(echo "$path" | cut -d/ -f1-2)"   # drop /tree/main/... from browser links
        path="${path%.git}"
        if [[ ! "$path" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            echo "Could not understand link: $url"; exit 1
        fi

        new_url="git@$(host_for "$profile"):${path}.git"
        dir="${4:-${path##*/}}"
        echo "Cloning as '$profile': $new_url"
        git clone "$new_url" "$dir" || exit $?

        source "$profile_file"
        git -C "$dir" config user.name "$GIT_PROFILE_NAME"
        git -C "$dir" config user.email "$GIT_PROFILE_EMAIL"
        echo "Done: $dir  (identity: $GIT_PROFILE_NAME <$GIT_PROFILE_EMAIL>)"
        ;;

    use)
        profile="${2:-}"
        [[ -z "$profile" ]] && { echo "Usage: git profile use <profile> [-g]"; exit 1; }

        profile_file="$SSH_DIR/git-profile-${profile}"
        [[ ! -f "$profile_file" ]] && { echo "Profile '$profile' not found. Run: ssh-manager.sh list"; exit 1; }
        source "$profile_file"

        scope="--local"; scope_label="repo"
        [[ "${3:-}" == "-g" ]] && { scope="--global"; scope_label="global"; }

        if [[ "$scope" == "--local" ]] && ! git rev-parse --is-inside-work-tree &>/dev/null; then
            scope="--global"; scope_label="global (not in a repo)"
        fi

        git config $scope user.name "$GIT_PROFILE_NAME"
        git config $scope user.email "$GIT_PROFILE_EMAIL"
        echo "Switched to '$profile' ($scope_label): $GIT_PROFILE_NAME <$GIT_PROFILE_EMAIL>"

        # Point origin at the right SSH host alias
        if [[ "$scope" == "--local" ]] && git remote get-url origin &>/dev/null; then
            current_url="$(git remote get-url origin)"
            if [[ "$current_url" == git@* ]]; then
                old_host="$(echo "$current_url" | sed 's/git@\([^:]*\):.*/\1/')"
                new_host="$(host_for "$profile")"
                if [[ "$old_host" != "$new_host" ]]; then
                    git remote set-url origin "$(echo "$current_url" | sed "s|git@${old_host}:|git@${new_host}:|")"
                    echo "Remote updated: $old_host → $new_host"
                fi
            fi
        fi
        ;;

    show)
        name=$(git config user.name 2>/dev/null || echo "(not set)")
        email=$(git config user.email 2>/dev/null || echo "(not set)")
        echo "Current: $name <$email>"
        for f in "$SSH_DIR"/git-profile-*; do
            [[ -f "$f" ]] || continue
            source "$f"
            if [[ "$GIT_PROFILE_EMAIL" == "$email" ]]; then
                echo "Profile: $(basename "$f" | sed 's/^git-profile-//')"; break
            fi
        done
        ;;

    list)
        echo "Available profiles:"
        for f in "$SSH_DIR"/git-profile-*; do
            [[ -f "$f" ]] || continue
            source "$f"
            pname="$(basename "$f" | sed 's/^git-profile-//')"
            tag=""; [[ "$pname" == "$DEFAULT_PROFILE_NAME" ]] && tag=" (default)"
            echo "  $pname$tag: $GIT_PROFILE_NAME <$GIT_PROFILE_EMAIL>"
        done
        ;;

    *)
        echo "Usage: git profile <clone|use|show|list>"
        echo "  clone <link> [profile] [dir]   Clone with the right account (asks if no profile)"
        echo "  use <profile> [-g]             Set identity + fix origin (per-repo, or -g global)"
        echo "  show                           Show current identity"
        echo "  list                           List profiles"
        ;;
esac
GITPROFILE

    sed -i "s|__DEFAULT_PROFILE__|${DEFAULT_PROFILE_NAME}|" "$GIT_PROFILE_BIN"
    chmod +x "$GIT_PROFILE_BIN"
    ok "git-profile installed to $GIT_PROFILE_BIN"
}

# =============================================================================
# show_public_keys
# =============================================================================
show_public_keys() {
    echo
    echo -e "${BOLD}${YELLOW}Add each public key to the corresponding GitHub account:${NORMAL}"
    echo -e "${BOLD}${YELLOW}GitHub → Settings → SSH and GPG Keys → New SSH Key${NORMAL}"

    for profile in "${!ALL_PROFILES[@]}"; do
        local pub_file="$SSH_DIR/id_ed25519_github_${profile}.pub"
        if [[ -f "$pub_file" ]]; then
            echo
            echo -e "${BOLD}${CYAN}=== $profile ===${NORMAL}"
            cat "$pub_file"
        fi
    done
    echo
}

# =============================================================================
# test_connections
# =============================================================================
test_connections() {
    echo
    info "Testing SSH connections..."

    for profile in "${!ALL_PROFILES[@]}"; do
        local key_file="$SSH_DIR/id_ed25519_github_${profile}"
        [[ ! -f "$key_file" ]] && { warn "$profile: no key found"; continue; }

        local host="github.com"
        [[ "$profile" != "$DEFAULT_PROFILE_NAME" ]] && host="github-${profile}"

        local result
        result=$(ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "git@${host}" 2>&1 || true)
        if echo "$result" | grep -qi "successfully authenticated"; then
            ok "$profile ($host): authenticated"
        else
            warn "$profile ($host): $result"
        fi
    done
    echo
}

# =============================================================================
# list_profiles
# =============================================================================
list_profiles() {
    echo
    echo -e "${BOLD}Configured GitHub profiles:${NORMAL}"
    for f in "$SSH_DIR"/git-profile-*; do
        [[ -f "$f" ]] || { echo "  (none configured — run: $0 setup)"; return; }
        source "$f"
        local pname
        pname=$(basename "$f" | sed 's/git-profile-//')

        local host="github.com"
        [[ "$pname" != "$DEFAULT_PROFILE_NAME" ]] && host="github-${pname}"

        local default_tag=""
        [[ "$pname" == "$DEFAULT_PROFILE_NAME" ]] && default_tag=" ${YELLOW}(default)${NORMAL}"

        echo -e "  ${BOLD}$pname${NORMAL}${default_tag}: $GIT_PROFILE_NAME <$GIT_PROFILE_EMAIL> → git@${host}"
    done

    echo
    echo -e "${BOLD}Robot SSH:${NORMAL}"
    if grep -q "StrictHostKeyChecking no" "$SSH_CONFIG" 2>/dev/null; then
        echo -e "  ${GREEN}Configured${NORMAL} for $ROBOT_SUBNET (no host key checking)"
    else
        echo -e "  ${YELLOW}Not configured${NORMAL}"
    fi
    echo
}

# =============================================================================
# robot_clear
# =============================================================================
robot_clear() {
    echo
    info "Clearing robot SSH entries from known_hosts..."

    if [[ ! -f "$KNOWN_HOSTS" ]]; then
        warn "No known_hosts file found"
        return
    fi

    local subnet_base
    subnet_base=$(echo "$ROBOT_SUBNET" | sed 's/\.\*$//')

    local count=0
    while IFS= read -r line; do
        local ip
        ip=$(echo "$line" | awk '{print $1}' | cut -d',' -f1)
        if [[ "$ip" == ${subnet_base}.* ]]; then
            ssh-keygen -f "$KNOWN_HOSTS" -R "$ip" 2>/dev/null
            ((count++))
        fi
    done < "$KNOWN_HOSTS"

    if [[ $count -gt 0 ]]; then
        ok "Cleared $count robot entries from known_hosts"
    else
        info "No robot entries found in known_hosts"
    fi
    echo
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    case "${1:-}" in
        setup)
            load_default_profiles

            echo
            echo -e "${BOLD}${CYAN}========================================${NORMAL}"
            echo -e "${BOLD}${CYAN}  GitHub + Robot SSH Setup${NORMAL}"
            echo -e "${BOLD}${CYAN}========================================${NORMAL}"
            echo
            info "Default profiles to set up:"
            for entry in "${DEFAULT_PROFILES[@]}"; do
                IFS=':' read -r name desc <<< "$entry"
                echo "  - $name: $desc"
            done
            echo
            read -r -p "Continue? [Y/n] " confirm
            [[ "$confirm" =~ ^[Nn]$ ]] && { info "Cancelled."; exit 0; }

            for entry in "${DEFAULT_PROFILES[@]}"; do
                IFS=':' read -r name desc <<< "$entry"
                setup_account "$name"
            done

            while true; do
                echo
                read -r -p "Add another GitHub profile? [y/N] " add_more
                [[ ! "$add_more" =~ ^[Yy]$ ]] && break

                read -r -p "Profile name (lowercase, no spaces): " extra_name
                extra_name=$(echo "$extra_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_')
                [[ -z "$extra_name" ]] && { warn "Invalid name"; continue; }
                [[ -n "${ALL_PROFILES[$extra_name]+x}" ]] && { warn "'$extra_name' already exists"; continue; }

                read -r -p "Description for '$extra_name': " extra_desc
                ALL_PROFILES["$extra_name"]="$extra_desc (git@github-${extra_name} URLs)"
                setup_account "$extra_name"
            done

            write_ssh_config
            install_git_profile

            show_public_keys
            read -r -p "Press Enter after adding ALL public keys to their GitHub accounts..." _

            test_connections

            echo -e "${GREEN}${BOLD}Setup complete!${NORMAL}"
            echo
            echo "Usage in any repo:"
            for profile in "${!ALL_PROFILES[@]}"; do
                echo "  git profile use $profile"
            done
            echo "  git profile show"
            echo
            echo "Easiest: paste ANY GitHub link, it is rewritten for you:"
            echo "  git profile clone https://github.com/org/repo          # asks personal/work"
            echo "  git profile clone https://github.com/org/repo work"
            echo
            echo "Or clone by hand with the host alias:"
            for profile in "${!ALL_PROFILES[@]}"; do
                local host="github.com"
                [[ "$profile" != "$DEFAULT_PROFILE_NAME" ]] && host="github-${profile}"
                echo "  git clone git@${host}:user/repo.git    # $profile"
            done
            echo
            echo "Robot SSH:"
            echo "  ssh user@192.168.1.3    # no host key conflicts"
            echo "  $0 robot-clear          # clear stale robot entries"
            ;;

        list)
            load_default_profiles
            list_profiles
            ;;

        test)
            load_default_profiles
            test_connections
            ;;

        robot-clear)
            robot_clear
            ;;

        *)
            echo "Usage: $0 <setup|list|test|robot-clear>"
            echo "  setup         Interactive setup of GitHub accounts + robot SSH"
            echo "  list          Show configured profiles"
            echo "  test          Test SSH connections"
            echo "  robot-clear   Clear robot entries from known_hosts"
            ;;
    esac
}

main "$@"
