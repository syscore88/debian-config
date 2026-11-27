# 🌀 Debian 13 (Trixie) Post-Install Setup Script

A comprehensive, automated Bash post-installation script for **Debian 13 "Trixie"**. It configures APT repositories (including third-party ones), removes unwanted default apps, detects your GPU and installs matching drivers/32-bit libraries, installs a large curated set of system/multimedia/gaming packages plus Flatpak and standalone `.deb` packages, sets up Wine, configures virtualization (libvirt/QEMU) and the firewall, configures the GRUB boot splash, and sets up Zsh with Oh My Zsh and Powerlevel10k.

The script auto-detects the system language (Polish/English) from the `LANG`/`LC_ALL` locale and prints all status messages accordingly.

---

## 🚀 Script Features

- **Temporary Passwordless Sudo**: Requests the admin password once at the start, then configures a temporary `NOPASSWD` rule (via `/etc/sudoers.d/`, or a `polkit`/`run0` rule on systems without `visudo`) so the rest of the script can run unattended. The rule is automatically removed at the end.
- **APT Repository Configuration**:
  - Comments out the CD-ROM source, enables the `i386` architecture, and adds `contrib non-free non-free-firmware` components to the default sources.
  - Adds the `<codename>-backports` repository if not already present.
  - Adds the official **Google Chrome** and **Brave Browser** APT repositories with their signing keys.
  - Runs `apt-get full-upgrade` after updating.
- **`wait_for_apt` Locking Helper**: Stops PackageKit and waits for any existing APT/dpkg locks to clear before every package operation, avoiding "could not get lock" failures.
- **Firmware & Bloatware**: Installs `isenkram-cli` and non-free firmware, then auto-installs recommended hardware firmware; purges a long list of default KDE/GNOME apps (`konqueror`, `kontact`, `kmail`, `korganizer`, `akonadi-server`, `epiphany`, `rhythmbox`, `evolution`, etc.) along with their leftover config/cache directories, and disables the KWallet secret service.
- **Package Installation**: Installs a large curated `PACKAGES_INSTALL` set covering browsers (Chrome, Brave), office/media apps (Thunderbird, GIMP, Krita, Kdenlive, Audacity, VLC...), dev tools (`gcc`, `cmake`, `meson`, `ninja-build`, `build-essential`, `git`...), and the gaming/Proton stack (`gamemode`, `mangohud`, `vulkan-tools`, `vkd3d-compiler`, `goverlay`); installs Telegram from backports if it's not in the main repo.
- **GPU Detection & Driver Setup**: Detects NVIDIA/AMD/Intel GPUs (and hybrid setups) via `lspci`, installs matching 32-bit Mesa/Vulkan/NVIDIA libraries, adds the correct kernel modules to `/etc/initramfs-tools/modules`, and rebuilds the initramfs.
- **Wine & Winetricks**: Installs `winetricks` directly from its GitHub source (falling back to the distro package); tries the distro's `wine`/`wine64`/`wine32:i386` first, and if that fails, purges it and installs the official **WineHQ** repository + `winehq-stable` instead, along with 32-bit audio/OpenGL/MangoHud libraries.
- **Flatpak & Standalone `.deb` Packages**: Adds the Flathub remote and installs Flatseal + Gear Lever; downloads and installs Discord, `ls-fg`/`ls-fg-vk`, and Faugus Launcher directly as `.deb` files (Discord from its official download endpoint, the others via the GitHub Releases API).
- **Virtualization & Firewall**: Installs `virt-manager`, `qemu-system`, `libvirt-daemon-system`, `ovmf`, and related tools; imports default `virt-manager` GUI preferences via `dconf load`; enables `libvirtd`/`virtqemud`; defines/starts/autostarts the default libvirt NAT network; resets and configures **UFW** (deny incoming by default, allow SSH, allow `virbr0` traffic and the libvirt subnet), and adds the user to the `libvirt`/`libvirt-qemu`/`kvm` groups.
- **Boot Splash (GRUB)**: Appends the standard silent-splash kernel parameters (`quiet splash loglevel=3 systemd.show_status=false rd.udev.log_level=3 ...`) to `GRUB_CMDLINE_LINUX_DEFAULT`, sets `GRUB_TIMEOUT=0`, sets the Plymouth theme to `bgrt`, and runs `update-grub` + `update-initramfs`.
- **System Tuning & DNS**: Enables `fstrim.timer`, vacuums the journal to 2 days, and sets Cloudflare (`1.1.1.2`/`1.0.0.2` + IPv6) as the system and NetworkManager DNS, applying it to the active connection.
- **Shell Setup**: If `zsh` is available, sets it as the default shell, installs Oh My Zsh (unattended) and the Powerlevel10k theme, and updates `~/.zshrc` (theme, plugins, locale export, `fastfetch` on login, syntax-highlighting/autosuggestions sourcing).
- **Dotfiles & Config Copy**: Copies an optional `.update.sh` helper script plus `.local`/`.config` directories from the script folder into the user's home directory.
- **Progress Bar & Logging**: Displays a live progress bar across 3 phases / 12 steps. On failure, a detailed log is saved to `~/install_error_<timestamp>.log`.
- **Optional Reboot Prompt**: Asks **"Do you want to restart the system now? [Y/N]"** at the end instead of forcing a reboot.

---

## 🔍 Module Details

### 1. Permissions & Repository Setup
Grants temporary `NOPASSWD` sudo, waits for any APT locks, enables `i386`, adds `contrib`/`non-free`/`non-free-firmware` and backports, adds the Google Chrome and Brave repositories with their keys, and runs a full upgrade.

### 2. Firmware & Bloatware Cleanup
Installs recommended firmware via `isenkram-cli`, purges the predefined list of default KDE/GNOME applications and their leftover config/cache, and disables KWallet if KDE Plasma is present.

### 3. Package & Driver Installation
Installs the curated package set, sets up Wine/Winetricks (with a WineHQ repository fallback), detects the GPU vendor(s) and installs matching 32-bit driver packages and initramfs kernel modules, then rebuilds the initramfs.

### 4. Flatpak & `.deb` Extras
Adds Flathub and installs Flatseal/Gear Lever, then downloads and installs Discord, `ls-fg`/`ls-fg-vk`, and Faugus Launcher as standalone `.deb` packages (resolved dynamically via the Discord download endpoint and GitHub Releases API).

### 5. Virtualization, Firewall & Boot Splash
Installs and configures `virt-manager`/QEMU/libvirt with a default NAT network and imported GUI preferences, locks down the firewall with UFW while allowing libvirt/SSH traffic, and configures the GRUB boot splash (silent kernel cmdline, zero timeout, Plymouth `bgrt` theme).

### 6. Shell & Finalization
Sets up Zsh + Oh My Zsh + Powerlevel10k (if `zsh` is present), configures Cloudflare DNS, removes the temporary sudo/polkit rule, and prompts the user to reboot immediately or exit without rebooting.

---

### Adding a user to the sudo group:
```bash
sudo usermod -aG sudo $USER
```
 🚀 How to Run

 1. Clone your repository
```bash
git clone https://github.com/syscore88/debian-config.git
```

2. Enter the downloaded folder
```bash
cd debian-config
```

3. Make the install.sh script executable
```bash
chmod +x install.sh
```

4. Run the script
   > ⚠️ **IMPORTANT:** Run the script as a **regular user** (NOT as root/sudo). The script will ask for the administrator password at the start to configure              temporary elevated privileges.
  ```bash
   ./install.sh
   ```
---

### ☕ Support the Project

If you find this tool helpful and it saved you some time, consider buying me a coffee to support further development! 

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/bartekszczecinski)

---

If you find this project useful, leave a star! ⭐

---

## ⚠️ Requirements & Notes

- A base **Debian 13 (Trixie)** installation with `apt` and an internet connection (packages come from the official repos, backports, Google/Brave/WineHQ repos, Flathub, and GitHub releases).
- `sudo` access for the current user.
- The following optional files, placed alongside `install.sh`, are picked up automatically if present: `.update.sh`, `.local/`, `.config/`.
- The script **installs a large number of packages** (development, multimedia, gaming, Wine, and full KVM/QEMU virtualization) and **modifies the firewall to deny incoming traffic by default** — review `PACKAGES_INSTALL` and the UFW rules before running if that doesn't match your needs.
- Boot splash configuration assumes **GRUB** is the active bootloader; other bootloaders are not handled by this script.
- On failure, check the generated `install_error_<timestamp>.log` file in your home directory for details.
