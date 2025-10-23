#!/bin/bash
set -e

# =====================================================================
#  Y-Control Raspberry Pi Installationsscript
#  Enthält:
#   - Geräteauswahl & EDATEC-Setup
#   - Optional statische IP-Konfiguration (wie nmtui)
#   - Splash-Screen Installation & Aktivierung
#   - Docker & ycontrol Setup
#   - X-Server & Kiosk-Umgebung für 7" / 10" Geräte
#   - Automatischer Reboot am Ende
# =====================================================================

# -------------------------------------------------------
# Interaktive Eingabe
# -------------------------------------------------------

function ask() {
    local prompt=$1
    local default=$2
    local result
    read -p "${prompt} [${default}]: " result
    echo "${result:-$default}"
}

DEVICES=("hmi3010_070c" "hmi3010_101c" "hmi3120_070c" "hmi3120_101c" "hmi3120_116c" "ipc3630")

echo "--------------------------------------------------------"
echo "   Y-Control Raspberry Pi Installer"
echo "--------------------------------------------------------"
echo
echo "Bitte wähle dein Gerät:"
select TARGET in "${DEVICES[@]}"; do
    if [[ -n "$TARGET" ]]; then
        echo "Gerät ausgewählt: $TARGET"
        break
    else
        echo "Ungültige Auswahl."
    fi
done

echo
read -p "Willst du eine statische IP-Adresse konfigurieren? (j/N): " netchoice
if [[ "$netchoice" =~ ^[JjYy]$ ]]; then
    STATIC_IP=$(ask "IP-Adresse" "192.168.1.100")
    NETMASK=$(ask "Subnetzmaske" "255.255.255.0")
    GATEWAY=$(ask "Gateway" "192.168.1.1")
    DNS=$(ask "DNS-Server" "8.8.8.8")
    USE_STATIC_NET=true
else
    USE_STATIC_NET=false
fi

# -------------------------------------------------------
# Netzwerk-Konfiguration (optional)
# -------------------------------------------------------
function configure_network() {
    local iface
    iface=$(nmcli -t -f DEVICE,STATE dev status | awk -F: '$2=="connected"{print $1; exit}')

    if [ -z "$iface" ]; then
        echo "Kein aktives Netzwerkinterface gefunden."
        return
    fi

    echo "Setze statische IP-Konfiguration für $iface ..."
    sudo nmcli con mod "$iface" ipv4.method manual \
        ipv4.addresses "${STATIC_IP}/$(ipcalc -p "$STATIC_IP" "$NETMASK" | cut -d= -f2)" \
        ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${DNS}" \
        ipv6.method ignore

    sudo nmcli con down "$iface" || true
    sudo nmcli con up "$iface"

    echo "Netzwerkkonfiguration abgeschlossen:"
    nmcli dev show "$iface" | grep IP4
}

if [ "$USE_STATIC_NET" = true ]; then
    configure_network
else
    echo "DHCP bleibt aktiv."
fi

# -------------------------------------------------------
# Allgemeine Variablen
# -------------------------------------------------------

TIMEOUT=30
BASE_URL=https://apt.edatec.cn/bsp
TMP_PATH="/tmp/eda-common"

function log_error(){ echo -e "\033[31m${1}\033[0m"; }
function log_info(){  echo -e "\033[32m${1}\033[0m"; }

# -------------------------------------------------------
# 1. EDATEC / Splash Screen Setup
# -------------------------------------------------------

function install_eda(){
    local tmp_dir="${TMP_PATH}/eda/"
    mkdir -p "$tmp_dir"

    log_info "Installiere Splash-Screen-Unterstützung..."
    sudo apt-get install -y rpd-plym-splash

    wget -q https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/img/splash.png -O "${tmp_dir}splash.png"
    if [ -f "${tmp_dir}splash.png" ]; then
        sudo install -m 644 "${tmp_dir}splash.png" "/usr/share/plymouth/themes/pix/splash.png"
        log_info "Custom splash.png installiert."
    else
        log_error "Konnte splash.png nicht laden."
    fi

    log_info "Aktiviere Splash Screen & Autologin..."
    sudo raspi-config nonint do_boot_splash 0
    sudo raspi-config nonint do_boot_behaviour B2

    local code_name=$(grep VERSION_CODENAME= /etc/os-release | cut -d= -f2)
    local cmd_file="/boot/firmware/cmdline.txt"
    [ "${code_name}" != "bookworm" ] && cmd_file="/boot/cmdline.txt"

    grep -q "net.ifnames=0" ${cmd_file} || sed -i "1{s/$/ net.ifnames=0/}" ${cmd_file}

    wget -q "https://apt.edatec.cn/pubkey.gpg" -O "${tmp_dir}edatec.gpg"
    cat "${tmp_dir}edatec.gpg" | gpg --dearmor > "/etc/apt/trusted.gpg.d/edatec-archive-stable.gpg"
    echo "deb https://apt.edatec.cn/raspbian stable main" | sudo tee /etc/apt/sources.list.d/edatec.list > /dev/null
    sudo apt update -y
}

install_eda

# -------------------------------------------------------
# 2. Docker & ycontrol Setup
# -------------------------------------------------------

log_info "Starte Docker-Installation..."
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do 
    sudo apt-get remove -y $pkg 2>/dev/null || true
done

sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg subversion

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker $USER

sudo mkdir -p /home/pi/docker/
sudo mkdir -p /home/pi/y-red_Data/
sudo mkdir -p /home/pi/ycontrol-data/
sudo chown -R pi:pi /home/pi/docker/ /home/pi/y-red_Data/ /home/pi/ycontrol-data/

log_info "Lade y-control Dateien..."
sudo -u pi svn export --force https://github.com/ikulx/ycontrol-sh/trunk/vis/assets /home/pi/ycontrol-data/assets
sudo -u pi svn export --force https://github.com/ikulx/ycontrol-sh/trunk/vis/external /home/pi/ycontrol-data/external

log_info "Lade docker-compose.yml..."
sudo -u pi curl -fsSL -o /home/pi/docker/docker-compose.yml \
  https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/docker/dis/docker-compose.yml

log_info "Starte docker-compose..."
cd /home/pi/docker/
sudo -u pi docker compose up -d

# -------------------------------------------------------
# 3. XServer / Kiosk Setup (nur 7" / 10" Geräte)
# -------------------------------------------------------

if [[ "$TARGET" == "hmi3010_070c" || "$TARGET" == "hmi3120_070c" || "$TARGET" == "hmi3010_101c" || "$TARGET" == "hmi3120_101c" ]]; then
    log_info "Installiere XServer & Kiosk-Umgebung..."

    sudo apt-get install -y --no-install-recommends \
        xserver-xorg-video-all \
        xserver-xorg-input-all xserver-xorg-core xinit x11-xserver-utils \
        vlc chromium-browser-l10n unclutter \
        chromium-browser

    # bash_profile und xinitrc laden
    sudo -u pi curl -fsSL -o /home/pi/.bash_profile \
        https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/kiosk/.bash_profile

    if [[ "$TARGET" == "hmi3010_070c" || "$TARGET" == "hmi3120_070c" ]]; then
        sudo -u pi curl -fsSL -o /home/pi/.xinitrc \
            https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/kiosk/7z/.xinitrc
    else
        sudo -u pi curl -fsSL -o /home/pi/.xinitrc \
            https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/kiosk/10z/.xinitrc

        # Touchscreen-Kalibrierung (nur 10 Zoll)
        log_info "Füge Touchscreen-Kalibrierung hinzu..."
        sudo sed -i '/MatchIsTouchscreen "on"/a \ \ Option "CalibrationMatrix" "0 -1 1 1 0 0 0 0 0 1"' /usr/share/X11/xorg.conf.d/40-libinput.conf
    fi
    sudo chown pi:pi /home/pi/.bash_profile /home/pi/.xinitrc
fi

# -------------------------------------------------------
# 4. Abschluss & Reboot
# -------------------------------------------------------

log_info "Alle Installationen abgeschlossen."
echo "System wird in 5 Sekunden neu gestartet..."
sleep 5
sudo reboot
