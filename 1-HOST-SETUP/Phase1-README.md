# Phase 1: Host Bootstrap — `00-host-setup.sh`

Post-install setup script for **Fedora 44 KDE Plasma** on an **ASUS ROG Strix SCAR 16 G634JZR** (Intel i9-14900HX + NVIDIA RTX 4080 Laptop GPU).

Transforms a fresh Fedora 44 KDE install into a fully configured development workstation with NVIDIA GPU support, container tooling, programming languages, editors, and gaming — in one command.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [What the Script Does (All 15 Stages)](#what-the-script-does)
3. [Two-Phase Execution (The Reboot)](#two-phase-execution)
4. [Customizing the CLI Tool List](#customizing-the-cli-tool-list)
5. [Post-Reboot Verification](#post-reboot-verification)
6. [Steam, Proton & Gaming Setup Guide](#steam-proton--gaming-setup-guide)
7. [Snapper Snapshots (Rollback)](#snapper-snapshots)
8. [Multi-Account Git Setup](#multi-account-git-setup)
9. [SSH Keys for GitHub](#ssh-keys-for-github)
10. [Troubleshooting](#troubleshooting)
11. [Script Flags](#script-flags)
12. [Known Hardware-Specific Decisions](#known-hardware-specific-decisions)

---

## Quick Start

### Prerequisites

- Fresh Fedora 44 KDE Plasma install (first boot completed, logged into the desktop)
- Internet connection
- The USB stick with this script (and optionally `wallpaper.jpg` in the same directory)

### Run

```bash
cd /run/media/$USER/<usb-partition>    # or wherever the script lives
chmod +x 00-host-setup.sh
./00-host-setup.sh --verbose           # recommended for first run
```

The script will:

1. Run Stage 1 (system upgrade, RPM Fusion).
2. Detect that a new kernel was installed but you're still running the old one.
3. Prompt you to reboot.
4. After reboot, run the script again — same command — and it continues from Stage 2 onward.
5. At the end, prompt for a final reboot.

Total time: roughly 20-40 minutes depending on internet speed and mirror availability.

---

## What the Script Does

### Stage 1 — System Upgrade + RPM Fusion

Applies all pending Fedora updates and installs RPM Fusion (free + nonfree repositories). RPM Fusion provides packages Fedora cannot ship due to licensing: NVIDIA drivers, Steam, multimedia codecs, and more.

Also configures dnf for faster operation:
- `fastestmirror=True` — automatically picks the fastest mirror for your location
- `max_parallel_downloads=10` — downloads 10 packages simultaneously instead of 3

**May reboot here** if a new kernel was installed (see [Two-Phase Execution](#two-phase-execution)).

### Stage 2 — NVIDIA Driver (Open Kernel Module)

Installs `akmod-nvidia-open` (NVIDIA's open-source kernel module, recommended for RTX 20-series and newer) plus CUDA runtime libraries. The `akmod` system automatically rebuilds the NVIDIA kernel module whenever Fedora ships a kernel update, so you never have to think about driver/kernel mismatches.

Waits up to 5 minutes for the kernel module build to complete, then verifies it loaded. Checks Secure Boot state (if enabled, MOK enrollment is needed — the script warns you).

**Why open-source kernel module?** NVIDIA themselves recommend it for Ada Lovelace (RTX 40-series) and newer. The userspace libraries (CUDA, OpenGL, Vulkan) are the same proprietary NVIDIA code regardless of which kernel module variant you choose. Performance is identical. CUDA compatibility is identical.

### Stage 3 — ASUS ROG Hardware Stack

Installs `asusctl` (fan curves, keyboard RGB, power profiles), `supergfxctl` (hybrid GPU mode switching between iGPU/dGPU), and ROG Control Center (GUI for all of the above) from the `lukenukem/asus-linux` COPR repository.

Sets GPU mode to **Hybrid** (both Intel iGPU and NVIDIA dGPU active, with automatic offloading). This is the mode that gives you battery life on light tasks and GPU power on demand.

**Deliberate omission:** `asusd-user.service` is NOT created. On the ROG Strix SCAR 16 G634JZR (and other Ada-era ROG models), the user-session daemon crashes due to an upstream bug — it calls `.unwrap()` on a D-Bus object (`/xyz/ljones/Aura`) that doesn't exist on newer keyboard controllers. The system daemon `asusd.service` handles all hardware control via D-Bus activation. ROG Control Center works perfectly without `asusd-user`.

### Stage 4 — SELinux Policy Exception

Installs a declarative SELinux policy module (`my-systemdlogind`) that allows `systemd-logind` to read/write the GPU character device (`card0`). Without this, SELinux blocks logind from accessing the GPU on hybrid-graphics laptops after supergfxctl mode changes, which can cause session management issues.

The policy is compiled from source (a `.te` file) and installed at priority 300, so it gets automatically superseded if Fedora ships an official fix in a future `selinux-policy` update.

### Stage 5 — Browser (Remove Firefox, Install Zen)

Removes the Firefox RPM, enables the Flathub repository (user scope), and installs Zen browser as a user-scoped Flatpak. Sets Zen as the system default browser.

User-scoped Flatpak avoids permission issues with KDE Discover's system-level Flatpak lockdown on fresh installs.

### Stage 6 — Container Stack

Installs the full container toolchain:

- **Docker CE** (Community Edition) with Compose and Buildx plugins — the standard container runtime for most development workflows
- **NVIDIA Container Toolkit** — enables GPU passthrough into Docker containers (essential for Isaac Sim, CUDA workloads, ML training)
- **Podman** — rootless container runtime (required by Distrobox)
- **Distrobox** — runs full Linux distributions as lightweight containers with automatic GPU, home directory, Wayland/X, audio, and USB forwarding

Adds your user to the `docker` group (requires reboot to take effect).

### Stage 7 — Snapper (BTRFS Snapshots)

Installs Snapper and the dnf-plugin-snapper so that a filesystem snapshot is automatically created before and after every `dnf install/upgrade/remove` transaction. If a package update breaks something, you can roll back the entire transaction in seconds.

Configuration:
- **Pre/post transaction snapshots only** — no time-based snapshots
- **Keep last 5 pairs** (10 snapshots total) — oldest auto-pruned
- **Timeline timer disabled** — snapshots only happen when you install/upgrade/remove packages
- **Cleanup timer enabled** — automatically prunes expired snapshots

### Stage 8 — CLI Baseline + Fonts + Node.js

Installs a lean set of CLI tools (see [Customizing the CLI Tool List](#customizing-the-cli-tool-list)), programming fonts (JetBrains Mono, Fira Code, Noto), and Node.js + npm (needed by several language servers).

### Stage 9 — Programming Languages

- **Python** via `uv` (from Astral) — modern Python project + package manager that replaces pip, pyenv, virtualenv, and poetry
- **Rust** via `rustup` — the official Rust toolchain manager, installs to `~/.cargo`
- **Go** via `dnf install golang` — Fedora's packaged Go
- **C++** toolchain: gcc, g++, make, cmake, ninja-build, gdb, valgrind, clang, clangd (from clang-tools-extra), pkg-config, qt6-qttools

### Stage 10 — Language Servers (LSPs)

Language servers provide autocomplete, go-to-definition, error/warning diagnostics, hover documentation, rename-across-files, and formatting in both Neovim (LazyVim) and VS Code.

Installed directly by the script:
- `clangd` — C/C++ (from clang-tools-extra, already installed in Stage 9)
- `rust-analyzer` — Rust (via `rustup component add`)
- `gopls` — Go (via `go install`)
- `pyright` — Python (via npm)
- `bash-language-server` — Bash (via npm)
- `yaml-language-server` — YAML (via npm)
- `dockerfile-language-server-nodejs` — Dockerfile (via npm)
- `vscode-langservers-extracted` — JSON, HTML, CSS, ESLint (via npm)
- `typescript-language-server` — TypeScript/JavaScript (via npm)
- `java-latest-openjdk-devel` — Java JDK (needed for jdtls)

Handled by Mason (auto-installed on first file open in LazyVim):
- `lua-language-server` — Lua (not in Fedora repos)
- `lemminx` — XML (not in Fedora repos)
- `marksman` — Markdown (not a Rust crate despite the name; .NET binary)
- `jdtls` — Java (Eclipse LSP, large download)

### Stage 11 — LazyVim

Clones the LazyVim starter configuration into `~/.config/nvim`. LazyVim is a Neovim distribution that provides a pre-configured, batteries-included editor experience with plugin management, LSP integration, Treesitter syntax highlighting, and a consistent keymap.

First launch of `nvim` after installation takes approximately 30 seconds to bootstrap plugins. Treesitter parsers (which provide syntax highlighting) auto-install the first time you open a file of each language.

### Stage 12 — VS Code

Adds Microsoft's official RPM repository and installs Visual Studio Code. This is the native RPM, not Flatpak — it integrates cleanly with Docker, Dev Containers, Wayland, and terminal shell integration.

**Important:** telemetry is enabled by default. Turn it off after first launch: File → Preferences → Settings → search "telemetry" → set to "off".

### Stage 13 — Steam + Controller Support + ProtonUp-Qt

Installs Steam from RPM Fusion, `steam-devices` (udev rules for game controllers), and ProtonUp-Qt (a Flatpak GUI for managing Proton/Proton GE versions).

See [Steam, Proton & Gaming Setup Guide](#steam-proton--gaming-setup-guide) for complete setup instructions.

### Stage 14 — Git Configuration

Interactive prompt for your primary git identity (name + email). Sets sensible defaults:
- `init.defaultBranch = main`
- `pull.rebase = false` (merge on pull, not rebase)
- `core.editor = nvim`

### Stage 15 — Wallpaper

If a file named `wallpaper.jpg` exists in the same directory as the script, copies it to `~/Pictures/wallpapers/` and applies it to all KDE Plasma desktops via D-Bus scripting.

---

## Two-Phase Execution

Fresh Fedora installs ship an older kernel. Stage 1's `dnf upgrade` installs the latest kernel, but you're still running the old one. The NVIDIA driver (Stage 2) needs `kernel-devel` headers matching the running kernel — and after upgrade, only headers for the *new* kernel are available.

The script detects this mismatch automatically:

```
[WARN] KERNEL MISMATCH — reboot needed before NVIDIA install
       After reboot, re-run: ./00-host-setup.sh
```

After reboot, the script picks up where it left off. State files in `~/.fedora-setup-state/` track which stages completed. Each stage checks `is_done "stage_N"` before running.

To force a full re-run from scratch:
```bash
./00-host-setup.sh --reset-state
```

---

## Customizing the CLI Tool List

The CLI tools are defined at the top of the script in a bash array. To add or remove tools, edit the `CLI_PACKAGES` array:

```bash
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
    neovim                  # terminal editor (LazyVim base)
)
```

To add a tool, add its Fedora package name on a new line. To remove one, delete or comment out the line. The script uses `dnf install -y` with all packages in a single transaction.

Similarly, you can customize:
- `FONT_PACKAGES` — programming fonts
- `CPP_PACKAGES` — C++ toolchain packages
- `NPM_LSP_PACKAGES` — Node.js-based language servers

**Tools you might want to add later:**

| Package name | What it does | When you'd want it |
|---|---|---|
| `fd-find` | Fast `find` replacement | Once `find` syntax annoys you |
| `bat` | `cat` with syntax highlighting | Once plain `cat` feels limiting |
| `eza` | Modern `ls` with git integration | Once you want visual dir listings |
| `fzf` | Fuzzy finder for everything | Once you need interactive filtering |
| `tmux` | Terminal multiplexer | Once you SSH into remote machines |
| `zsh` | Alternative shell | Once bash's tab-completion limits you |
| `lazygit` | TUI for git | After you're comfortable with git CLI |
| `lazydocker` | TUI for Docker | After you're comfortable with docker CLI |
| `direnv` | Per-directory environment variables | When managing multiple projects |
| `starship` | Cross-shell prompt customization | When you want a prettier terminal |

---

## Post-Reboot Verification

After the final reboot, open Konsole and run each of these:

### Hardware
```bash
nvidia-smi                  # Should show RTX 4080, driver version, CUDA version
supergfxctl -g              # Should show "Hybrid"
asusctl profile -p          # Should show "Balanced" (or whatever profile is active)
```

### Containers
```bash
docker run hello-world      # Should print "Hello from Docker!" without needing sudo

# GPU inside a container (pulls ~2GB image on first run):
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### Languages
```bash
python3 --version           # System Python
uv --version                # uv Python manager
go version                  # Go
rustc --version             # Rust (may need to open a new shell first)
cargo --version             # Cargo (Rust package manager)
g++ --version               # GCC C++ compiler
node --version              # Node.js
npm --version               # npm
```

### Editors
```bash
nvim                        # LazyVim — first launch bootstraps plugins (~30s)
code                        # VS Code — remember to turn off telemetry
```

### Snapshots
```bash
sudo snapper -c root list   # Should show at least one snapshot from the setup
```

---

## Steam, Proton & Gaming Setup Guide

### Initial Steam Setup

1. **Launch Steam** from the application menu (or `steam` in Konsole).
2. **Log in** with your Steam account.
3. **Enable Steam Play (Proton) for all titles:**
   - Steam → Settings → Compatibility
   - Check **"Enable Steam Play for all other titles"**
   - Set the Proton version to the latest stable (e.g., "Proton 9.0-4" or whatever is newest)
   - Click OK

This enables Proton (Valve's Windows compatibility layer) for every game in your library, not just the ones officially verified for Linux.

### Installing Proton GE (Recommended for AAA Games)

Proton GE ("GloriousEggroll") is a community fork of Proton with additional patches, game-specific fixes, and faster adoption of upstream Wine/DXVK improvements. For demanding games like Cyberpunk 2077, it often provides noticeably better performance and stability.

1. **Open ProtonUp-Qt** from your application menu.
2. Click **"Add Version"**.
3. Select **"GE-Proton"** from the compatibility tool dropdown.
4. Pick the **latest version** (e.g., GE-Proton9-27 or whatever is newest).
5. Click **"Install"**.
6. Close ProtonUp-Qt.

To use Proton GE for a specific game:
1. In Steam, right-click the game → **Properties**
2. Go to the **Compatibility** tab
3. Check **"Force the use of a specific Steam Play compatibility tool"**
4. Select the **GE-Proton** version you just installed
5. Close the window and launch the game

### Forcing Games to Use the NVIDIA GPU (Critical for AAA Games)

On your hybrid-graphics laptop (Intel iGPU + NVIDIA dGPU), games launch on the **iGPU by default**, which is terrible for performance. You need to tell each game to use the dGPU.

**Method 1: Per-game launch option (recommended)**

Right-click the game in Steam → Properties → General → Launch Options. Paste:

```
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia %command%
```

This forces the game to render on the RTX 4080. Do this for every game where performance matters.

**Method 2: Global Steam launch wrapper**

If you want ALL Steam games to use the dGPU by default, create a script:

```bash
mkdir -p ~/bin
cat > ~/bin/nvidia-offload <<'EOF'
#!/bin/bash
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
exec "$@"
EOF
chmod +x ~/bin/nvidia-offload
```

Then set each game's launch options to:
```
~/bin/nvidia-offload %command%
```

Or, for a truly global approach, use Steam's environment override. In `~/.config/environment.d/nvidia-steam.conf`:
```
STEAM_GAME_NVIDIA_OFFLOAD=1
```
(This is less standard; per-game launch options are more reliable.)

### Controller Setup

The script installed `steam-devices`, which provides udev rules for all major controller types. Your controller should work plug-and-play:

- **Xbox / Xbox-compatible controllers** (including HyperX Clutch Gladiate, PowerA wired, 8BitDo in XInput mode): plug in USB → works immediately in Steam and all games. This is the gold standard.
- **PlayStation DualShock 4 / DualSense**: plug in USB → works. Bluetooth pairing also works but may have slightly more input lag.
- **Generic / DirectInput controllers**: Steam Input can usually remap these, but compatibility is not guaranteed. Prefer Xbox-compatible (XInput) controllers for the most reliable experience.

**Testing your controller:**
1. Plug in the controller.
2. Open Steam → Settings → Controller → General Controller Settings.
3. Your controller should appear in the detected controllers list.
4. Click **"Identify My Controller"** to verify button mapping.

If buttons are mapped wrong, Steam Input lets you remap them per-game or globally from this settings page.

### Game-Specific Tips

**For AAA games (Cyberpunk 2077, etc.):**
- Use **Proton GE** (not default Proton) — often 10-15% better performance
- Set **dGPU launch option** (the `__NV_PRIME_RENDER_OFFLOAD=1` line above)
- In-game: start with **Medium/High** graphics, adjust from there
- Enable **FSR (FidelityFX Super Resolution)** in-game if available — renders at lower resolution and upscales, massive FPS boost with minimal visual difference
- Your RTX 4080 Laptop supports **DLSS** — enable it in games that support it for the best quality/performance ratio
- Consider switching to **Performance** power profile before playing: `asusctl profile -P Performance`
- Switch back after: `asusctl profile -P Balanced`

**For indie / lightweight games:**
- Default Proton works fine (no need for Proton GE)
- dGPU launch option is optional — many indie games run fine on the iGPU
- No special configuration needed — install and play

**For games that won't launch:**
1. Check [ProtonDB](https://www.protondb.com/) — community database of game compatibility reports with fixes
2. Try a different Proton version (switch between stable Proton and Proton GE)
3. Check if the game needs a specific launch option (ProtonDB usually lists these)
4. Some anti-cheat games (Valorant, Fortnite) genuinely don't work on Linux — this is an anti-cheat vendor decision, not a Linux limitation

### Verifying GPU is Actually Being Used

While a game is running, open a terminal and run:
```bash
nvidia-smi
```

You should see the game process listed under "Processes" with GPU memory usage. If you don't see it, the game is running on the iGPU — add the dGPU launch option.

---

## Snapper Snapshots

Snapper automatically creates pre/post snapshots around every dnf transaction.

### List Snapshots
```bash
sudo snapper -c root list
```

### See What Changed Between Two Snapshots
```bash
sudo snapper -c root status 1..2    # compare snapshot 1 vs 2
```

### Undo a Transaction (Roll Back)
```bash
sudo snapper -c root undochange 1..2    # revert all changes between snapshot 1 and 2
```

### Create a Manual Snapshot (Before Risky Operations)
```bash
sudo snapper -c root create -d "before doing something scary"
```

### Retention Policy
- Max 10 snapshots (5 pre + 5 post pairs)
- Oldest auto-deleted when limit is reached
- Nothing younger than 30 minutes is ever deleted
- Empty pre/post pairs (where nothing changed) are auto-cleaned

---

## Multi-Account Git Setup

If you have multiple GitHub accounts (personal + work), use git's conditional includes.

### Directory Structure
```
~/dev/
├── personal-1/     # repos for GitHub account 1
├── personal-2/     # repos for GitHub account 2
└── work/           # repos for work account (if on host; usually in a container)
```

### `~/.gitconfig` (add these blocks)
```ini
[includeIf "gitdir:~/dev/personal-2/"]
    path = ~/.gitconfig-personal-2

[includeIf "gitdir:~/dev/work/"]
    path = ~/.gitconfig-work
```

### `~/.gitconfig-personal-2`
```ini
[user]
    name = Your Other Name
    email = other-account@email.com
```

Git automatically uses the matching identity based on which directory the repo is cloned into. No manual switching needed.

### SSH Keys for Multiple Accounts

Create separate SSH keys per account:
```bash
ssh-keygen -t ed25519 -C "account1@email.com" -f ~/.ssh/id_ed25519_personal_1
ssh-keygen -t ed25519 -C "account2@email.com" -f ~/.ssh/id_ed25519_personal_2
```

Then configure `~/.ssh/config`:
```
Host github-personal-1
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_personal_1

Host github-personal-2
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_personal_2
```

Clone repos using the alias:
```bash
git clone git@github-personal-1:username/repo.git    # uses key 1
git clone git@github-personal-2:username/repo.git    # uses key 2
```

---

## SSH Keys for GitHub

If you only have one GitHub account:

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
# Press Enter for default location (~/.ssh/id_ed25519)
# Set a passphrase (recommended) or press Enter for none

cat ~/.ssh/id_ed25519.pub
# Copy the output
```

Go to GitHub → Settings → SSH and GPG Keys → New SSH Key → paste the public key.

Test:
```bash
ssh -T git@github.com
# Should say: "Hi username! You've successfully authenticated..."
```

---

## Troubleshooting

### Script hangs during dnf operations
Slow mirrors. The script configures `fastestmirror=True` but RPM Fusion mirrors in particular can be slow from India. Wait it out — dnf retries automatically.

### `nvidia-smi` fails after reboot
Run `supergfxctl -g`. If it doesn't say "Hybrid", set it: `sudo supergfxctl -m Hybrid` and reboot again.

### SELinux notification pops up
Check the notification text. If it's about a process being denied access to a device or file, the fix pattern is always:
```bash
sudo ausearch -c 'process-name' --raw | sudo audit2allow -M my-policyname
sudo semodule -X 300 -i my-policyname.pp
```

### Flatpak permission error
The script uses `--user` scope for Flatpaks. If you see permission errors, try:
```bash
flatpak --user install flathub <app-id>
```

### `docker run` requires sudo
You need to log out and back in (or reboot) after the script adds you to the docker group. Verify with `groups` — "docker" should be listed.

### LazyVim first launch is slow / shows errors
Normal. First launch downloads and installs all plugins (~30 seconds). Some Treesitter parsers may show compilation messages. Close and reopen nvim — subsequent launches are instant.

### A specific stage failed
The script logs everything to `~/fedora-setup.log`. Check the log for the specific error. Fix the underlying issue (usually a network problem or missing dependency), then re-run the script. It will skip all completed stages and retry the failed one.

### Want to start completely fresh
```bash
rm -rf ~/.fedora-setup-state
./00-host-setup.sh --verbose
```

---

## Script Flags

| Flag | Effect |
|---|---|
| `--verbose` | Show all command output live (in addition to logging) |
| `--skip-nvidia` | Skip NVIDIA driver installation (for VMs or non-NVIDIA hardware) |
| `--skip-asus` | Skip ASUS ROG tool installation (for non-ASUS hardware) |
| `--reset-state` | Clear all state files and force a fresh run from Stage 1 |
| `--help` | Print usage information |

### Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `LOG_FILE` | `~/fedora-setup.log` | Custom log file path |
| `STEP_DELAY` | `1` | Seconds to pause between steps |
| `BANNER_DELAY` | `2` | Seconds to pause on stage banners |

---

## Known Hardware-Specific Decisions

These decisions are specific to the ASUS ROG Strix SCAR 16 G634JZR and may need adjustment for other hardware:

1. **`akmod-nvidia-open` over `akmod-nvidia`**: NVIDIA recommends the open kernel module for Ada Lovelace (RTX 40-series). On older cards (pre-Turing), use `akmod-nvidia` instead.

2. **`asusd-user.service` not created**: Crashes on Ada-era ROG models due to an upstream bug in the Aura RGB D-Bus object handling. System daemon `asusd` handles everything via D-Bus activation.

3. **SELinux policy `my-systemdlogind`**: Required specifically for hybrid-graphics laptops where `supergfxctl` manages GPU mode switching. May not be needed on single-GPU systems.

4. **`supergfxctl -m Hybrid`**: Sets hybrid GPU mode. Options on this hardware are `Integrated`, `Hybrid`, and `AsusMuxDgpu`. The script defaults to Hybrid for battery/performance balance.
