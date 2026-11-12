#!/bin/bash
# =========================================
# KOMPLEKSOWY SKRYPT KONFIGURACYJNY Debian
# =========================================

set -Eeuo pipefail
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
DEB_DIR="/tmp/debs_$$"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

cleanup_on_exit() {
    local exit_code=$?
    declare -F restore_packagekit >/dev/null && restore_packagekit || true
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}[X] Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${ERR}[X] An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
            fi
        fi
    fi
    rm -f "$TMP_LOG"
    rm -rf "$DEB_DIR"
    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        sudo sh -c 'rm -f "$1" "$2"; systemctl try-restart polkit 2>/dev/null; if [ "$3" = 1 ]; then systemctl reboot; fi' _ \
            "${RUN0_NOPASSWD_FILE:-/etc/polkit-1/rules.d/51-run0-nopasswd.rules}" \
            "/etc/sudoers.d/99-temp-installer" \
            "$do_reboot"
    fi
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() { printf "\r\033[K" >&3; echo -e "$1" >&3; echo -e "$1"; cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true; }
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}[OK] $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}[X] ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}[!] WARN: $m${NC}"; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

# ==========================================================
# PACKAGEKIT + BLOKADA MENEDŻERA PAKIETÓW
# ==========================================================
PACKAGEKIT_MASKED=0
PACKAGEKIT_UNITS=(packagekit.service packagekit-offline-update.service)

disable_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] && return 0
    sudo systemctl stop "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    if command -v killall >/dev/null 2>&1; then
        sudo killall -q packagekitd 2>/dev/null || true
    else
        sudo pkill -x packagekitd 2>/dev/null || true
    fi
    sudo systemctl mask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    PACKAGEKIT_MASKED=1
}

restore_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] || return 0
    sudo systemctl unmask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    PACKAGEKIT_MASKED=0
}

_pkg_lock_busy() {
    local f
    for f in /var/lib/dpkg/lock-frontend \
             /var/lib/dpkg/lock \
             /var/lib/apt/lists/lock \
             /var/cache/apt/archives/lock; do
        [[ -e "$f" ]] || continue
        sudo fuser "$f" >/dev/null 2>&1 && return 0
    done
    pgrep -x 'apt|apt-get|apt-config|dpkg|unattended-upgrade|packagekitd' >/dev/null 2>&1 && return 0
    return 1
}

wait_for_apt() {
    local timeout="${1:-300}" waited=0
    disable_packagekit
    while _pkg_lock_busy; do
        if (( waited >= timeout )); then
            log_warn "Blokada menedżera pakietów trwa ponad ${timeout}s - kontynuuję mimo to." \
                     "Package manager lock held for over ${timeout}s - continuing anyway."
            break
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
}

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(stty size </dev/tty 2>/dev/null || true)
    cols="${cols##* }"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols=80

    local bar_width=50
    local reserved=14
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 3))}..."
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
    MSG_PHASE_1="[1/4] Przygotowywanie..."
    MSG_PHASE_2="[2/4] Instalacja..."
    MSG_PHASE_3="[3/4] Optymalizacja..."
    MSG_PHASE_4="[4/4] Finalizowanie..."
else
    MSG_PHASE_1="[1/4] Preparing..."
    MSG_PHASE_2="[2/4] Installing..."
    MSG_PHASE_3="[3/4] Optimizing..."
    MSG_PHASE_4="[4/4] Finalizing..."
fi

TOTAL_STEPS=12
FAILED_PACKAGES=()

if [[ "$EUID" -eq 0 ]]; then
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}[X] Nie uruchamiaj skryptu jako root. Użyj zwykłego użytkownika z sudo.${NC}" >&3
    else
        echo -e "${ERR}[X] Do not run this script as root. Run as a normal user with sudo.${NC}" >&3
    fi
    exit 1
fi

CURRENT_USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

printf '\033[?7h\n' >&3

RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1 || sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

SUDO_READY=0
if [[ "$USE_RUN0" -eq 1 ]]; then
    sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null << EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
EOF
    sudo systemctl try-restart polkit 2>/dev/null || true
    SUDO_READY=1
else
    sudo -v

    (
        set +e
        trap - ERR
        while true; do
            sudo -n true
            sleep 60
            kill -0 "$$" 2>/dev/null || exit
        done
    ) &
    SUDO_KEEPALIVE_PID=$!

    SUDOERS_TMP="$(mktemp)"
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null; then
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
        echo "%sudo ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
        sudo visudo -cf "$SUDOERS_TMP" &>/dev/null && sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99_nopasswd || true
    else
        rm -f "$SUDOERS_TMP"
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}[X] Nieprawidłowa składnia pliku sudoers – przerywam.${NC}" >&3
        else
            echo -e "${ERR}[X] Invalid sudoers rule syntax - aborting.${NC}" >&3
        fi
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
    SUDO_READY=1
fi

printf '\033[?7l' >&3

# ==========================================================
#  ETAP 1/4: PRZYGOTOWYWANIE
# ==========================================================
show_progress 0 $TOTAL_STEPS "$MSG_PHASE_1"

disable_packagekit

pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]]
}

install_apt_pkgs() {
    wait_for_apt
    local valid_pkgs=()
    for pkg in "$@"; do
        pkg_installed "$pkg" && continue
        if apt-cache show "$pkg" &>/dev/null; then
            valid_pkgs+=("$pkg")
        else
            FAILED_PACKAGES+=("$pkg")
        fi
    done
    for pkg in "${valid_pkgs[@]}"; do
        sudo apt-get install -yq "$pkg" || FAILED_PACKAGES+=("$pkg")
    done
}

wait_for_apt
sudo sed -i '/cdrom/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
sudo dpkg --add-architecture i386 || true

if [[ -f /etc/apt/sources.list ]]; then
    if ! grep -q "non-free-firmware" /etc/apt/sources.list; then
        sudo sed -i -E 's/ main($| )/ main contrib non-free non-free-firmware\1/' /etc/apt/sources.list || true
    fi
    grep -qE '^[^#]*[[:space:]]contrib([[:space:]]|$)' /etc/apt/sources.list || sudo sed -i -E '/^deb / s/ main($| )/ main contrib\1/' /etc/apt/sources.list || true
fi

if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    if ! grep -q "non-free-firmware" /etc/apt/sources.list.d/debian.sources; then
        sudo sed -i -E '/^Components:/ s/$/ contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources || true
    fi
    grep -qE '^Components:.*[[:space:]]contrib([[:space:]]|$)' /etc/apt/sources.list.d/debian.sources || sudo sed -i -E '/^Components:/ s/$/ contrib/' /etc/apt/sources.list.d/debian.sources || true
fi

DEBIAN_CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
[[ -z "$DEBIAN_CODENAME" ]] && DEBIAN_CODENAME="trixie"
if ! grep -rqE "^[^#]*${DEBIAN_CODENAME}-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-backports main contrib non-free non-free-firmware" | sudo tee /etc/apt/sources.list.d/backports.list > /dev/null
fi

wait_for_apt
sudo apt-get update -yq || true
install_apt_pkgs curl wget gnupg pciutils dconf-cli xz-utils

GPU_TYPE="unknown"
HYBRID_GPU=false
GPU_VENDORS=()
GPU_UNKNOWN_PKGS=(
    libgl1-mesa-dri:amd64 libgl1-mesa-dri:i386
    mesa-vulkan-drivers:amd64 mesa-vulkan-drivers:i386
    libglx-mesa0:amd64 libglx-mesa0:i386 mesa-opencl-icd:amd64
    vulkan-tools libvulkan-dev libgl1-mesa-dev mesa-common-dev
)
if command -v lspci &>/dev/null; then
    GPU_INFO=$(lspci | grep -i -E "vga|3d|display" || true)

    echo "$GPU_INFO" | grep -qi "nvidia"      && GPU_VENDORS+=("nvidia")
    echo "$GPU_INFO" | grep -qi -E "\b(amd|ati)\b|advanced micro devices|radeon" && GPU_VENDORS+=("amd")
    echo "$GPU_INFO" | grep -qi "intel"       && GPU_VENDORS+=("intel")

    TOTAL_KNOWN=${#GPU_VENDORS[@]}

    if [ -z "$GPU_INFO" ] || [ "$TOTAL_KNOWN" -eq 0 ]; then
        HYBRID_GPU=false
        install_apt_pkgs "${GPU_UNKNOWN_PKGS[@]}"
    elif [ "$TOTAL_KNOWN" -ge 2 ]; then
        HYBRID_GPU=true
        GPU_TYPE="$(IFS=+; echo "${GPU_VENDORS[*]}")"
        log_info "Wykryto hybrydowy układ graficzny (HYBRID_GPU=$HYBRID_GPU): $GPU_TYPE" "Detected a hybrid GPU setup (HYBRID_GPU=$HYBRID_GPU): $GPU_TYPE"
    else
        HYBRID_GPU=false
        GPU_TYPE="${GPU_VENDORS[0]}"
    fi
else
    install_apt_pkgs "${GPU_UNKNOWN_PKGS[@]}"
fi

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

TO_REMOVE=(
konqueror plasma-browser-integration plasma-vault
plasma-thunderbolt dragonplayer transmission-qt
evolution evolution-ews evolution-data-server
evolution-bogofilter evolution-spamassassin
transmission-gtk pragha elisa kontact kmail kontrast plasma-welcome
kaddressbook cosmic-player kdepim-runtime akonadi-server akregator
korganizer epiphany-browser decibels gnome-user-docs gnome-contacts
gnome-maps gnome-weather gnome-calendar gnome-clocks gnome-music
parole rhythmbox showtime kwalletmanager totem exaile mpv juk
)
wait_for_apt
for pkg in "${TO_REMOVE[@]}"; do
    sudo apt-get purge -yq "$pkg" 2>/dev/null || true
done
sudo apt-get autoremove --purge -yq || true

if pkg_installed plasma-desktop || pkg_installed plasma-workspace; then
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
rm -rf ~/.local/share/akonadi ~/.local/share/kmail2 ~/.local/share/local-mail ~/.local/share/contacts ~/.local/share/korganizer ~/.local/share/akregator ~/.local/share/kontact ~/.local/share/konqueror
rm -rf ~/.config/akonadi* ~/.config/kmail* ~/.config/kontact* ~/.config/korganizer* ~/.config/kaddressbook* ~/.config/akregator* ~/.config/emailidentities ~/.config/mailtransports
rm -rf ~/.cache/akonadi* ~/.cache/kmail* ~/.cache/kontact* ~/.cache/korganizer* ~/.cache/kaddressbook* ~/.cache/akregator* ~/.cache/konqueror*
rm -rf ~/.local/share/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,gnome-calendar,evolution,gnome-clocks,gnome-music,parole,rhythmbox,showtime,dragonplayer,elisa,cosmic-player,transmission,pragha,totem,exaile,mpv,juk}
rm -rf ~/.config/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,gnome-calendar,evolution,gnome-clocks,gnome-music,parole,rhythmbox,showtime,dragonplayer,elisa,cosmic-player,transmission,pragha,totem,exaile,mpv,juk}
rm -rf ~/.cache/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,gnome-calendar,evolution,gnome-clocks,gnome-music,parole,rhythmbox,showtime,dragonplayer,elisa,cosmic-player,transmission,pragha,totem,exaile,mpv,juk}
command -v dconf &>/dev/null && dconf reset -f /org/gnome/evolution/ || true

show_progress 2 $TOTAL_STEPS "$MSG_PHASE_1"

sudo mkdir -p /etc/apt/keyrings
sudo chmod 755 /etc/apt/keyrings

if [ ! -f /etc/apt/keyrings/google-chrome.gpg ]; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
    sudo chmod 644 /etc/apt/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
fi

sudo mkdir -p /usr/share/keyrings
sudo rm -f /usr/share/keyrings/brave-origin-archive-keyring.gpg /etc/apt/sources.list.d/brave-origin-release.sources
sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
sudo chmod 644 /usr/share/keyrings/brave-browser-archive-keyring.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

sudo mkdir -p /etc/NetworkManager/conf.d
echo -e "[main]\ndns=default\nrc-manager=symlink" | sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null
echo -e "[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002" | sudo tee /etc/NetworkManager/conf.d/global-dns.conf > /dev/null

ACTIVE_CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -v "^lo" | head -n 1 | cut -d: -f1 || true)
if [[ -n "$ACTIVE_CONN" ]]; then
    sudo nmcli connection modify "$ACTIVE_CONN" ipv4.dns "1.1.1.2,1.0.0.2" ipv6.dns "2606:4700:4700::1112,2606:4700:4700::1002"
    sudo nmcli connection up "$ACTIVE_CONN" || true
fi

show_progress 3 $TOTAL_STEPS "$MSG_PHASE_1"

# ==========================================================
#  ETAP 2/4: INSTALACJA
# ==========================================================
show_progress 4 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_apt
sudo apt-get update -yq || true
sudo apt-get full-upgrade -yq || true
sudo apt-get autoremove -yq || true

show_progress 5 $TOTAL_STEPS "$MSG_PHASE_2"

SYSTEM_PKGS=(
    google-chrome-stable brave-origin
    audacity gimp krita mixxx kdenlive handbrake soundconverter
    vim dconf-editor hunspell-pl fastfetch bleachbit profile-sync-daemon
    plymouth plymouth-themes unrar-free mc btrfs-progs exfatprogs ntfs-3g os-prober
    adb fastboot fsarchiver inxi pv rsync cdemu-daemon cdemu-client
    7zip makeself zenity innoextract needrestart flatpak timeshift
    python3-defusedxml python3-packaging python3-pip python3-tqdm vlc vlc-plugin-access-extra
    libayatana-appindicator3-1 gamemode mangohud qmmp
    gcc g++ clang llvm make cmake meson ninja-build just build-essential git
    qt6-tools-dev ghostwriter qbittorrent gnome-disk-utility
    zsh zsh-syntax-highlighting zsh-autosuggestions pkg-config
    cabextract unzip wget xz-utils winetricks wine wine64
    isenkram-cli firmware-linux-nonfree systemd-zram-generator
    virt-manager qemu-system qemu-utils libvirt-daemon-system libvirt-clients
    libxcb1 qt6-qpa-plugins qt6-wayland qt6-svg-plugins
    libqt6core6t64 libqt6gui6 libqt6widgets6 libqt6svg6
    libqt6qml6 libqt6qmlmodels6 libqt6qmlworkerscript6
    libqt6quick6 libqt6quickcontrols2-6 libqt6quickdialogs2-6
    libqt6quicklayouts6 libqt6quicktemplates2-6
    qml6-module-qtquick qml6-module-qtquick-controls
    qml6-module-qtquick-layouts qml6-module-qtquick-window
    qml6-module-qtquick-dialogs qml6-module-qtquick-templates
    qml6-module-qtqml qml6-module-qtqml-models qml6-module-qtqml-workerscript
    qml6-module-qtcore qml6-module-qt-labs-folderlistmodel
    qml6-module-qt-labs-platform qml6-module-qt-labs-settings
)

PKGS_32BIT=(
    libpulse0:i386 libopenal1:i386 mangohud:i386 wine32:i386
    libgamemode0:i386 libgamemodeauto0:i386
    libpipewire-0.3-0t64:i386 pipewire-alsa:i386 libasound2-plugins:i386
    libxrandr2:i386 libxrender1:i386
)

PKGS_CODECS=(
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
    gstreamer1.0-libav ffmpeg x264
)

for vendor in "${GPU_VENDORS[@]}"; do
    case "$vendor" in
        "nvidia") SYSTEM_PKGS+=(vulkan-tools libvulkan-dev libgl1-mesa-dev mesa-common-dev libgl1-nvidia-glvnd-glx:i386 nvidia-vaapi-driver:amd64 nvidia-vaapi-driver:i386 nvidia-opencl-icd:amd64) ;;
        "amd")    SYSTEM_PKGS+=(libgl1-mesa-dri:amd64 libgl1-mesa-dri:i386 mesa-vulkan-drivers:amd64 mesa-vulkan-drivers:i386 libglx-mesa0:amd64 libglx-mesa0:i386 vulkan-tools libvulkan-dev libgl1-mesa-dev mesa-common-dev mesa-va-drivers:amd64 mesa-va-drivers:i386 mesa-opencl-icd:amd64) ;;
        "intel")  SYSTEM_PKGS+=(libgl1-mesa-dri:amd64 libgl1-mesa-dri:i386 mesa-vulkan-drivers:amd64 mesa-vulkan-drivers:i386 libglx-mesa0:amd64 libglx-mesa0:i386 vulkan-tools libvulkan-dev libgl1-mesa-dev mesa-common-dev intel-media-va-driver-non-free:amd64 intel-media-va-driver-non-free:i386 intel-opencl-icd:amd64) ;;
    esac
done

if [ "${#SYSTEM_PKGS[@]}" -gt 0 ]; then
    readarray -t SYSTEM_PKGS < <(printf '%s\n' "${SYSTEM_PKGS[@]}" | awk '!seen[$0]++')
fi

install_apt_pkgs "${SYSTEM_PKGS[@]}"
install_apt_pkgs "${PKGS_32BIT[@]}"
install_apt_pkgs "${PKGS_CODECS[@]}"

if ! pkg_installed telegram-desktop; then
    wait_for_apt
    if ! sudo apt-get install -yq telegram-desktop 2>/dev/null; then
        sudo apt-get install -yq -t "${DEBIAN_CODENAME}-backports" telegram-desktop 2>/dev/null || FAILED_PACKAGES+=("telegram-desktop")
    fi
fi

wait_for_apt
sudo isenkram-autoinstall-firmware || true
sudo depmod -a &>/dev/null || true

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

show_progress 6 $TOTAL_STEPS "$MSG_PHASE_2"

if command -v flatpak &>/dev/null; then
    sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    sudo flatpak update --appstream || true
    for fp_app in com.github.tchx84.Flatseal it.mijorus.gearlever; do
        flatpak info "$fp_app" &>/dev/null || sudo flatpak install -y flathub "$fp_app" || FAILED_PACKAGES+=("flatpak:$fp_app")
    done
fi

show_progress 7 $TOTAL_STEPS "$MSG_PHASE_2"

mkdir -p "$DEB_DIR"
download_deb() { wget -q --timeout=30 -O "$3" "$2" || { rm -f "$3"; FAILED_PACKAGES+=("$1"); }; }
get_github_deb_url() { curl -sfL "https://api.github.com/repos/${1}/releases/latest" | grep "browser_download_url.*${2}" | cut -d '"' -f 4 || true; }

pkg_installed discord || download_deb "Discord" "https://discord.com/api/download?platform=linux&format=deb" "$DEB_DIR/discord.deb"
OPENCODE_URL=""
FAUGUS_URL=""
pkg_installed opencode-desktop || OPENCODE_URL=$(get_github_deb_url "anomalyco/opencode" "opencode-desktop-linux-amd64\\.deb")
pkg_installed faugus-launcher || FAUGUS_URL=$(get_github_deb_url "Faugus/faugus-launcher" "all\\.deb")

if ! pkg_installed opencode-desktop; then
    if [[ -n "$OPENCODE_URL" ]]; then
        download_deb "opencode-desktop" "$OPENCODE_URL" "$DEB_DIR/opencode-desktop.deb"
    else
        FAILED_PACKAGES+=("opencode-desktop")
    fi
fi
if ! pkg_installed faugus-launcher; then
    if [[ -n "$FAUGUS_URL" ]]; then
        download_deb "Faugus Launcher" "$FAUGUS_URL" "$DEB_DIR/faugus.deb"
    else
        FAILED_PACKAGES+=("faugus-launcher")
    fi
fi

shopt -s nullglob
DEB_FILES=("$DEB_DIR"/*.deb)
shopt -u nullglob
if [[ ${#DEB_FILES[@]} -gt 0 ]]; then
    wait_for_apt
    for deb in "${DEB_FILES[@]}"; do
        sudo apt-get install -yq "$deb" || FAILED_PACKAGES+=("$(basename "$deb" .deb)")
    done
fi
rm -rf "$DEB_DIR"

LSFG_TMP="$(mktemp -d)"
LSFG_UA="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
LSFG_BASE="https://builds.lsfg-vk.dev"
LSFG_INSTALLED=0
LSFG_URLS=()

if LSFG_HTML="$(curl -fsSL --retry 3 --retry-delay 2 -A "$LSFG_UA" -e "$LSFG_BASE/" "$LSFG_BASE/" 2>/dev/null)"; then
    mapfile -t LSFG_CANDIDATES < <(
        {
            printf '%s' "$LSFG_HTML" | grep -oiE '(href|src)=["'\''][^"'\'']*lsfg-vk-[0-9]+(\.[0-9]+)*(-[A-Za-z0-9._-]+)?\.tar\.xz["'\'']' | sed -E 's/^(href|src)=["'\'']//I; s/["'\'']$//'
            printf '%s' "$LSFG_HTML" | grep -oiE '(https?://[^"'\'' <>[:space:]]+/)?lsfg-vk-[0-9]+(\.[0-9]+)*(-[A-Za-z0-9._-]+)?\.tar\.xz'
        } | awk 'NF && !seen[$0]++' | sort -rV || true
    )
    for c in "${LSFG_CANDIDATES[@]}"; do
        [[ -z "$c" ]] && continue
        case "$c" in
            http*://*) u="$c" ;;
            //*)       u="https:$c" ;;
            /*)        u="$LSFG_BASE$c" ;;
            *)         u="$LSFG_BASE/${c#./}" ;;
        esac
        LSFG_URLS+=("$u")
    done
fi

for LSFG_URL in "${LSFG_URLS[@]}"; do
    rm -f "$LSFG_TMP/lsfg-vk.tar.xz"
    if curl -fsSL --retry 3 --retry-delay 2 -A "$LSFG_UA" -e "$LSFG_BASE/" -o "$LSFG_TMP/lsfg-vk.tar.xz" "$LSFG_URL" 2>/dev/null; then
        if LSFG_TAR_LIST="$(tar -tf "$LSFG_TMP/lsfg-vk.tar.xz" 2>/dev/null)"; then
            if printf '%s\n' "$LSFG_TAR_LIST" | grep -qE '(^|/)bin/lsfg-vk-(ui|cli)$'; then
                BIN_LINE="$(printf '%s\n' "$LSFG_TAR_LIST" | grep -E '(^|/)bin/lsfg-vk-(ui|cli)$' | head -n 1)"
                PREFIX="${BIN_LINE%bin/lsfg-vk-*}"
                PREFIX="${PREFIX#./}"
                STRIP=0
                if [[ -n "$PREFIX" ]]; then
                    STRIP="$(awk -F'/' '{print NF-1}' <<< "$PREFIX")"
                fi
                mkdir -p "$HOME/.local"
                if tar -xf "$LSFG_TMP/lsfg-vk.tar.xz" --strip-components="$STRIP" -C "$HOME/.local" 2>/dev/null; then
                    if [[ -x "$HOME/.local/bin/lsfg-vk-ui" || -x "$HOME/.local/bin/lsfg-vk-cli" ]]; then
                        LSFG_INSTALLED=1
                        break
                    fi
                fi
            fi
        fi
    fi
done

if [[ "$LSFG_INSTALLED" -eq 0 ]]; then
    FAILED_PACKAGES+=("lsfg-vk")
fi
rm -rf "$LSFG_TMP"

show_progress 8 $TOTAL_STEPS "$MSG_PHASE_2"

# ==========================================================
#  ETAP 3/4: OPTYMALIZACJA
# ==========================================================
show_progress 9 $TOTAL_STEPS "$MSG_PHASE_3"

restore_packagekit

if [ -f /etc/default/grub ]; then
    GRUB_PARAMS=(quiet splash loglevel=3 systemd.show_status=false rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.ignore-serial-consoles mitigations=off split_lock_detect=off)
    [[ $GPU_TYPE == *"nvidia"* ]] && GRUB_PARAMS+=(nvidia_drm.modeset=1)

    GRUB_CMDLINE_CURRENT="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/' || true)"
    GRUB_CMDLINE_NEW="$GRUB_CMDLINE_CURRENT"
    for param in "${GRUB_PARAMS[@]}"; do
        if [[ " $GRUB_CMDLINE_CURRENT " != *" $param "* ]]; then
            GRUB_CMDLINE_NEW="${GRUB_CMDLINE_NEW} ${param}"
        fi
    done
    GRUB_CMDLINE_NEW="$(echo "$GRUB_CMDLINE_NEW" | sed -E 's/ +/ /g; s/^ //; s/ $//')"
    if [[ "$GRUB_CMDLINE_NEW" != "$GRUB_CMDLINE_CURRENT" ]]; then
        sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"|" /etc/default/grub || true
    fi
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub || true
    sudo update-grub || true
fi

show_progress 10 $TOTAL_STEPS "$MSG_PHASE_3"

sudo plymouth-set-default-theme bgrt 2>/dev/null || true

MODULES_FILE="/etc/initramfs-tools/modules"
if [ -f "$MODULES_FILE" ]; then
    add_module() { grep -q "^$1" "$MODULES_FILE" || echo "$1" | sudo tee -a "$MODULES_FILE" > /dev/null; }

    if [[ $GPU_TYPE == *"nvidia"* ]]; then
        add_module "nvidia"
        add_module "nvidia_modeset"
        add_module "nvidia_uvm"
        add_module "nvidia_drm"
    fi
    if [[ $GPU_TYPE == *"amd"* ]]; then
        add_module "amdgpu"
    fi
    if [[ $GPU_TYPE == *"intel"* ]]; then
        add_module "i915"
    fi
fi

sudo update-initramfs -u || true

show_progress 11 $TOTAL_STEPS "$MSG_PHASE_3"

sudo systemctl enable --now fstrim.timer || true
sudo systemctl enable --now bluetooth || true
echo "options btusb enable_autosuspend=0" | sudo tee /etc/modprobe.d/btusb.conf > /dev/null

sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'ZRAMEOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMEOF
sudo tee /etc/sysctl.d/99-zram.conf >/dev/null <<'SYSEOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
SYSEOF
sudo sysctl --system >/dev/null 2>&1 || true
sudo systemctl daemon-reload || true
sudo systemctl start /dev/zram0 2>/dev/null || sudo systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

for svc in libvirtd virtqemud; do
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
        sudo systemctl enable --now "${svc}.service" || true
        break
    fi
done

LIBVIRT_NET="192.168.122.0/24"
if ip -4 -o addr show 2>/dev/null | awk '$2 != "virbr0" && $4 ~ /^192\.168\.122\./ {found=1} END {exit !found}'; then
    LIBVIRT_NET="192.168.150.0/24"
fi

if ! sudo virsh net-info default &>/dev/null; then
    sudo virsh net-define /usr/share/libvirt/networks/default.xml || true
fi

if [[ "$LIBVIRT_NET" == "192.168.150.0/24" ]]; then
    LIBVIRT_NET_XML="$(mktemp)"
    if sudo virsh net-dumpxml default --inactive 2>/dev/null > "$LIBVIRT_NET_XML" && grep -q '192\.168\.122\.' "$LIBVIRT_NET_XML"; then
        sed -i 's/192\.168\.122\./192.168.150./g' "$LIBVIRT_NET_XML"
        sudo virsh net-destroy default 2>/dev/null || true
        sudo virsh net-undefine default 2>/dev/null || true
        sudo virsh net-define "$LIBVIRT_NET_XML" || true
    fi
    rm -f "$LIBVIRT_NET_XML"
fi

sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default 2>/dev/null || true

if command -v ufw &>/dev/null || [[ -x /usr/sbin/ufw ]]; then
    [[ -f /etc/default/ufw ]] && sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
    sudo ufw --force reset || true
    sudo ufw default deny incoming || true
    sudo ufw default allow outgoing || true
    sudo ufw allow in  on virbr0 || true
    sudo ufw allow out on virbr0 || true
    sudo ufw allow from "$LIBVIRT_NET" || true
    if pkg_installed openssh-server || [[ -x /usr/sbin/sshd ]] \
        || systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        sudo ufw allow ssh || true
    fi
    sudo ufw --force enable || true
    sudo systemctl enable --now ufw || true
fi

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
EOF
fi

sudo sed -i 's/^#\?[[:space:]]*DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=3s/' /etc/systemd/system.conf
sudo sed -i 's/^#\?[[:space:]]*DefaultTimeoutStartSec=.*/DefaultTimeoutStartSec=3s/' /etc/systemd/system.conf
sudo systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
sudo journalctl --vacuum-time=2d || true

for grp in libvirt libvirt-qemu kvm; do
    getent group "$grp" &>/dev/null && sudo usermod -aG "$grp" "$CURRENT_USER" || true
done

if command -v zsh &>/dev/null; then
    sudo chsh -s /usr/bin/zsh "$CURRENT_USER" || true
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
        [[ -d "$HOME/.oh-my-zsh" ]] || FAILED_PACKAGES+=("oh-my-zsh")
    fi
    P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    if [[ ! -d "$P10K_DIR" ]]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR" || FAILED_PACKAGES+=("powerlevel10k")
    fi
    if [[ -f ~/.zshrc ]]; then
        sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' ~/.zshrc || true
        sed -i 's/^plugins=(.*/plugins=(git sudo systemd debian)/' ~/.zshrc || true

        SHELL_LOCALE="${LANG:-${LC_ALL:-${LC_MESSAGES:-en_US.UTF-8}}}"
        if command -v locale &>/dev/null; then
            AVAILABLE_LOCALES="$(locale -a 2>/dev/null)"
            if ! echo "$AVAILABLE_LOCALES" | grep -qiF "$SHELL_LOCALE" && ! echo "$AVAILABLE_LOCALES" | grep -qiF "$(echo "$SHELL_LOCALE" | sed 's/UTF-8/utf8/')"; then
                SHELL_LOCALE="en_US.UTF-8"
            fi
        fi
        if ! grep -q "^export LC_ALL=" ~/.zshrc; then
            {
                echo ""
                echo "export LC_ALL=${SHELL_LOCALE}"
                echo "export LC_MESSAGES=${SHELL_LOCALE}"
                echo "fastfetch"
            } >> ~/.zshrc
        fi

        if ! grep -q "zsh-syntax-highlighting.zsh" ~/.zshrc; then
            {
                echo ""
                echo "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
                echo "source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
            } >> ~/.zshrc
        fi
    fi
fi


# =============================================================
#  ETAP 4/4: CZYSZCZENIE
# =============================================================
show_progress 12 $TOTAL_STEPS "$MSG_PHASE_4"
printf '\n\n' >&3

if [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
    log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}" "Failed to install: ${FAILED_PACKAGES[*]}"
fi

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}[OK] KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}[OK] CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
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
        DO_REBOOT=1
        ;;
esac
exit 0