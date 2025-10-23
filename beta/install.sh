#!/bin/bash
set -e

# =====================================================================
#  Y-Control Raspberry Pi Installationsscript (mit Header & Logo)
# =====================================================================

# -------------------------------------------------------
# Header-Logo anzeigen
# -------------------------------------------------------
clear
cat <<'EOF'
       ██            ██                                                                                                 
      █████        █████                                                                                                
     ████████    ████████                                                                                               
    ██████████ ███████████                                                                                              
   ███████████████████████   ██████        ██████     █████████       █████        ██████    ██████       █████████     
   ███████████████████████   ███████      ███████  ███████████████    ███████      ██████    ██████    ███████████████  
  ██████████ █████████████    ███████    ███████  █████████████████   █████████    ██████    ██████   ████████████████  
 ██████████  ████████████      ███████  ███████ █████████    ████     ██████████   ██████    ██████   ███████     ███   
 █████████   ████████████       ██████████████  ███████    ███████    ████████████ ██████    ██████   ███████████       
 ████████   ████████████         ████████████   ███████   █████████   ███████████████████    ██████    ██████████████   
 ████████  ███████████            ██████████    ███████   █████████   ███████████████████    ██████     ███████████████ 
  ██████   ██████████              ████████     ███████    ████████   ██████  ███████████    ██████           █████████ 
  ██████  ██████████              ████████       ██████████████████   ██████   ██████████    ██████    ████████████████ 
    ████ █████████               ███████          █████████████████   ██████     ████████    ██████   ████████████████  
      ███████████               ███████             ██████████████    ██████       ██████    ██████   ██████████████    
        ███████                                                                                                         
         ████                                                                                                           

--------------------------------------------------------
           Y-Control Raspberry Pi Installer
--------------------------------------------------------

EOF

# -------------------------------------------------------
# Logging-Funktionen
# -------------------------------------------------------
log_error() { echo -e "\033[31m${1}\033[0m"; }
log_info()  { echo -e "\033[32m${1}\033[0m"; }

# -------------------------------------------------------
# Interaktive Eingabe
# -------------------------------------------------------
ask() {
    local prompt=$1
    local default=$2
    local result
    read -p "${prompt} [${default}]: " result
    echo "${result:-$default}"
}

DEVICES=("hmi3010_070c" "hmi3010_101c" "hmi3120_070c" "hmi3120_101c" "hmi3120_116c" "ipc3630")

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
    while true; do
        STATIC_IP=$(ask "IP-Adresse" "192.168.1.100")
        NETMASK=$(ask "Subnetzmaske" "255.255.255.0")
        GATEWAY=$(ask "Gateway" "192.168.1.1")
        DNS=$(ask "DNS-Server" "8.8.8.8")

        echo
        echo "--------------------------------------------------------"
        echo "  Bitte überprüfe deine Netzwerkkonfiguration:"
        echo "--------------------------------------------------------"
        echo "  IP-Adresse:   ${STATIC_IP}"
        echo "  Subnetzmaske: ${NETMASK}"
        echo "  Gateway:      ${GATEWAY}"
        echo "  DNS:          ${DNS}"
        echo "--------------------------------------------------------"
        read -p "Sind diese Angaben korrekt? (J/n): " confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            USE_STATIC_NET=true
            break
        else
            echo "Bitte gib die Werte erneut ein."
            echo
        fi
    done
else
    USE_STATIC_NET=false
fi

# -------------------------------------------------------
# Netzwerk-Konfiguration (Bookworm-kompatibel)
# -------------------------------------------------------
configure_network_bookworm() {
    log_info "Erkenne aktives Netzwerkinterface..."
    local iface
    iface=$(nmcli -t -f DEVICE,STATE dev status | awk -F: '$2=="connected"{print $1; exit}')

    if [ -z "$iface" ]; then
        log_error "Kein aktives Netzwerkinterface gefunden!"
        return 1
    fi

    log_info "Setze statische IP-Konfiguration über NetworkManager..."
    sudo apt-get install -y network-manager

    sudo nmcli connection modify "$iface" ipv4.method manual \
        ipv4.addresses "${STATIC_IP}/24" \
        ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${DNS}" \
        ipv4.dns-search "" \
        ipv6.method ignore

    sudo nmcli connection down "$iface" || true
    sudo nmcli connection up "$iface"

    log_info "Statische IP erfolgreich gesetzt für $iface."
    nmcli dev show "$iface" | grep IP4
}

configure_network_dhcpcd() {
    local config="/etc/dhcpcd.conf"
    echo "" | sudo tee -a $config > /dev/null
    echo "# --- Y-Control static network configuration ---" | sudo tee -a $config > /dev/null
    echo "interface eth0" | sudo tee -a $config > /dev/null
    echo "static ip_address=${STATIC_IP}/24" | sudo tee -a $config > /dev/null
    echo "static routers=${GATEWAY}" | sudo tee -a $config > /dev/null
    echo "static domain_name_servers=${DNS}" | sudo tee -a $config > /dev/null
    echo "" | sudo tee -a $config > /dev/null

    log_info "Netzwerk-Konfiguration gespeichert in $config"
    sudo systemctl restart dhcpcd || log_error "dhcpcd konnte nicht neu gestartet werden."
}

if [ "$USE_STATIC_NET" = true ]; then
    if grep -q "VERSION_CODENAME=bookworm" /etc/os-release; then
        log_info "Bookworm erkannt – verwende NetworkManager."
        configure_network_bookworm
    else
        log_info "Verwende dhcpcd (älteres Raspberry Pi OS)."
        configure_network_dhcpcd
    fi
else
    echo "DHCP bleibt aktiv."
fi

# -------------------------------------------------------
# Allgemeine Variablen
# -------------------------------------------------------
TIMEOUT=30
BASE_URL=https://apt.edatec.cn/bsp
TMP_PATH="/tmp/eda-common"

# -------------------------------------------------------
# 1. EDATEC / Splash Screen Setup
# -------------------------------------------------------
install_eda() {
    local tmp_dir="${TMP_PATH}/eda/"
    mkdir -p "$tmp_dir"

    log_info "Installiere Splash-Screen-Unterstützung..."
    sudo apt-get update -y
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

    grep -q "net.ifnames=0" ${cmd_file} || sudo sed -i "1{s/$/ net.ifnames=0/}" ${cmd_file}

    wget -q "https://apt.edatec.cn/pubkey.gpg" -O "${tmp_dir}edatec.gpg"
    cat "${tmp_dir}edatec.gpg" | gpg --dearmor | sudo tee "/etc/apt/trusted.gpg.d/edatec-archive-stable.gpg" > /dev/null
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

sudo mkdir -p /home/pi/docker/ /home/pi/y-red_Data/ /home/pi/ycontrol-data/
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
# 3. XServer / Kiosk Setup
# -------------------------------------------------------
if [[ "$TARGET" =~ 070c$ || "$TARGET" =~ 101c$ ]]; then
    log_info "Installiere XServer & Kiosk-Umgebung..."
    sudo apt-get install -y --no-install-recommends \
        xserver-xorg-video-all \
        xserver-xorg-input-all xserver-xorg-core xinit x11-xserver-utils \
        vlc chromium-browser-l10n unclutter chromium-browser

    sudo -u pi curl -fsSL -o /home/pi/.bash_profile \
        https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/kiosk/.bash_profile

    if [[ "$TARGET" =~ 070c$ ]]; then
        sudo -u pi curl -fsSL -o /home/pi/.xinitrc \
            https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/kiosk/7z/.xinitrc
    else
        sudo -u pi curl -fsSL -o /home/pi/.xinitrc \
            https://raw.githubusercontent.com/ikulx/ycontrol-sh/refs/heads/main/kiosk/10z/.xinitrc
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
