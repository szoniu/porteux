# CLAUDE.md — Project context for Claude Code

> Testing notes (shared `lib/dialog.sh` conventions across the 6 sibling installers, gum/TERM quirks, real-hardware test loop) → **[docs/TESTING-NOTES.md](docs/TESTING-NOTES.md)**.

## What this is

Interactive TUI installer for PorteuX Linux written in Bash. Goal: boot any live Linux ISO with networking, clone the repo, run `./install.sh` and be guided through the entire process from disk partitioning to a working PorteuX system. After a crash: `./install.sh --resume` scans disks and resumes from the last checkpoint.

## Architecture

### Single-process model

Unlike the Void/Gentoo installers (which use a two-process model with chroot), the PorteuX installer is **single-process** — no chroot needed. PorteuX is a modular live system where the "installation" is essentially extracting ISO contents to a partition and configuring the bootloader.

Flow: `TUI wizard → partition disk → download ISO → extract → configure bootloader → set persistence → optional modules → done`

### What makes PorteuX different

PorteuX is **NOT** a traditional Linux installation:
- **Slackware-based** — uses Slackware current (rolling) packages
- **Modular squashfs** — system is composed of `.xzm` modules (squashfs + zstd compression, AUFS overlay)
- **No package manager post-install** — the base system comes as pre-built modules
- **Init system**: sysvinit (traditional Slackware init)
- **Persistence via AUFS** — changes are stored in a separate overlay directory (`/porteux/changes/`)
- **8 desktop variants** — each is a separate ISO: cinnamon, cosmic, gnome, kde, lxde, lxqt, mate, xfce
- **No chroot** — no need to enter the installed system to configure it

### File structure

```
install.sh              — Entry point, argument parsing, phase orchestration
configure.sh            — Wrapper: exec install.sh --configure

lib/                    — Library modules (NEVER execute directly)
├── protection.sh       — Guard: checks $_PORTEUX_INSTALLER
├── constants.sh        — Global constants, paths, CONFIG_VARS[], CHECKPOINTS[]
├── logging.sh          — elog/einfo/ewarn/eerror/die/die_trace, colors, log to file
├── utils.sh            — try (interactive recovery), checkpoint_set/reached/validate, is_root/is_efi/has_network/ensure_dns, generate_password_hash, try_resume_from_disk
├── dialog.sh           — Wrapper gum/dialog/whiptail, primitives (msgbox/yesno/menu/radiolist/checklist/gauge/infobox/inputbox/passwordbox), wizard runner (register_wizard_screens + run_wizard), bundled gum extraction
├── config.sh           — config_save/load/set/get/dump/diff (${VAR@Q} quoting), validate_config()
├── hardware.sh         — detect_cpu/gpu(multi-GPU/hybrid)/disks/esp/installed_oses, detect_asus_rog, detect_surface, detect_bluetooth/fingerprint/thunderbolt/sensors/webcam/wwan, get_hardware_summary
├── disk.sh             — Two-phase: disk_plan_add/add_stdin/show/auto/dualboot → cleanup_target_disk + disk_execute_plan (sfdisk), mount/unmount_filesystems, get_uuid/get_partuuid, shrink helpers
├── network.sh          — check_network
├── iso.sh              — porteux_resolve_asset_url (GitHub release asset lookup), iso_get_url/download/verify/extract (_find_iso_file for resume)
├── modules.sh          — modules_list_installed, modules_download_optional, modules_ensure_locale_support (auto-load 08-multilanguage for non-base locales), modules_verify, _download_optional_module, _download_nvidia_module
├── bootloader.sh       — bootloader_install (_bootloader_install_efi uses the ISO's bundled EFI syslinux — NO GRUB; _bootloader_install_bios with syslinux), _update_syslinux_config (awk rewriter: DEFAULT label + persistence + UMPC, idempotent)
├── persistence.sh      — persistence_setup (_setup_persistent_changes), persistence_get_boot_param, persistence_clean
├── system.sh           — system_configure (hostname/timezone/locale/keymap), system_create_users (first-boot script via rc.local), system_finalize
├── hooks.sh            — maybe_exec 'before_X' / 'after_X'
└── preset.sh           — preset_export/import (hardware overlay)

tui/                    — TUI screens
├── welcome.sh          — screen_welcome: branding + prereq check
├── preset_load.sh      — screen_preset_load: skip/file/browse
├── hw_detect.sh        — screen_hw_detect: detect_all_hardware + summary
├── disk_select.sh      — screen_disk_select: disk + scheme (auto/dual-boot/manual) + _shrink_wizard()
├── filesystem_select.sh — screen_filesystem_select: ext4/fat32/btrfs/xfs
├── swap_config.sh      — screen_swap_config: none/partition/file
├── desktop_select.sh   — screen_desktop_select: 8 desktop variants (kde/xfce/lxqt/cinnamon/mate/gnome/lxde/cosmic)
├── gpu_config.sh       — screen_gpu_config: nvidia module yes/no, AMD/Intel info
├── persistence_config.sh — screen_persistence_config: changes (persistent) / none (immutable)
├── boot_mode_config.sh — screen_boot_mode_config: normal/copy2ram/fresh/text
├── module_select.sh    — screen_module_select: 05-devel, 08-multilanguage, 0050-multilib-lite
├── network_config.sh   — screen_network_config: hostname
├── locale_config.sh    — screen_locale_config: timezone + locale + keymap
├── user_config.sh      — screen_user_config: root pwd, user, groups
├── preset_save.sh      — screen_preset_save: optional export
├── summary.sh          — screen_summary: validate_config + full summary + "YES" + countdown
└── progress.sh         — screen_progress: resume detection + phase execution

data/                   — Static databases + bundled assets
├── gpu_database.sh     — nvidia_generation(), get_gpu_recommendation()
├── mirrors.sh          — PORTEUX_MIRRORS[], download source info
├── dialogrc            — Dark TUI theme
└── gum.tar.gz          — Bundled gum v0.17.0 binary (static ELF x86-64)

presets/                — Example configurations
tests/                  — Tests (bash, standalone)
hooks/                  — *.sh.example
```

### TUI screen conventions

Each screen is a `screen_*()` function that returns:
- `0` (`TUI_NEXT`) — proceed forward
- `1` (`TUI_BACK`) — go back
- `2` (`TUI_ABORT`) — abort

`run_wizard()` in `lib/dialog.sh` manages the screen index based on return code. Cancel in any dialog is treated as `TUI_BACK`.

### Configuration variables

All config variables are defined in `CONFIG_VARS[]` in `lib/constants.sh`:

| Variable | Values | Description |
|---|---|---|
| `TARGET_DISK` | /dev/sda, /dev/nvme0n1 | Target disk device |
| `PARTITION_SCHEME` | auto/dual-boot/manual | Partitioning strategy |
| `FILESYSTEM` | ext4/fat32/btrfs/xfs | Root filesystem type |
| `SWAP_TYPE` | none/partition/file | Swap configuration |
| `SWAP_SIZE_MIB` | integer | Swap size |
| `DESKTOP_VARIANT` | kde/xfce/lxqt/cinnamon/mate/gnome/lxde/cosmic | PorteuX desktop ISO variant |
| `ISO_URL` | URL | ISO download URL (auto-resolved or custom) |
| `BOOT_MODE` | normal/fresh/copy2ram/text | Default boot mode |
| `PERSISTENCE_MODE` | changes/none | Persistence mode (AUFS overlay) |
| `PERSISTENCE_SIZE_MIB` | integer | Persistence size (if limited) |
| `NVIDIA_MODULE` | yes/no | Download NVIDIA driver .xzm module |
| `ENABLE_DEVEL_MODULE` | yes/no | Download 05-devel module |
| `ENABLE_MULTILANG_MODULE` | yes/no | Download 08-multilanguage module |
| `ENABLE_MULTILIB_MODULE` | yes/no | Download 0050-multilib-lite module |
| `HOSTNAME` | string | System hostname (RFC 1123) |
| `TIMEZONE` | Region/City | e.g. `Europe/Warsaw` |
| `LOCALE` | locale string | e.g. `en_US.UTF-8` |
| `KEYMAP` | keymap name | e.g. `us`, `pl` |
| `ROOT_PASSWORD_HASH` | SHA-512 hash | Root password (never plaintext) |
| `USERNAME` | string | Regular user login |
| `USER_PASSWORD_HASH` | SHA-512 hash | User password |
| `USER_GROUPS` | comma-separated | e.g. `wheel,audio,video` |
| `GPU_VENDOR` | nvidia/amd/intel/none/unknown | Detected GPU |
| `ESP_PARTITION` | /dev/sdX1 | EFI System Partition |
| `ROOT_PARTITION` | /dev/sdX2 | Root partition |

### PorteuX-specific patterns

#### Modular system (no package manager)

PorteuX does NOT use a traditional package manager for system installation. The system is composed of squashfs modules:
- `000-kernel.xzm` — Linux kernel + firmware
- `001-core.xzm` — Core system (glibc, coreutils, etc.)
- `002-gui.xzm` — GUI base (X11/Wayland, mesa, etc.)
- `003-<desktop>.xzm` — Desktop environment module

These are pre-built and included in the ISO. The installer simply extracts them to disk.

#### AUFS persistence

PorteuX uses AUFS (Another Union File System) to layer squashfs modules. Changes go to a writable overlay:
- `changes=EXIT:/porteux` — boot parameter for persistence. The param points at
  the BASE dir `/porteux`; PorteuX itself creates a `changes/` subdirectory inside
  it for the AUFS overlay. The installer therefore pre-seeds config into
  `/porteux/changes` (= `PORTEUX_CHANGES_DIR`) while the boot param uses `/porteux`
  (= `PORTEUX_PERSISTENCE_DIR`). These two MUST stay distinct.
- `baseonly norootcopy` — immutable mode (no persistence)
- `copy2ram` — load all modules to RAM

#### Sysvinit (not systemd, runit, or dinit)

PorteuX uses traditional sysvinit with `/etc/rc.d/` scripts:
- Services controlled by `chmod +x /etc/rc.d/rc.<service>` (executable = enabled)
- Init scripts: `rc.S` (single-user), `rc.M` (multi-user), `rc.local` (custom)
- No `systemctl`, no `sv`, no `dinitctl`

#### User setup via first-boot script

Since PorteuX's `/etc/passwd` lives inside a read-only squashfs module, the installer creates a first-boot script (`/etc/rc.d/rc.porteux-setup`) that runs via `rc.local` and sets up user accounts in the writable AUFS layer.

#### Slackware conventions

- Hostname: `/etc/HOSTNAME` (Slackware) + `/etc/hostname` (standard)
- Locale: `/etc/profile.d/lang.sh` (not `/etc/locale.conf`)
- Keymap: `/etc/rc.d/rc.keymap` (not `/etc/vconsole.conf`)
- Timezone: `/etc/localtime` symlink + `/etc/localtime-copied-from/.tz`
- Package management: `installpkg`, `removepkg`, `upgradepkg` (Slackware tools, NOT used during installation)

#### ISO download and extraction

The installer resolves the official PorteuX ISO for the selected desktop variant from the `porteux/porteux` GitHub release assets (matching `porteux-*-<variant>-*-x86_64.iso`), downloads it, mounts it, and copies all contents to the target partition. This is fundamentally different from other installers that download a base system and build upon it.

#### Boot directory structure on target

```
/boot/syslinux/vmlinuz      — Linux kernel
/boot/syslinux/initrd.zst   — Initial ramdisk (zstd compressed)
/boot/syslinux/porteux.cfg  — Syslinux configuration
/EFI/BOOT/bootx64.efi       — EFI bootloader (syslinux; lowercase filename)
/porteux/modules/            — Base system modules (auto-loaded)
/porteux/optional/           — Optional modules (manual activation)
/porteux/changes/            — Persistence overlay directory
```

### Checkpoints

`checkpoint_set "name"` creates a file in `$CHECKPOINT_DIR`. `checkpoint_reached "name"` checks for it. After mounting the target disk, checkpoints migrate to `${MOUNTPOINT}/tmp/porteux-installer-checkpoints/`.

Phases: preflight → disks → iso_download → iso_verify → iso_extract → bootloader → persistence → optional_modules → system_config → users → finalize

### Two-phase disk operations

Identical to Void installer: `disk_plan_auto()` / `disk_plan_dualboot()` → `disk_execute_plan()` using sfdisk stdin scripts.

### Function `try`

`try "description" command args...` — on failure displays Retry/Shell/Continue/Log/Abort menu. Every command that can fail MUST go through `try`.

### gum TUI backend

Bundled in `data/gum.tar.gz`. Priority: gum > dialog > whiptail. Static binary, zero dependencies.

## Testing plan

### Unit tests (offline, no root, no hardware)

```bash
bash tests/test_config.sh        # Config save/load round-trip + validation
bash tests/test_hardware.sh      # GPU database lookups (TODO)
bash tests/test_disk.sh          # Disk planning dry-run with sfdisk scripts (TODO)
bash tests/test_checkpoint.sh    # Checkpoint set/reached/clear/validate (TODO)
```

All unit tests use `DRY_RUN=1` and `NON_INTERACTIVE=1`. They must:
- Export `_PORTEUX_INSTALLER=1`
- Never require root or hardware
- Use `_RESUME_TEST_DIR` for fake filesystems where needed

### Integration tests (VM, requires root)

These tests should be run in a QEMU/KVM or VirtualBox VM with networking:

#### Test 1: Full dry-run wizard
```bash
./install.sh --dry-run
# Verify: all 16 TUI screens render, config file is generated, no disk operations
```

#### Test 2: Config round-trip
```bash
./install.sh --configure                              # Generate config
cat /tmp/porteux-installer.conf                       # Verify all variables saved
./install.sh --install --config /tmp/porteux-installer.conf --dry-run  # Verify load
```

#### Test 3: Full installation on empty disk (QEMU)
```bash
# Host: create test VM
qemu-img create -f qcow2 test-porteux.qcow2 20G
qemu-system-x86_64 -m 4096 -smp 4 \
    -drive file=test-porteux.qcow2,format=qcow2 \
    -cdrom <any-live-iso>.iso \
    -bios /usr/share/ovmf/OVMF.fd \
    -enable-kvm -nic user

# Inside VM:
git clone https://github.com/szoniu/porteux.git && cd porteux
./install.sh
# Select: auto partition → /dev/vda → ext4 → kde → persistent → normal boot
# Verify: ISO downloads, extracts, bootloader installs, reboot works
```

#### Test 4: Installation on empty disk (BIOS mode)
```bash
# Same as Test 3 but without -bios OVMF (legacy BIOS)
# Verify: syslinux installed, MBR written, boots correctly
```

#### Test 5: Dual-boot with existing Linux
```bash
# Pre-install another Linux on /dev/vda1-vda2
# Run PorteuX installer with dual-boot scheme
# Verify: ESP reused, separate UEFI boot entry for PorteuX (no GRUB), both boot via firmware boot menu
```

#### Test 6: Resume after interruption
```bash
./install.sh
# Let it run through disk partitioning + ISO download
# Kill with Ctrl+C during ISO extraction
./install.sh --resume
# Verify: resumes from iso_extract, doesn't re-partition or re-download
```

#### Test 7: Persistence verification
```bash
# After full install, boot into PorteuX
# Create a file: touch /root/test-persistence
# Reboot
# Verify: /root/test-persistence still exists (persistence mode)
```

#### Test 8: Immutable mode verification
```bash
# Install with PERSISTENCE_MODE=none
# Boot, create file, reboot
# Verify: file is gone (immutable mode)
```

#### Test 9: Copy to RAM mode
```bash
# Install with BOOT_MODE=copy2ram
# Boot, verify system loads into RAM
# Remove boot media (or unmount)
# Verify: system still works
```

#### Test 10: Optional modules
```bash
# Install with ENABLE_DEVEL_MODULE=yes
# Verify: 05-devel.xzm present in /porteux/optional/
# Activate: activate 05-devel.xzm
# Verify: gcc --version works
```

#### Test 11: NVIDIA module download
```bash
# Install on VM with NVIDIA GPU passthrough (or just test download)
# Select NVIDIA_MODULE=yes
# Verify: NVIDIA driver module downloaded to /porteux/optional/ (upstream ships it as nvidia-driver-current.zip → extracted to .xzm)
```

#### Test 12: User setup on first boot
```bash
# After install, boot into PorteuX
# Verify: root password changed from default "toor"
# Verify: user account exists with correct groups
# Verify: /etc/.porteux-setup-done marker exists
```

#### Test 13: SSH remote installation
```bash
# Boot Live ISO on target machine
# Configure SSH (see README)
# From remote machine: ssh root@<IP> and run installer
# Verify: entire wizard works over SSH, installation completes
```

#### Test 14: Preset save/load across machines
```bash
# Machine A: ./install.sh --configure → save preset
# Machine B: ./install.sh --config preset.conf --dry-run
# Verify: portable values loaded, hardware values re-detected
```

#### Test 15: All 8 desktop variants
```bash
# For each variant in {kde,xfce,lxqt,cinnamon,mate,gnome,lxde,cosmic}:
#   - Install with DESKTOP_VARIANT=<variant>
#   - Verify: correct ISO downloaded, boots to correct desktop
```

#### Test 16: FAT32 filesystem (USB portability)
```bash
# Install with FILESYSTEM=fat32 on a USB drive
# Boot from USB on different machines
# Verify: PorteuX boots, modules load correctly
```

### Edge cases to test

- Installer run without network → should fail at preflight with clear message
- Installer run as non-root → should fail at preflight
- Disk with existing partitions → cleanup_target_disk should handle
- Very small disk (< 4 GiB) → should reject at disk_select
- GitHub release asset redirect (302 → objects.githubusercontent.com) → curl -L should follow
- Interrupted ISO download → resume should re-download
- Invalid ISO (truncated) → iso_verify should catch (size check)
- gum binary missing → should fall back to dialog/whiptail/text

## SSH remote installation

PorteuX (Slackware-based) uses sysvinit, not runit. SSH setup differs from Void:

```bash
# On target machine (booted from PorteuX Live or any Live ISO):

# 1. Set root password
passwd root

# 2. Start sshd (PorteuX Live may have it pre-installed)
# If sshd is available:
chmod +x /etc/rc.d/rc.sshd    # Slackware: make executable = enable
/etc/rc.d/rc.sshd start

# If sshd is NOT available (e.g. running from another Live ISO):
# Install openssh for that distro, then start sshd

# 3. Allow root login (if not already)
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
/etc/rc.d/rc.sshd restart

# 4. Check IP
ip -4 addr show | grep inet

# 5. Verify
ss -tlnp | grep 22    # should show LISTEN
```

From remote machine:
```bash
ssh root@<IP>
git clone https://github.com/szoniu/porteux.git
cd porteux

# IMPORTANT: Always use tmux/screen to protect against SSH disconnection
tmux new -s install
./install.sh
```

If SSH connection drops:
```bash
ssh root@<IP>
tmux attach -t install
# Installation continues in background — nothing lost
```

Monitoring from second terminal:
```bash
ssh root@<IP>
tail -f /tmp/porteux-installer.log
```

## Known patterns and pitfalls

- `(( var++ ))` at var=0 returns exit 1 under `set -e` — always add `|| true`
- `lib/constants.sh` uses `: "${VAR:=default}"` instead of `readonly` so tests can override
- `lib/protection.sh` checks `$_PORTEUX_INSTALLER` — tests must export this
- `config_save` uses `${VAR@Q}` (bash 4.4+), creates files with `umask 077`
- `config_load` sources a filtered temp file (only known CONFIG_VARS)
- Files in lib/ are NEVER executed directly — always sourced
- **No chroot**: Unlike Void/Gentoo/Chimera installers, PorteuX never enters the installed system
- **ISO extraction, not package installation**: The system is pre-built; we just copy it
- **AUFS changes directory**: Must exist before first boot for persistence to work
- **First-boot user setup**: Users are created at first boot, not during installation, because `/etc/passwd` is read-only in the squashfs module
- **rc.local for automation**: PorteuX uses `/etc/rc.d/rc.local` for first-boot scripts (sysvinit)
- **GitHub release downloads**: ISO + module URLs are RESOLVED from the `porteux/porteux` GitHub release assets (`porteux_resolve_asset_url` in `iso.sh`), never hand-constructed — filenames embed per-variant app versions and date stamps (e.g. `porteux-2.6-current-lxqt-2.3.0-x86_64.iso`, `08-multilanguage-current-20260228.xzm`). Asset URLs redirect, so curl needs `-L`.
- **Persistence dir is split**: boot param uses `PORTEUX_PERSISTENCE_DIR` (`/porteux`); config is written to `PORTEUX_CHANGES_DIR` (`/porteux/changes`). Don't conflate them.
- **EFI is syslinux, not GRUB**: the ISO ships `EFI/BOOT/bootx64.efi` whose `syslinux.cfg` does `INCLUDE ../../boot/syslinux/porteux.cfg`; the ESP needs BOTH `/EFI/BOOT` and `/boot/syslinux`. All boot config lives in `porteux.cfg` (single source for BIOS + EFI).
- **Non-base locales need a module**: base glibc only has `C`/`en_US`. Selecting any other locale (pl_PL, de_DE, en_GB...) auto-downloads `08-multilanguage` (glibc-i18n) into the auto-loading `/porteux/modules/` (see `modules_ensure_locale_support`).
- **Dual-boot root partition**: never guess the partition number after `sfdisk --append` (GPT gaps make `count+1` point at an existing partition) — detect the new device by diffing the partition list before/after, then format.
- **FAT32 filesystem option**: PorteuX can run from FAT32 (maximum USB portability), but this limits file sizes to 4 GB

## How to add a new TUI screen

1. Create `tui/new_screen.sh` with a `screen_new_screen()` function
2. Add `source "${TUI_DIR}/new_screen.sh"` in `install.sh`
3. Add `screen_new_screen` to `register_wizard_screens` in `run_configuration_wizard()`
4. The screen must return `TUI_NEXT`/`TUI_BACK`/`TUI_ABORT`

## How to add a new configuration variable

1. Add the name to `CONFIG_VARS[]` in `lib/constants.sh`
2. Set the value in the appropriate TUI screen + `export`
3. Use it in the appropriate `lib/` module

## How to add a new installation phase

1. Add the checkpoint name to `CHECKPOINTS[]` in `lib/constants.sh`
2. Add an entry to `INSTALL_PHASES[]` in `tui/progress.sh`
3. Add logic to `_execute_phase()` in `tui/progress.sh`
4. The phase will automatically be skipped on resume if its checkpoint exists
