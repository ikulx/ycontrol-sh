#!/bin/bash
set -e

# =====================================================================
#  Y-Control Raspberry Pi Installationsscript (Bookworm-kompatibel)
#  - Fixierter Header
#  - Fortschrittsanzeige
#  - GitHub main-Branch Download (kein svn)
# =====================================================================

TOTAL_STEPS=10
CURRENT_STEP=0

# -------------------------------------------------------
# Header zeichnen
# -------------------------------------------------------
draw_header() {
    tput clear
    tput cup 0 0
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
    echo
}

progress() {
    CURRENT_STEP=$((CURRENT_STEP+1))
    draw_header
    echo -e "[${CURRENT_STEP}/${TOTAL_STEPS}] $1"
    echo
}

log_info()  { echo -e "\033[32m[OK]\033[0m $1"; sleep 1; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1"; sleep 2; }

# -------------------------------------------------------
# 1. Gerätauswahl
# -------------------------------------------------------
progress "Starte Installation..."
sleep 1

DEVICES=("hmi3010_070c" "hmi3010_101c" "hmi3120_070c" "hmi3120_101c" "hmi3120_116c" "ipc3630")

progress "Gerät auswählen..."
select TARGET in "${DEVICES[@]}"; do
    if [[ -n "$TARGET" ]]; then
        echo "Gerät ausgewählt: $TARGET"
        sleep 1
        break
    else
        echo "Ungültige Auswahl."
    fi
done

# -------------------------------------------------------
# 2. Netzwerk-Eingabe
# -------------------------------------------------------
progress "Netzwerkkonfiguration..."
read -p "Willst du eine statische IP-Adresse konfigurieren? (j/N): " netchoice
USE_STATIC_NET=false

if [[ "$netchoice" =~ ^[JjYy]$ ]]; then
    while true; do
        read -p "IP-Adresse [192.168.1.100]: " STATIC_IP
        STATIC_IP=${STATIC_IP:-192.168.1.100}
        read -p "Subnetzmaske [255.255.255.0]: " NETMASK
        NETMASK=${NETMASK:-255.255.255.0}
        read -p "Gateway [192.168.1.1]: " GATEWAY
        GATEWAY=${GATEWAY:-192.168.1.1}
        read -p "DNS-Server [8.8.8.8]: " DNS
        DNS=${DNS:-8.8.8.8}

        draw_header
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
        fi
    done
fi

# -------------------------------------------------------
# 3. Netzwerk setzen
# -------------------------------------------------------
progress "Setze Netzwerkadresse..."
if [ "$USE_STATIC_NET" = true ]; then
    if grep -q "VERSION_CODENAME=bookworm" /etc/os-release; then
        iface=$(nmcli -t -f DEVICE,STATE dev status | awk -F: '$2=="connected"{print $1; exit}')
        sudo apt-get install -y -qq network-manager
        sudo nmcli connection modify "$iface" ipv4.method manual ipv4.addresses "${STATIC_IP}/24" ipv4.gateway "${GATEWAY}" ipv4.dns "${DNS}" ipv6.method ignore
        sudo nmcli connection down "$iface" || true
        sudo nmcli connection up "$iface"
        log_info "Statische IP für $iface konfiguriert."
    else
        echo -e "\ninterface eth0\nstatic ip_address=${STATIC_IP}/24\nstatic routers=${GATEWAY}\nstatic domain_name_servers=${DNS}\n" | sudo tee -a /etc/dhcpcd.conf >/dev/null
        sudo systemctl restart dhcpcd || true
        log_info "Netzwerk über dhcpcd konfiguriert."
    fi
else
    log_info "DHCP bleibt aktiv."
fi

# -------------------------------------------------------
# 4. Splashscreen
# -------------------------------------------------------
progress "Installiere Splashscreen..."
sudo apt-get update -qq
sudo apt-get install -y -qq rpd-plym-splash
sudo wget -q https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/img/splash.png -O /usr/share/plymouth/themes/pix/splash.png
sudo raspi-config nonint do_boot_splash 0
sudo raspi-config nonint do_boot_behaviour B2
log_info "Splashscreen eingerichtet."

# -------------------------------------------------------
# 5. Docker Installation
# -------------------------------------------------------
progress "Installiere Docker..."
sudo apt-get remove -y -qq docker.io docker-doc docker-compose podman-docker containerd runc || true
sudo apt-get install -y -qq ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker $USER
log_info "Docker installiert."

# -------------------------------------------------------
# 6. y-control Dateien
# -------------------------------------------------------
progress "Lade y-control Dateien..."
sudo mkdir -p /home/pi/docker /home/pi/y-red_Data /home/pi/ycontrol-data
sudo chown -R pi:pi /home/pi/docker /home/pi/y-red_Data /home/pi/ycontrol-data

# assets & external von main branch laden
sudo -u pi mkdir -p /home/pi/ycontrol-data/assets /home/pi/ycontrol-data/external
sudo -u pi curl -fsSL https://github.com/ikulx/ycontrol-sh/archive/refs/heads/main.tar.gz | sudo -u pi tar -xz --strip-components=2 -C /home/pi/ycontrol-data ycontrol-sh-main/vis/assets
sudo -u pi curl -fsSL https://github.com/ikulx/ycontrol-sh/archive/refs/heads/main.tar.gz | sudo -u pi tar -xz --strip-components=2 -C /home/pi/ycontrol-data ycontrol-sh-main/vis/external

sudo -u pi curl -fsSL -o /home/pi/docker/docker-compose.yml https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/docker/dis/docker-compose.yml
log_info "Dateien geladen."

# -------------------------------------------------------
# 7. Docker starten
# -------------------------------------------------------
progress "Starte Docker Compose..."
cd /home/pi/docker
sudo -u pi docker compose up -d
log_info "Container gestartet."

# -------------------------------------------------------
# 8. XServer/Kiosk
# -------------------------------------------------------
if [[ "$TARGET" =~ 070c$ || "$TARGET" =~ 101c$ ]]; then
    progress "Installiere XServer & Kiosk..."
    sudo apt-get install -y -qq --no-install-recommends xserver-xorg-video-all xserver-xorg-input-all xserver-xorg-core xinit x11-xserver-utils vlc chromium-browser-l10n unclutter chromium-browser
    sudo -u pi curl -fsSL -o /home/pi/.bash_profile https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/kiosk/.bash_profile
    if [[ "$TARGET" =~ 070c$ ]]; then
        sudo -u pi curl -fsSL -o /home/pi/.xinitrc https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/kiosk/7z/.xinitrc
    else
        sudo -u pi curl -fsSL -o /home/pi/.xinitrc https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/kiosk/10z/.xinitrc
        sudo sed -i '/MatchIsTouchscreen "on"/a \ \ Option "CalibrationMatrix" "0 -1 1 1 0 0 0 0 0 1"' /usr/share/X11/xorg.conf.d/40-libinput.conf
    fi
    sudo chown pi:pi /home/pi/.bash_profile /home/pi/.xinitrc
    log_info "Kioskmodus eingerichtet."
fi

# -------------------------------------------------------
# 9. Abschluss
# -------------------------------------------------------
progress "Abschluss..."
log_info "Alle Installationen abgeschlossen."

# -------------------------------------------------------
# 10. Reboot
# -------------------------------------------------------
progress "Starte System neu..."
sleep 3
sudo reboot
