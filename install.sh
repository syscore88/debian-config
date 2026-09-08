#!/bin/bash
# ==========================================================
# KOMPLEKSOWY SKRYPT KONFIGURACYJNY SYSTEMU (DEBIAN 13)
# ==========================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/sbin:/sbin:$PATH" 

detect_system_lang() {
    local sys_lang="${LANG:-}"
    [[ -z "$sys_lang" ]] && sys_lang="${LC_ALL:-${LC_MESSAGES:-}}"
    if [[ "$sys_lang" == pl* ]]; then
        echo "pl"
    else
        echo "en"
    fi
}
SCRIPT_LANG="$(detect_system_lang)"

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[0;33m'
ERR='\033[0;31m'
NC='\033[0m'

TMP_LOG="$(mktemp /tmp/install-log.XXXXXX)"
LOG_FILE="$HOME/install_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

cleanup_on_exit() {
    local exit_code=$?
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}✖ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
        else
            echo -e "${ERR}✖ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
        fi
    fi
    rm -f "$TMP_LOG"
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${SUCCESS}✔ $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${ERR}✘ ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${WARN}⚠ WARN: $m${NC}"; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    local bar_width=50
    local reserved=12
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 1))}…"
    fi

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ $filled -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ $empty -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
}

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    MSG_PHASE_1="[1/3] Konfiguracja i optymalizacja systemu..."
    MSG_PHASE_2="[2/3] Instalacja pakietów systemowych, Flathub i paczek .deb..."
    MSG_PHASE_3="[3/3] Konfiguracja usług, bootloadera i środowiska..."
else
    MSG_PHASE_1="[1/3] System configuration and optimization..."
    MSG_PHASE_2="[2/3] Installing system, Flathub, and .deb packages..."
    MSG_PHASE_3="[3/3] Configuring services, bootloader, and environment..."
fi

TOTAL_STEPS=12
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CURRENT_USER=$(whoami)
DEB_DIR="/tmp/debs_$$"

if [[ "$EUID" -eq 0 ]]; then
    echo -e "${ERR}✖ Nie uruchamiaj skryptu jako root. Użyj zwykłego użytkownika z sudo.${NC}" >&3
    exit 1
fi

printf '\033[?7h\n' >&3

RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1 || sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

sudo -v

if [[ "$USE_RUN0" -eq 1 ]]; then
    printf 'polkit._run0_nopasswd.push("%s");\n' "$CURRENT_USER" | sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null
    sudo systemctl try-restart polkit 2>/dev/null || true
else
    SUDOERS_TMP="$(mktemp)"
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    chmod 0440 "$SUDOERS_TMP"
    if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null; then
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
    else
        rm -f "$SUDOERS_TMP"
        echo -e "${ERR}✖ Nieprawidłowa składnia pliku sudoers – przerywam.${NC}" >&3
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
fi

printf '\033[?7l' >&3

wait_for_apt() {
    sudo systemctl stop packagekit 2>/dev/null || true
    while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo killall -0 apt apt-get dpkg 2>/dev/null; do
        sleep 3
    done
}

# ==========================================================
#  ETAP 1/3: KONFIGURACJA I OPTYMALIZACJA SYSTEMU
# ==========================================================
show_progress 0 $TOTAL_STEPS "$MSG_PHASE_1"

if [[ -f "$SCRIPT_DIR/.update.sh" ]]; then
    cp -af "$SCRIPT_DIR/.update.sh" ~/.update.sh
    chmod +x ~/.update.sh
fi

if [[ -d "$SCRIPT_DIR/.local" ]]; then
    mkdir -p ~/.local
    cp -afT "$SCRIPT_DIR/.local" ~/.local
fi

if [[ -d "$SCRIPT_DIR/.config" ]]; then
    mkdir -p ~/.config
    cp -afT "$SCRIPT_DIR/.config" ~/.config
fi

show_progress 1 $TOTAL_STEPS "$MSG_PHASE_1"

wait_for_apt
sudo sed -i '/cdrom/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
sudo dpkg --add-architecture i386 || true

if [[ -f /etc/apt/sources.list ]]; then
    if ! grep -q "non-free-firmware" /etc/apt/sources.list; then
        sudo sed -i -E 's/ main($| )/ main contrib non-free non-free-firmware\1/' /etc/apt/sources.list || true
    fi
fi

if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    if ! grep -q "non-free-firmware" /etc/apt/sources.list.d/debian.sources; then
        sudo sed -i -E '/^Components:/ s/$/ contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources || true
    fi
fi

DEBIAN_CODENAME="$(. /etc/os-release 2>/dev/null && echo "$VERSION_CODENAME")"
[[ -z "$DEBIAN_CODENAME" ]] && DEBIAN_CODENAME="trixie"
if ! grep -rqE "^[^#]*${DEBIAN_CODENAME}-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-backports main contrib non-free non-free-firmware" | sudo tee /etc/apt/sources.list.d/backports.list > /dev/null
    sudo apt-get update -yq || true
fi

wait_for_apt
sudo apt-get update -yq || true
for pkg in curl wget gnupg pciutils dconf-cli; do
    sudo apt-get install -yq "$pkg" || true
done
sudo mkdir -p /etc/apt/keyrings
sudo chmod 755 /etc/apt/keyrings

show_progress 2 $TOTAL_STEPS "$MSG_PHASE_1"

if [ ! -f /etc/apt/keyrings/google-chrome.gpg ]; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
    sudo chmod 644 /etc/apt/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
fi

sudo mkdir -p /usr/share/keyrings
sudo rm -f /usr/share/keyrings/brave-browser-archive-keyring.gpg
BRAVE_KEY_ID="0686B78420038257"
BRAVE_GNUPGHOME="$(mktemp -d)"
if ! gpg --homedir "$BRAVE_GNUPGHOME" --keyserver hkps://keyserver.ubuntu.com --recv-keys "$BRAVE_KEY_ID"; then
    gpg --homedir "$BRAVE_GNUPGHOME" --keyserver hkps://keys.openpgp.org --recv-keys "$BRAVE_KEY_ID" || true
fi
gpg --homedir "$BRAVE_GNUPGHOME" --export "$BRAVE_KEY_ID" | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg > /dev/null
rm -rf "$BRAVE_GNUPGHOME"
sudo chmod 644 /usr/share/keyrings/brave-browser-archive-keyring.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

wait_for_apt
sudo apt-get update -yq && sudo apt-get full-upgrade -yq || true

show_progress 3 $TOTAL_STEPS "$MSG_PHASE_1"

wait_for_apt
sudo apt-get install -yq isenkram-cli firmware-linux firmware-linux-nonfree || true
sudo isenkram-autoinstall-firmware || true

PACKAGES_REMOVE=(nano konqueror plasma-browser-integration plasma-vault krdp krfb plasma-thunderbolt dragonplayer elisa kontact kmail kontrast plasma-welcome kaddressbook kdepim-runtime akonadi-server akregator korganizer epiphany decibels gnome-user-docs gnome-contacts gnome-maps gnome-weather gnome-calendar gnome-clocks gnome-music parole rhythmbox showtime kwalletmanager evolution,evolution-common,evolution-plugins,evolution-ews)
for pkg in "${PACKAGES_REMOVE[@]}"; do
    sudo apt-get purge -yq "$pkg" 2>/dev/null || true
done
sudo apt-get autoremove -yq || true

rm -rf ~/.local/share/akonadi ~/.local/share/kmail2 ~/.local/share/local-mail ~/.local/share/contacts ~/.local/share/korganizer ~/.local/share/akregator ~/.local/share/kontact ~/.local/share/konqueror
rm -rf ~/.config/akonadi* ~/.config/kmail* ~/.config/kontact* ~/.config/korganizer* ~/.config/kaddressbook* ~/.config/akregator* ~/.config/emailidentities ~/.config/mailtransports
rm -rf ~/.cache/akonadi* ~/.cache/kmail* ~/.cache/kontact* ~/.cache/korganizer* ~/.cache/kaddressbook* ~/.cache/akregator* ~/.cache/konqueror*
rm -rf ~/.local/share/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,gnome-calendar,gnome-clocks,evolution,gnome-music,parole,rhythmbox,showtime,epiphany,decibels,dragonplayer,elisa}
rm -rf ~/.config/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,gnome-calendar,gnome-clocks,evolution,gnome-music,parole,rhythmbox,showtime,epiphany,decibels,dragonplayer,elisa}
rm -rf ~/.cache/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,gnome-calendar,gnome-clocks,evolution,gnome-music,parole,rhythmbox,showtime,epiphany,decibels,dragonplayer,elisa}
command -v dconf &>/dev/null && dconf reset -f /org/gnome/evolution/ || true

if dpkg -l plasma-desktop 2>/dev/null | grep -q '^ii' || dpkg -l plasma-workspace 2>/dev/null | grep -q '^ii'; then
    mkdir -p ~/.config
    cat > ~/.config/kwalletrc << 'EOF'
[Wallet]
Close When Idle=false
Close on Screensaver=false
Default Wallet=kdewallet
Enabled=false
First Use=false
Idle Timeout=10
Launch Manager=false
Leave Manager Open=false
Leave Open=true
Prompt on Open=false
Use One Wallet=true

[org.freedesktop.secrets]
apiEnabled=false
EOF
fi

# ==========================================================
#  ETAP 2/3: INSTALACJA PAKIETÓW I OPROGRAMOWANIA
# ==========================================================
show_progress 4 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_apt
PACKAGES_INSTALL=(
    google-chrome-stable brave-origin thunderbird thunderbird-l10n-pl
    qbittorrent audacity gimp krita gmic mixxx kdenlive handbrake soundconverter
    vim dconf-editor hunspell-pl fastfetch bleachbit profile-sync-daemon
    plymouth plymouth-themes unrar-free mc btrfs-progs exfatprogs ntfs-3g os-prober
    adb fastboot fsarchiver inxi pv rsync cdemu-daemon cdemu-client
    7zip makeself zenity innoextract needrestart flatpak timeshift
    python3-defusedxml python3-packaging python3-pip python3-tqdm vlc vlc-plugin-access-extra
    libayatana-appindicator3-1 gamemode vulkan-tools mangohud qmmp qmmp-plugin-pack
    vkd3d-compiler goverlay gcc make cmake meson ninja-build just build-essential git
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
    zsh zsh-syntax-highlighting zsh-autosuggestions 
)
for pkg in "${PACKAGES_INSTALL[@]}"; do
    sudo apt-get install -yq "$pkg" || true
done

sudo systemctl disable --now cdemu-daemon 2>/dev/null || true
sudo systemctl mask cdemu-daemon 2>/dev/null || true
mkdir -p "$HOME/.config/autostart"
for f in /etc/xdg/autostart/gcdemu.desktop /etc/xdg/autostart/cdemu.desktop /usr/share/applications/gcdemu.desktop; do
    if [[ -f "$f" ]]; then
        cp -f "$f" "$HOME/.config/autostart/$(basename "$f")"
        if grep -q '^Hidden=' "$HOME/.config/autostart/$(basename "$f")"; then
            sed -i 's/^Hidden=.*/Hidden=true/' "$HOME/.config/autostart/$(basename "$f")"
        else
            echo "Hidden=true" >> "$HOME/.config/autostart/$(basename "$f")"
        fi
    fi
done
pkill -f gcdemu 2>/dev/null || true

if ! sudo apt-get install -yq telegram-desktop 2>/dev/null; then
    sudo apt-get install -yq -t "${DEBIAN_CODENAME}-backports" telegram-desktop 2>/dev/null || true
fi

show_progress 5 $TOTAL_STEPS "$MSG_PHASE_2"

sudo apt-get install -yq cabextract unzip wget >/dev/null 2>&1 || true
if sudo curl -fsSLo /usr/local/bin/winetricks https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks && sudo chmod +x /usr/local/bin/winetricks; then
    :
else
    sudo apt-get install -yq winetricks || true
fi

show_progress 6 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_apt
sudo apt-get install -yq libpulse0:i386 libopenal1:i386 mangohud:i386 || true

if ! sudo apt-get install -yq wine wine64 wine32:i386; then
    for pkg in wine wine64 wine32; do
        sudo apt-get purge -yq "$pkg" 2>/dev/null || true
    done
    sudo mkdir -pm755 /etc/apt/keyrings
    if sudo curl -fsSLo /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && sudo curl -fsSLo /etc/apt/sources.list.d/winehq.sources https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources; then
        wait_for_apt
        sudo apt-get update -yq || true
        sudo apt-get install -yq --install-recommends winehq-stable || true
    fi
fi

show_progress 7 $TOTAL_STEPS "$MSG_PHASE_2"

VGA_INFO=""
HYBRID_GPU=false
GPU_VENDORS=()
if command -v lspci &>/dev/null; then
    VGA_INFO=$(lspci -nn | grep -iE "VGA|3D|Display" || true)

    echo "$VGA_INFO" | grep -qi "intel"     && GPU_VENDORS+=("intel")
    echo "$VGA_INFO" | grep -qi -E "amd|ati" && GPU_VENDORS+=("amd")
    echo "$VGA_INFO" | grep -qi "nvidia"    && GPU_VENDORS+=("nvidia")

    TOTAL_KNOWN=${#GPU_VENDORS[@]}

    if [ -z "$VGA_INFO" ] || [ "$TOTAL_KNOWN" -eq 0 ]; then
        HYBRID_GPU=false
        wait_for_apt
        sudo apt-get install -yq libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 || true
    elif [ "$TOTAL_KNOWN" -ge 2 ]; then
        HYBRID_GPU=true
    else
        HYBRID_GPU=false
    fi
else
    wait_for_apt
    sudo apt-get install -yq libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 || true
fi

MODULES_FILE="/etc/initramfs-tools/modules"
add_module() { grep -q "^$1" "$MODULES_FILE" || echo "$1" | sudo tee -a "$MODULES_FILE" > /dev/null; }

wait_for_apt
if [ "${#GPU_VENDORS[@]}" -gt 0 ]; then
    for vendor in "${GPU_VENDORS[@]}"; do
        case "$vendor" in
            "nvidia")
                sudo apt-get install -yq libgl1-nvidia-glvnd-glx:i386 || true
                add_module "nvidia"
                add_module "nvidia_modeset"
                add_module "nvidia_uvm"
                add_module "nvidia_drm"
                ;;
            "amd")
                sudo apt-get install -yq libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 || true
                add_module "amdgpu"
                ;;
            "intel")
                sudo apt-get install -yq libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 || true
                add_module "i915"
                ;;
        esac
    done
else
    sudo apt-get install -yq libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 || true
fi
sudo update-initramfs -u || true

show_progress 8 $TOTAL_STEPS "$MSG_PHASE_2"

sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
sudo flatpak update --appstream || true
sudo flatpak install -y flathub com.github.tchx84.Flatseal || true
sudo flatpak install -y flathub it.mijorus.gearlever || true

mkdir -p "$DEB_DIR"
download_deb() { wget -q --timeout=30 -O "$3" "$2" || rm -f "$3"; }
get_github_deb_url() { curl -sfL "https://api.github.com/repos/${1}/releases/latest" | grep "browser_download_url.*${2}" | cut -d '"' -f 4 || true; }

download_deb "Discord" "https://discord.com/api/download?platform=linux&format=deb" "$DEB_DIR/discord.deb"
LSFG_URL=$(get_github_deb_url "YuriSizov/ls-fg" "ls-fg_.*deb")
LSFG_VK_URL=$(get_github_deb_url "YuriSizov/ls-fg-vk" "ls-fg-vk_.*deb")
FAUGUS_URL=$(get_github_deb_url "faugus/faugus-launcher" "deb")
OPENCODE_URL=$(get_github_deb_url "anomalyco/opencode" "opencode-desktop-linux-amd64\\.deb")

[[ -n "$LSFG_URL" ]] && download_deb "ls-fg" "$LSFG_URL" "$DEB_DIR/lsfg.deb"
[[ -n "$LSFG_VK_URL" ]] && download_deb "ls-fg-vk" "$LSFG_VK_URL" "$DEB_DIR/lsfg-vk.deb"
[[ -n "$FAUGUS_URL" ]] && download_deb "Faugus Launcher" "$FAUGUS_URL" "$DEB_DIR/faugus.deb"
[[ -n "$OPENCODE_URL" ]] && download_deb "opencode-desktop" "$OPENCODE_URL" "$DEB_DIR/opencode-desktop.deb"

shopt -s nullglob
DEB_FILES=("$DEB_DIR"/*.deb)
if [[ ${#DEB_FILES[@]} -gt 0 ]]; then
    wait_for_apt
    for deb in "${DEB_FILES[@]}"; do
        sudo apt-get install -yq "$deb" || true
    done
fi
shopt -u nullglob
rm -rf "$DEB_DIR"

# ==========================================================
#  ETAP 3/3: KONFIGURACJA USŁUG, BOOTLOADERA I ŚRODOWISKA
# ==========================================================
show_progress 9 $TOTAL_STEPS "$MSG_PHASE_3"

wait_for_apt
sudo apt-get install -yq virt-manager qemu-system qemu-utils libvirt-daemon-system libvirt-clients ovmf dnsmasq bluetooth bluez bluez-firmware bluez-tools ufw || true

if command -v dconf &>/dev/null; then
    dconf load /org/virt-manager/virt-manager/ <<'EOF'
[/]
manager-window-height=297
manager-window-width=478
xmleditor-enabled=true

[confirm]
delete-storage=false
forcepoweroff=false

[connections]
autoconnect=['qemu:///system']
uris=['qemu:///system']

[conns/qemu:system]
window-size=(800, 600)

[details]
show-toolbar=true

[new-vm]
cpu-default='host-passthrough'
firmware='uefi'
graphics-type='spice'
storage-format='raw'

[stats]
enable-disk-poll=true
enable-memory-poll=true
enable-net-poll=true

[vmlist-fields]
disk-usage=false
network-traffic=false

[vms/2a91721fef6c4249997ea19b01801825]
autoconnect=1
vm-window-size=(1280, 842)
EOF
else
    log_warn "Brak polecenia dconf – pomijam wczytanie ustawień virt-managera." "dconf command not found – skipping virt-manager settings import."
fi

for svc in libvirtd virtqemud; do
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
        sudo systemctl enable --now "${svc}.service" || true
        break
    fi
done

if ! sudo virsh net-info default &>/dev/null; then
    sudo virsh net-define /usr/share/libvirt/networks/default.xml || true
fi
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default || true

if command -v ufw &>/dev/null || [[ -x /usr/sbin/ufw ]]; then
    [[ -f /etc/default/ufw ]] && sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
    sudo ufw --force reset || true
    sudo ufw default deny incoming || true
    sudo ufw default allow outgoing || true
    sudo ufw allow ssh || true
    sudo ufw allow in  on virbr0 || true
    sudo ufw allow out on virbr0 || true
    sudo ufw allow from 192.168.122.0/24 || true
    sudo ufw --force enable || true
fi

for grp in libvirt libvirt-qemu kvm; do
    getent group "$grp" &>/dev/null && sudo usermod -aG "$grp" "$CURRENT_USER" || true
done

show_progress 10 $TOTAL_STEPS "$MSG_PHASE_3"

GRUB_CMDLINE_CURRENT="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/' || true)"
GRUB_CMDLINE_NEW="$GRUB_CMDLINE_CURRENT"
for param in quiet splash loglevel=3 systemd.show_status=false rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.ignore-serial-consoles; do
    if [[ " $GRUB_CMDLINE_CURRENT " != *" $param "* ]]; then
        GRUB_CMDLINE_NEW="${GRUB_CMDLINE_NEW} ${param}"
    fi
done
GRUB_CMDLINE_NEW="$(echo "$GRUB_CMDLINE_NEW" | sed -E 's/ +/ /g; s/^ //; s/ $//')"
if [[ "$GRUB_CMDLINE_NEW" != "$GRUB_CMDLINE_CURRENT" ]]; then
    sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"|" /etc/default/grub || true
fi

sudo plymouth-set-default-theme bgrt || true
sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub || true
sudo update-grub || true
sudo update-initramfs -u || true

show_progress 11 $TOTAL_STEPS "$MSG_PHASE_3"

sudo systemctl enable fstrim.timer || true
sudo journalctl --vacuum-time=2d || true

sudo mkdir -p /etc/NetworkManager/conf.d
echo -e "[main]\ndns=default\nrc-manager=symlink" | sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null
echo -e "[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.1,1.0.0.1,2606:4700:4700::1112,2606:4700:4700::1002" | sudo tee /etc/NetworkManager/conf.d/global-dns.conf > /dev/null

ACTIVE_CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -v "^lo" | head -n 1 | cut -d: -f1 || true)
if [[ -n "$ACTIVE_CONN" ]]; then
    sudo nmcli connection modify "$ACTIVE_CONN" ipv4.dns "1.1.1.1,1.0.0.1" ipv6.dns "2606:4700:4700::1112,2606:4700:4700::1002"
    sudo nmcli connection up "$ACTIVE_CONN" || true
fi

if command -v zsh &>/dev/null; then
    sudo chsh -s /usr/bin/zsh "$CURRENT_USER" || true
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
    fi
    P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    if [[ ! -d "$P10K_DIR" ]]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR" || true
    fi
    ZSHRC="$HOME/.zshrc"
    if [[ -f "$ZSHRC" ]]; then
        sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$ZSHRC" || true
        sed -i 's/^plugins=(.*/plugins=(git sudo systemd debian)/' "$ZSHRC" || true
        SHELL_LOCALE="${LANG:-${LC_ALL:-${LC_MESSAGES:-en_US.UTF-8}}}"
        if command -v locale &>/dev/null; then
            AVAILABLE_LOCALES="$(locale -a 2>/dev/null)"
            if ! echo "$AVAILABLE_LOCALES" | grep -qiF "$SHELL_LOCALE" && ! echo "$AVAILABLE_LOCALES" | grep -qiF "$(echo "$SHELL_LOCALE" | sed 's/UTF-8/utf8/')"; then
                SHELL_LOCALE="en_US.UTF-8"
            fi
        fi
        grep -q "^export LC_ALL=" "$ZSHRC" || echo "export LC_ALL=${SHELL_LOCALE}" >> "$ZSHRC"
        grep -q "^fastfetch"         "$ZSHRC" || echo "fastfetch"                  >> "$ZSHRC"
        grep -q "zsh-syntax-highlighting.zsh" "$ZSHRC" || echo "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> "$ZSHRC"
        grep -q "zsh-autosuggestions.zsh"     "$ZSHRC" || echo "source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"         >> "$ZSHRC"
    fi
fi

if [[ "$USE_RUN0" -eq 1 ]]; then
    sudo rm -f "$RUN0_NOPASSWD_FILE"
    sudo systemctl try-restart polkit 2>/dev/null || true
else
    sudo rm -f /etc/sudoers.d/99-temp-installer
fi

show_progress 12 $TOTAL_STEPS "$MSG_PHASE_3"
echo -e "\n" >&3

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}✔ KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}✔ CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
fi

# ==========================================================
#  RESTART SYSTEMU
# ==========================================================
if [[ "$SCRIPT_LANG" == "pl" ]]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
echo -en "${INFO}==> ${RESTART_PROMPT}${NC}" >&3
read -r RESTART_CHOICE < /dev/tty
case "$RESTART_CHOICE" in
    [YyTt]*)
        systemctl reboot
        ;;
    *)
        exit 0
        ;;
esac
