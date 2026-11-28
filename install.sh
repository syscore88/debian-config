#!/bin/bash
# =========================================
# KOMPLEKSOWY SKRYPT KONFIGURACYJNY Debian
# =========================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/sbin:/sbin:$PATH"

detect_system_lang() {
    local sys_lang="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
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
DEB_DIR="$(mktemp -d /tmp/debs.XXXXXX)"

FAILED_PACKAGES=()
SUDOERS_TMP=""
LSFG_TMP=""
LIBVIRT_NET_XML=""
LIBVIRT_NET_BAK=""
LIBVIRT_NET_RESTORE=0
SUDO_READY=0
USE_RUN0=0
SUDO_KEEPALIVE_PID=""
QUIET_WARNS=0
RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
TEMP_SUDOERS="/etc/sudoers.d/99-temp-installer"
APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

exec 3>&1
exec >>"$TMP_LOG" 2>&1

_sudo_n() {
    if [ "${USE_RUN0:-0}" -eq 1 ]; then
        sudo "$@"
    else
        sudo -n "$@"
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    trap '' INT TERM HUP
    trap - ERR
    set +e

    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    declare -F restore_packagekit >/dev/null && restore_packagekit

    if [ "${SUDO_READY:-0}" = "1" ] && [ "${LIBVIRT_NET_RESTORE:-0}" = "1" ] && [ -s "${LIBVIRT_NET_BAK:-}" ]; then
        _sudo_n virsh net-define "$LIBVIRT_NET_BAK" &>/dev/null
        _sudo_n virsh net-start default &>/dev/null
        _sudo_n virsh net-autostart default &>/dev/null
    fi

    rm -f "$SUDOERS_TMP" "$LIBVIRT_NET_XML" "$LIBVIRT_NET_BAK"
    rm -rf "$LSFG_TMP" "$DEB_DIR"

    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ] || [ "${QUIET_WARNS:-0}" -gt 0 ]; then
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null
    else
        rm -f "$LOG_FILE"
    fi

    {
        printf '\033[?7h'
        if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
            echo -e "\n"
        fi
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}[X] Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}"
            else
                echo -e "${ERR}[X] An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}"
            fi
        fi
    } >&3 2>/dev/null
    rm -f "$TMP_LOG"

    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        _sudo_n sh -c 'rm -f "$1" "$2"; systemctl try-restart polkit 2>/dev/null; if [ "$3" = 1 ]; then systemctl reboot; fi' _ \
            "$RUN0_NOPASSWD_FILE" "$TEMP_SUDOERS" "$do_reboot"
    fi
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() { printf "\r\033[K" >&3 2>/dev/null || true; echo -e "$1" >&3 2>/dev/null || true; echo -e "$1"; cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true; }
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}[OK] $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}[X] ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}[!] WARN: $m${NC}"; }
log_quiet() { local m; m="$(_pick_msg "$1" "$2")"; QUIET_WARNS=$((QUIET_WARNS + 1)); echo "[!] WARN: $m"; cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

# ==========================================================
# PACKAGEKIT + BLOKADA MENEDŻERA PAKIETÓW
# ==========================================================
PACKAGEKIT_MASKED=0
PACKAGEKIT_UNITS=(packagekit.service packagekit-offline-update.service)

disable_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] && return 0
    PACKAGEKIT_MASKED=1
    sudo systemctl stop "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    if command -v killall >/dev/null 2>&1; then
        sudo killall -q packagekitd 2>/dev/null || true
    else
        sudo pkill -x packagekitd 2>/dev/null || true
    fi
    sudo systemctl mask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
}

restore_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] || return 0
    _sudo_n systemctl unmask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
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

    printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3 2>/dev/null || true
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

if [[ "$EUID" -eq 0 ]]; then
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}[X] Nie uruchamiaj skryptu jako root. Użyj zwykłego użytkownika z sudo.${NC}" >&3 2>/dev/null || true
    else
        echo -e "${ERR}[X] Do not run this script as root. Run as a normal user with sudo.${NC}" >&3 2>/dev/null || true
    fi
    exit 1
fi

CURRENT_USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

printf '\033[?7h\n' >&3 2>/dev/null || true

USE_RUN0=0
SUDO_VERSION_OUT="$(sudo --version 2>/dev/null || true)"
if ! command -v visudo >/dev/null 2>&1 || grep -qi "run0" <<< "$SUDO_VERSION_OUT"; then
    USE_RUN0=1
fi

if [[ "$USE_RUN0" -eq 1 ]]; then
    if printf 'polkit.addRule(function(action, subject) {\n    if (subject.user == "%s") {\n        return polkit.Result.YES;\n    }\n});\n' "$CURRENT_USER" | sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null; then
        SUDO_READY=1
        sudo systemctl try-restart polkit 2>/dev/null || true
    else
        log_err "Nie udało się uzyskać uprawnień administratora." "Failed to obtain administrator privileges."
        exit 1
    fi
else
    sudo -v
    SUDO_READY=1

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
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "$TEMP_SUDOERS"
    else
        rm -f "$SUDOERS_TMP"
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}[X] Nieprawidłowa składnia pliku sudoers – przerywam.${NC}" >&3 2>/dev/null || true
        else
            echo -e "${ERR}[X] Invalid sudoers rule syntax - aborting.${NC}" >&3 2>/dev/null || true
        fi
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
    SUDOERS_TMP=""
fi

printf '\033[?7l' >&3 2>/dev/null || true

# ==========================================================
#  ETAP 1/4: PRZYGOTOWYWANIE
# ==========================================================
show_progress 0 $TOTAL_STEPS "$MSG_PHASE_1"

disable_packagekit

apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@"
}

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
        apt_get install -yq "${APT_OPTS[@]}" "$pkg" || FAILED_PACKAGES+=("$pkg")
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
apt_get update -yq || log_quiet "apt-get update zakończył się błędem." "apt-get update failed."
apt_get full-upgrade -yq "${APT_OPTS[@]}" || log_quiet "apt-get full-upgrade zakończył się błędem." "apt-get full-upgrade failed."
apt_get autoremove -yq || true
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

    grep -qi "nvidia" <<< "$GPU_INFO" && GPU_VENDORS+=("nvidia")
    grep -qi -E "\b(amd|ati)\b|advanced micro devices|radeon" <<< "$GPU_INFO" && GPU_VENDORS+=("amd")
    grep -qi "intel" <<< "$GPU_INFO" && GPU_VENDORS+=("intel")

    TOTAL_KNOWN=${#GPU_VENDORS[@]}

    if [ -z "$GPU_INFO" ] || [ "$TOTAL_KNOWN" -eq 0 ]; then
        HYBRID_GPU=false
        install_apt_pkgs "${GPU_UNKNOWN_PKGS[@]}"
    elif [ "$TOTAL_KNOWN" -ge 2 ]; then
        HYBRID_GPU=true
        GPU_TYPE="$(IFS=+; echo "${GPU_VENDORS[*]}")"
        _pick_msg "Wykryto hybrydowy układ graficzny (HYBRID_GPU=$HYBRID_GPU): $GPU_TYPE" "Detected a hybrid GPU setup (HYBRID_GPU=$HYBRID_GPU): $GPU_TYPE"
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

CORE_PKGS=(sudo systemd network-manager plasma-desktop plasma-workspace
           gnome-shell gnome-session gdm3 plasma-login-manager cosmic-session xwayland sudo)
CORE_RE="^($(IFS='|'; echo "${CORE_PKGS[*]}"))\$"
TO_REMOVE_RE="^($(IFS='|'; echo "${TO_REMOVE[*]}"))\$"

would_remove_core() {
    local removed
    removed="$(apt_get -s "$@" 2>/dev/null | awk '/^Remv /{print $2}')" || true
    grep -Eq "$CORE_RE" <<< "$removed"
}

wait_for_apt
for meta in gnome gnome-core task-gnome-desktop task-kde-desktop kde-standard kde-plasma-desktop kde-full task-xfce-desktop task-cinnamon-desktop task-mate-desktop; do
    pkg_installed "$meta" || continue
    mapfile -t META_DEPS < <(
        apt-cache depends "$meta" 2>/dev/null \
        | awk '/(Depends|Recommends):/ && $2 !~ /^</ {gsub(/:.*/, "", $2); print $2}' \
        | grep -Ev "$TO_REMOVE_RE" \
        | sort -u || true
    )
    if [[ ${#META_DEPS[@]} -gt 0 ]]; then
        mapfile -t INSTALLED_META_DEPS < <(
            dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' "${META_DEPS[@]}" 2>/dev/null \
            | awk '$1 ~ /^ii/ {print $2}' || true
        )
        [[ ${#INSTALLED_META_DEPS[@]} -gt 0 ]] && sudo apt-mark manual "${INSTALLED_META_DEPS[@]}" >/dev/null || true
    fi
done
for core in "${CORE_PKGS[@]}"; do
    pkg_installed "$core" && sudo apt-mark manual "$core" >/dev/null || true
done
for pkg in "${TO_REMOVE[@]}"; do
    pkg_installed "$pkg" || continue
    if would_remove_core purge -y "$pkg"; then
        log_quiet "Pomijam usunięcie $pkg - pociągnęłoby kluczowe pakiety pulpitu." \
                 "Skipping removal of $pkg - it would remove core desktop packages."
        continue
    fi
    apt_get purge -yq "$pkg" || true
done
if would_remove_core autoremove --purge -y; then
    log_quiet "Pomijam autoremove - usunąłby kluczowe pakiety pulpitu." \
             "Skipping autoremove - it would remove core desktop packages."
else
    apt_get autoremove --purge -yq || true
fi

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
    if curl -fsSL --retry 3 --retry-delay 2 https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg; then
        sudo chmod 644 /etc/apt/keyrings/google-chrome.gpg || true
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null || true
    else
        sudo rm -f /etc/apt/keyrings/google-chrome.gpg 2>/dev/null || true
        log_quiet "Nie udało się dodać repozytorium Google Chrome." "Failed to add Google Chrome repository."
    fi
fi

sudo mkdir -p /usr/share/keyrings
sudo rm -f /usr/share/keyrings/brave-origin-archive-keyring.gpg /etc/apt/sources.list.d/brave-origin-release.sources
if sudo curl -fsSL --retry 3 --retry-delay 2 -o /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    && sudo curl -fsSL --retry 3 --retry-delay 2 -o /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources; then
    sudo chmod 644 /usr/share/keyrings/brave-browser-archive-keyring.gpg || true
else
    sudo rm -f /usr/share/keyrings/brave-browser-archive-keyring.gpg /etc/apt/sources.list.d/brave-browser-release.sources 2>/dev/null || true
    log_quiet "Nie udało się dodać repozytorium Brave." "Failed to add Brave repository."
fi

sudo mkdir -p /etc/NetworkManager/conf.d
echo -e "[main]\ndns=default\nrc-manager=symlink" | sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null
echo -e "[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002" | sudo tee /etc/NetworkManager/conf.d/global-dns.conf > /dev/null

sudo nmcli general reload 2>/dev/null || sudo systemctl reload NetworkManager 2>/dev/null || true
ACTIVE_CONN="$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
    | awk -F: '$2 != "" && $2 != "lo" && $2 !~ /^(virbr|docker|br-|veth|tun|tap)/ {print $1; exit}' || true)"
if [[ -n "$ACTIVE_CONN" ]]; then
    sudo nmcli connection modify uuid "$ACTIVE_CONN" ipv4.dns "1.1.1.2,1.0.0.2" ipv6.dns "2606:4700:4700::1112,2606:4700:4700::1002" || true
    sudo nmcli connection up uuid "$ACTIVE_CONN" || true
fi

show_progress 3 $TOTAL_STEPS "$MSG_PHASE_1"

# ==========================================================
#  ETAP 2/4: INSTALACJA
# ==========================================================
show_progress 4 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_apt
apt_get update -yq || log_quiet "apt-get update zakończył się błędem." "apt-get update failed."

show_progress 5 $TOTAL_STEPS "$MSG_PHASE_2"

SYSTEM_PKGS=(
    google-chrome-stable brave-origin
    audacity gimp krita mixxx kdenlive handbrake soundconverter
    vim dconf-editor hunspell-pl fastfetch bleachbit profile-sync-daemon
    plymouth plymouth-themes unrar-free mc btrfs-progs exfatprogs ntfs-3g os-prober
    adb fastboot fsarchiver inxi pv rsync cdemu-daemon cdemu-client
    7zip makeself zenity innoextract needrestart flatpak timeshift
    python3-defusedxml python3-packaging python3-pip python3-tqdm vlc vlc-plugin-access-extra
    libayatana-appindicator3-1 gamemode mangohud audacious
    gcc g++ clang llvm make cmake meson ninja-build just build-essential git
    dkms linux-headers-amd64 libelf-dev
    qt6-tools-dev ghostwriter qbittorrent gnome-disk-utility
    zsh zsh-syntax-highlighting zsh-autosuggestions pkg-config
    cabextract unzip wget xz-utils winetricks wine wine64
    isenkram-cli firmware-linux-nonfree systemd-zram-generator
    virt-manager qemu-system qemu-utils libvirt-daemon-system libvirt-clients
    qt6-qpa-plugins libqt6quick6 qml6-module-qtquick-controls
    qml6-module-qtquick-layouts qml6-module-qtquick-window
    qml6-module-qtquick-dialogs qml6-module-qtqml-workerscript
    qml6-module-qtquick-templates qml6-module-qt-labs-folderlistmodel
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
        "nvidia") SYSTEM_PKGS+=(nvidia-open-kernel-dkms nvidia-driver nvidia-driver-libs:i386 vulkan-tools libvulkan-dev libgl1-mesa-dev mesa-common-dev libgl1-nvidia-glvnd-glx:i386 nvidia-vaapi-driver:amd64 nvidia-vaapi-driver:i386 nvidia-opencl-icd:amd64) ;;
        "amd")    SYSTEM_PKGS+=(libgl1-mesa-dri:amd64 libgl1-mesa-dri:i386 mesa-vulkan-drivers:amd64 mesa-vulkan-drivers:i386 libglx-mesa0:amd64 libglx-mesa0:i386 vulkan-tools libvulkan-dev libgl1-mesa-dev mesa-common-dev mesa-va-drivers:amd64 mesa-va-drivers:i386 mesa-opencl-icd:amd64) ;;
        "intel")  SYSTEM_PKGS+=(libgl1-mesa-dri:amd64 libgl1-mesa-dri:i386 mesa-vulkan-drivers:amd64 mesa-vulkan-drivers:i386 libglx-mesa0:amd64 libglx-mesa0:i386 vulkan-tools libvulkan-dev libgl1-mesa-dev mesa-common-dev intel-media-va-driver-non-free:amd64 intel-media-va-driver-non-free:i386 intel-opencl-icd:amd64) ;;
    esac
done

if ! pkg_installed "linux-headers-$(uname -r)" && apt-cache show "linux-headers-$(uname -r)" &>/dev/null; then
    SYSTEM_PKGS+=("linux-headers-$(uname -r)")
fi

if [ "${#SYSTEM_PKGS[@]}" -gt 0 ]; then
    readarray -t SYSTEM_PKGS < <(printf '%s\n' "${SYSTEM_PKGS[@]}" | awk '!seen[$0]++')
fi

install_apt_pkgs "${SYSTEM_PKGS[@]}"
install_apt_pkgs "${PKGS_32BIT[@]}"
install_apt_pkgs "${PKGS_CODECS[@]}"

if ! pkg_installed telegram-desktop; then
    wait_for_apt
    if ! apt_get install -yq "${APT_OPTS[@]}" telegram-desktop 2>/dev/null; then
        apt_get install -yq "${APT_OPTS[@]}" -t "${DEBIAN_CODENAME}-backports" telegram-desktop 2>/dev/null || FAILED_PACKAGES+=("telegram-desktop")
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
            sed -i 's/^Hidden=.*/Hidden=true/' "$HOME/.config/autostart/$(basename "$f")" || true
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
get_github_deb_url() { local j; j="$(curl -sfL "https://api.github.com/repos/${1}/releases/latest" 2>/dev/null || true)"; grep -m1 "\"browser_download_url\".*${2}\"" <<< "$j" | cut -d '"' -f 4 || true; }

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
        apt_get install -yq "${APT_OPTS[@]}" "$deb" || FAILED_PACKAGES+=("$(basename "$deb" .deb)")
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
            printf '%s' "$LSFG_HTML" | grep -oiE '(href|src)=["'\''][^"'\'']*lsfg-vk-[0-9]+(\.[0-9]+)*(-[A-Za-z0-9._-]+)?\.tar\.xz["'\'']' | sed -E 's/^(href|src)=["'\'']//I; s/["'\'']$//' || true
            printf '%s' "$LSFG_HTML" | grep -oiE '(https?://[^"'\'' <>[:space:]]+/)?lsfg-vk-[0-9]+(\.[0-9]+)*(-[A-Za-z0-9._-]+)?\.tar\.xz' || true
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
            if grep -qE '(^|/)bin/lsfg-vk-(ui|cli)$' <<< "$LSFG_TAR_LIST"; then
                BIN_LINE="$(grep -m1 -E '(^|/)bin/lsfg-vk-(ui|cli)$' <<< "$LSFG_TAR_LIST")"
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
else
    for LSFG_BIN in lsfg-vk-ui lsfg-vk-cli; do
        if [[ -x "$HOME/.local/bin/$LSFG_BIN" ]]; then
            sudo ln -sf "$HOME/.local/bin/$LSFG_BIN" "/usr/local/bin/$LSFG_BIN" || true
        fi
    done
    mkdir -p "$HOME/.local/share/applications"
    for LSFG_DESKTOP in "$HOME"/.local/share/applications/*lsfg*.desktop; do
        [[ -f "$LSFG_DESKTOP" ]] || continue
        sed -i -E "s|^Exec=\"?lsfg-vk-ui|Exec=$HOME/.local/bin/lsfg-vk-ui|; /^TryExec=/d" "$LSFG_DESKTOP" || true
    done
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    kbuildsycoca6 2>/dev/null || true
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

    GRUB_CMDLINE_CURRENT="$(awk -F= '/^GRUB_CMDLINE_LINUX_DEFAULT=/{v=substr($0, index($0,"=")+1); gsub(/^["\047]|["\047]$/, "", v); last=v} END{print last}' /etc/default/grub 2>/dev/null || true)"
    GRUB_CMDLINE_NEW="$GRUB_CMDLINE_CURRENT"
    for param in "${GRUB_PARAMS[@]}"; do
        if [[ " $GRUB_CMDLINE_NEW " != *" $param "* ]]; then
            GRUB_CMDLINE_NEW="${GRUB_CMDLINE_NEW:+$GRUB_CMDLINE_NEW }${param}"
        fi
    done
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        if [[ "$GRUB_CMDLINE_NEW" != "$GRUB_CMDLINE_CURRENT" ]]; then
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"|" /etc/default/grub || true
        fi
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"" | sudo tee -a /etc/default/grub > /dev/null || true
    fi
    if grep -q '^#\?GRUB_TIMEOUT=' /etc/default/grub; then
        sudo sed -i 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub || true
    else
        echo 'GRUB_TIMEOUT=0' | sudo tee -a /etc/default/grub > /dev/null || true
    fi
    sudo update-grub || true
fi

show_progress 10 $TOTAL_STEPS "$MSG_PHASE_3"

sudo plymouth-set-default-theme bgrt 2>/dev/null || true

MODULES_FILE="/etc/initramfs-tools/modules"
if [ -f "$MODULES_FILE" ]; then
    add_module() { grep -qxF "$1" "$MODULES_FILE" || echo "$1" | sudo tee -a "$MODULES_FILE" > /dev/null; }

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
    if grep -q "$svc" <<< "$(systemctl list-unit-files "${svc}.service" 2>/dev/null)"; then
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
    LIBVIRT_NET_BAK="$(mktemp)"
    if sudo virsh net-dumpxml default --inactive 2>/dev/null > "$LIBVIRT_NET_XML" && grep -q '192\.168\.122\.' "$LIBVIRT_NET_XML"; then
        cp -f "$LIBVIRT_NET_XML" "$LIBVIRT_NET_BAK"
        sed -i 's/192\.168\.122\./192.168.150./g' "$LIBVIRT_NET_XML" || true
        LIBVIRT_NET_RESTORE=1
        sudo virsh net-destroy default 2>/dev/null || true
        sudo virsh net-undefine default 2>/dev/null || true
        if ! sudo virsh net-define "$LIBVIRT_NET_XML"; then
            sudo virsh net-define "$LIBVIRT_NET_BAK" || true
        fi
        LIBVIRT_NET_RESTORE=0
    fi
    rm -f "$LIBVIRT_NET_XML" "$LIBVIRT_NET_BAK"
fi

sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default 2>/dev/null || true

if command -v ufw &>/dev/null || [[ -x /usr/sbin/ufw ]]; then
    [[ -f /etc/default/ufw ]] && sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
    UFW_STATUS="$(sudo ufw status 2>/dev/null || true)"
    UFW_WAS_ACTIVE=0
    grep -qi '^Status: active' <<< "$UFW_STATUS" && UFW_WAS_ACTIVE=1
    if [[ "$UFW_WAS_ACTIVE" -eq 0 ]]; then
        sudo ufw default deny incoming || true
        sudo ufw default allow outgoing || true
    fi
    sudo ufw allow in  on virbr0 || true
    sudo ufw allow out on virbr0 || true
    sudo ufw allow from "$LIBVIRT_NET" || true
    if pkg_installed openssh-server || [[ -x /usr/sbin/sshd ]] \
        || systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        SSH_PORT="$(sudo sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
        [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
        sudo ufw allow "${SSH_PORT}/tcp" || true
    fi
    if [[ "$UFW_WAS_ACTIVE" -eq 1 ]]; then
        sudo ufw reload || true
    else
        sudo ufw --force enable || true
    fi
    sudo systemctl enable --now ufw || true
fi

if command -v dconf &>/dev/null; then
    dconf load /org/virt-manager/virt-manager/ <<'EOF' || true
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

sudo mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultTimeoutStopSec=3s\n' | sudo tee /etc/systemd/system.conf.d/10-timeouts.conf >/dev/null || true
if [ -f /etc/systemd/system.conf ]; then
    sudo sed -i 's/^DefaultTimeoutStartSec=3s$/#DefaultTimeoutStartSec=90s/' /etc/systemd/system.conf 2>/dev/null || true
fi
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

        SHELL_LOCALE="${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US.UTF-8}}}"
        if command -v locale &>/dev/null; then
            AVAILABLE_LOCALES="$(locale -a 2>/dev/null || true)"
            if ! grep -qiF "$SHELL_LOCALE" <<< "$AVAILABLE_LOCALES" && ! grep -qiF "${SHELL_LOCALE//UTF-8/utf8}" <<< "$AVAILABLE_LOCALES"; then
                SHELL_LOCALE="en_US.UTF-8"
            fi
        fi
        if ! grep -q "^export LC_ALL=" ~/.zshrc; then
            {
                echo ""
                echo "export LC_ALL=${SHELL_LOCALE}"
                echo "export LC_MESSAGES=${SHELL_LOCALE}"
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
printf '\n\n' >&3 2>/dev/null || true

if [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
    log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}" "Failed to install: ${FAILED_PACKAGES[*]}"
fi

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}[OK] KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3 2>/dev/null || true
else
    echo -e "${SUCCESS}[OK] CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3 2>/dev/null || true
fi

# ==========================================================
#  RESTART SYSTEMU
# ==========================================================
if [[ "$SCRIPT_LANG" == "pl" ]]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
echo -en "${INFO}==> ${RESTART_PROMPT}${NC}" >&3 2>/dev/null || true
RESTART_CHOICE=""
read -r RESTART_CHOICE < /dev/tty || RESTART_CHOICE=""
case "$RESTART_CHOICE" in
    [YyTt]*)
        DO_REBOOT=1
        ;;
esac
exit 0
