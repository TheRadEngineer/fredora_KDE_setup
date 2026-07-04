# Debloat Script — `00a-debloat.sh` (v2)

Removes pre-installed bloatware from a fresh **Fedora 44 KDE Plasma** install and cleans up every trace — config files, cache, data directories, desktop menu entries, icon cache, and KDE's internal app database. After running, it's as if these apps were never installed.

**Run this BEFORE `00-host-setup.sh`.** Debloating first means faster system upgrades, a cleaner Snapper baseline, and less disk wasted from the start.

### Key design choice: individual package removal

Unlike typical debloat scripts that remove packages in bulk transactions, this script removes each package **individually**. If a package turns out to be dependency-protected (removing it would break the desktop), it's gracefully skipped and clearly reported — without blocking any other package from being removed.

This was learned the hard way: in v1, one protected package in a group of 21 caused all 21 to be skipped.

---

## Quick Start

```bash
chmod +x 00a-debloat.sh

# Preview what will be removed (touches nothing):
./00a-debloat.sh --dry-run

# Run for real:
./00a-debloat.sh
```

---

## What It Does (6 Phases)

### Phase 1 — Stop services from apps being removed

Before removing packages, the script stops any running services that belong to those apps. This prevents errors during removal and avoids orphaned processes.

Specifically:
- **Akonadi** (KDE PIM's database backend) — stopped via `akonadictl stop`
- **MariaDB** — stopped and disabled via systemctl
- **ibus** (input method framework) — stopped via user systemctl

### Phase 2 — Remove packages via dnf

Removes all listed packages using `dnf remove -y`, grouped by category and processed in dependency-safe order (KDE PIM/Akonadi first, since they have the most complex dependency web).

dnf automatically removes files installed by the RPM. However, it does NOT remove user-generated config, cache, or data files — that's what Phases 4-6 handle.

### Phase 3 — Remove orphaned dependencies

Runs `dnf autoremove` to clean up any libraries that were only installed as dependencies of the removed packages and are no longer needed by anything else.

### Phase 4 — Clean leftover traces in your home directory

This is the "never installed" part. After dnf removes the package files, apps still leave behind:

- **`~/.config/<app>/`** — user configuration (window positions, preferences, account settings)
- **`~/.local/share/<app>/`** — user data (mail databases, game save files, contact lists)
- **`~/.cache/<app>/`** — cached data (thumbnails, search indexes)
- **System directories** — `/var/lib/mysql/`, `/var/lib/akonadi/`, `/etc/my.cnf.d/`, stale autostart entries

The script removes all of these for every app in the removal list. It also scans `~/.config/autostart/` for `.desktop` files that reference binaries that no longer exist, and removes those too.

### Phase 5 — Clean stale user systemd units

Scans `~/.config/systemd/user/` and `~/.local/share/systemd/user/` for unit files whose `ExecStart` binary no longer exists. Disables and removes them, then reloads the user systemd daemon.

### Phase 6 — Rebuild desktop and icon caches

After removing packages and their traces, several caches need rebuilding so the desktop reflects the changes:

- **XDG desktop database** (`update-desktop-database`) — removes phantom entries from the application menu
- **MIME type database** (`update-mime-database`) — removes file associations for uninstalled apps
- **Icon cache** (`gtk-update-icon-cache`) — removes leftover icons
- **Baloo file index** (`balooctl6 purge`) — removes stale search index entries
- **KDE KSycoca cache** (`kbuildsycoca6 --noincremental`) — forces KDE to rebuild its internal service/application database from scratch, which is what actually makes removed apps disappear from the app launcher, right-click menus, and "Open With" dialogs

If any phantom menu entries somehow persist after all this, a simple log-out and log-in clears them (SDDM rebuilds the session state on login).

---

## What Gets Removed

### LibreOffice (~350 MB)

The full office suite: Calc (spreadsheets), Writer (documents), Draw (diagrams), Impress (presentations), Math (formulas), and help files. If you need office tools later, use Google Docs/Sheets in the browser or install LibreOffice from Flatpak (sandboxed, doesn't touch the system).

### KDE PIM (~170 MB)

The entire Personal Information Management stack:
- **KMail** — email client
- **Kontact** — unified PIM dashboard
- **KOrganizer** — calendar/planner
- **KAddressBook** — contacts manager
- **Akregator** — RSS feed reader
- **Akonadi** — the backend database that all of the above depend on (runs a full MySQL instance just for email — yes, really)
- All supporting libraries, import wizards, migration agents, and sieve filter editors

This is one of the biggest wins. Akonadi alone consumes significant RAM and disk I/O even when you never use KMail.

### KDE Games (~15 MB)

KMahjongg, KMines, KPat (solitaire), and their shared game libraries. You have Steam for gaming.

### Unnecessary Apps (~80 MB)

Apps that don't fit a dev/robotics/gaming workflow:
- **Dragon Player** — video player (VLC or browser handles this)
- **Kamoso** — webcam recording (not needed)
- **KMouth** — speech synthesis frontend (accessibility tool)
- **KolourPaint** — basic paint app (not needed alongside real editors)
- **KWrite** — simple text editor (you have Neovim + VS Code)
- **KCharSelect** — unicode character picker
- **Skanpage** — scanner frontend (no scanner)
- **KHelpCenter** — offline KDE documentation browser
- **NeoChat** — Matrix/Element chat client
- **Kleopatra** — certificate and key management
- **KRDC/KRDP/KRFB** — remote desktop client/server (you'll SSH instead)
- **Qrca** — QR code reader (phone does this)
- **Elisa** — music player (browser-based streaming)
- **KCalc** — calculator
- **KDebugSettings** — KDE internal debug logging (for KDE developers, not app developers)
- **KNighttime** — world clock
- **Plasma Welcome/Setup** — first-run wizards (already seen them)

### MariaDB (~70 MB)

A full MySQL-compatible database server. No idea why Fedora KDE ships this on a desktop. Removed. If you need a database later, run it in a Docker container (which is better practice anyway).

### Printer Drivers (~65 MB)

HPLIP (HP printer drivers) and Gutenprint (generic printer drivers). You don't have a printer. **Plasma Print Manager is kept** — it provides the "Print to PDF" functionality that KDE apps use when you select File → Print → Print to File.

### Accessibility/Speech (~75 MB)

Orca (screen reader), speech-dispatcher (text-to-speech daemon), espeak-ng (speech synthesizer), and flite (lightweight speech synthesis). These run background services even when unused.

### Input Methods / ibus (~156 MB)

The entire input method framework: ibus daemon, panel, setup, and language-specific engines (Japanese, Chinese, Korean, Hindi via m17n). Plus the dictionary data files (anthy-unicode for Japanese, libpinyin-data for Chinese).

If you ever need to type in a non-Latin script later, install `fcitx5` instead — it's lighter and doesn't auto-start on every login like ibus does.

### VM Guest Tools (~5 MB)

VMware tools, VirtualBox guest additions, and SPICE agent. You're running on bare metal hardware, not inside a VM.

### Installer Leftovers (~15 MB)

The Fedora installer (Anaconda) and Fedora Media Writer. You already installed the OS and created the USB. These serve no purpose on an installed system.

### Miscellaneous (~55 MB)

- **GNOME ABRT / abrt-gui** — crash reporter GUIs. CLI crash reporting (`abrt-cli`) stays.
- **Toolbox** — Red Hat's container tool. Replaced by Distrobox in the setup script.

---

## What Gets Kept

The script **never touches** any of these:

### Core Desktop
- Plasma Desktop, KWin (window manager), SDDM (login screen), Plasma Workspace
- System Settings, Plasma System Monitor, KInfoCenter
- All Plasma panels, widgets, themes (Breeze), wallpapers

### Essential Apps
- **Dolphin** — file manager
- **Konsole** — terminal emulator
- **Spectacle** — screenshot tool
- **Ark** — archive manager (zip, tar, 7z)
- **Okular** — PDF and document viewer
- **Gwenview** — image viewer
- **KFind** — file search GUI
- **Filelight** — disk usage visualization

### System Tools
- **KDE Connect** — phone ↔ laptop integration
- **KDE Partition Manager** — disk management
- **KWallet Manager** — password storage (used by git, SSH, browsers)
- **Plasma Network Manager** (all VPN plugins)
- **Plasma Print Manager** — kept for Print-to-PDF
- **Plasma Discover** — Flatpak app store GUI
- **Plasma Vault** — encrypted folder management
- **Plasma Disks** — SMART disk health monitoring
- **Plasma Thunderbolt** — Thunderbolt device management
- **KDE Network File Sharing** — Samba/LAN sharing
- **KDE Inotify Survey** — file system monitoring

### System Libraries
- All `kf6-*`, `plasma-*`, `kde-settings-*`, `libblockdev-*`, and Qt libraries are untouched

---

## Customizing the Removal List

Open `00a-debloat.sh` and edit the arrays at the top. Each category is a separate bash array:

```bash
REMOVE_OFFICE=(
    libreoffice-calc
    libreoffice-core
    # libreoffice-writer    ← commented out = kept
    ...
)
```

To **keep** a package: comment it out with `#`

To **add** a package: add its name on a new line. Run `rpm -q <package-name>` first to verify it's installed and get the exact name.

The trace-cleanup arrays (`CONFIG_DIRS_TO_CLEAN`, `DATA_DIRS_TO_CLEAN`, `CACHE_DIRS_TO_CLEAN`) are further down in the script. If you add a new package to remove, add its config/data directory names to those arrays too.

---

## Flags

| Flag | Effect |
|---|---|
| `--dry-run` | Show everything that would be removed (packages + trace directories) without changing anything |
| `--yes` / `-y` | Skip the interactive confirmation prompt |
| `--help` | Print usage |

### Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `LOG_FILE` | `~/fedora-debloat.log` | Custom log file path |

---

## Troubleshooting

### "Package X is protected" or "removal would break dependencies"

Some packages are dependencies of core Plasma. dnf will refuse to remove them and show a dependency error. This is dnf protecting you — do NOT force it with `--noautoremove` or `--nodeps`. Instead, comment out that package in the removal array and re-run.

### App still appears in the menu after debloat

The script rebuilds KSycoca (KDE's app cache) at the end, which should clear it. If a phantom entry persists: log out and log back in. SDDM rebuilds the full session state on login.

### Removed something I actually needed

If you haven't run `00-host-setup.sh` yet (which sets up Snapper), you'll need to reinstall manually:

```bash
sudo dnf install <package-name>
```

If Snapper was already set up, you can roll back:

```bash
sudo snapper -c root list        # find the pre-debloat snapshot
sudo snapper -c root undochange N..M
```

This is one reason we recommend running debloat BEFORE setup — Snapper isn't active yet, but you also haven't built anything worth protecting yet.

### ibus removal broke my keyboard

If you type in Hindi, Chinese, Japanese, Korean, or any script that needs an input method engine, you need ibus (or an alternative like fcitx5). Reinstall:

```bash
sudo dnf install ibus
# Or for the lighter alternative:
sudo dnf install fcitx5 fcitx5-configtool
```

---

## Estimated Savings

| Category | Size |
|---|---|
| LibreOffice | ~350 MB |
| KDE PIM + Akonadi | ~170 MB |
| Input Methods (ibus) | ~156 MB |
| Accessibility/Speech | ~70 MB |
| MariaDB | ~70 MB |
| Printer Drivers | ~65 MB |
| Unnecessary Apps | ~60 MB |
| Misc + VM + Games + Installer | ~90 MB |
| Orphaned dependencies (autoremove) | ~100-200 MB |
| **Total** | **~1.1 - 1.3 GB** |

Actual savings vary depending on what Fedora ships in the specific install media you used and what dependencies get auto-removed.

---

## Packages That CANNOT Be Removed (Dependency-Protected)

These packages look removable but are actually dependencies of the core Plasma desktop. The script deliberately does not list them, but if you try to add them, dnf will refuse and the script will skip them gracefully.

| Package | Why it's protected |
|---|---|
| `knighttime` | Despite the name, this is NOT a world clock app. It provides `libKNightTime.so.0` which `plasma-workspace-libs` depends on. It's a core Plasma library. |
| `plasma-setup` | Provides `libklookandfeel.so.6`, `libnotificationmanager.so.1`, `libtaskmanager.so.6` — all required by `plasma-desktop`. |
| `plasma-welcome` | Dependency of `plasma-setup`. Removing it breaks the chain. |
| `plasma-welcome-fedora` | Fedora-specific component of plasma-welcome. Same dependency chain. |
| `flite` | Text-to-speech library. Dependency chain: `flite` → `libavfilter-free` (FFmpeg filters) → `kpipewire` (screen recording/PipeWire) → `plasma-desktop`. Removing flite breaks screen recording and PipeWire integration. |
| `speech-dispatcher` | May be protected on some installs depending on what pulls it in. The script attempts removal individually — if it fails, it's kept gracefully. |

**How the script handles these:** each package is removed in its own dnf transaction. If it fails (dependency-protected), the script prints `✗ packagename (dependency-protected, kept)` and moves on. No other packages are affected. At the end, a summary shows exactly what was kept and why.
