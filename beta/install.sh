#!/bin/bash
set -Eeuo pipefail

# =====================================================================
#  Y-Control Raspberry Pi Installer  –  Bookworm 64-bit
# =====================================================================
TOTAL_STEPS=11
CURRENT_STEP=0
CURRENT_ACTION="Initialisierung"

# -------------------------------------------------------
# Fehlerbehandlung
# -------------------------------------------------------
error_handler() {
  local exit_code=$?
  local line_no=$1
  echo -e "\n\033[31m--------------------------------------------------------\033[0m"
  echo -e "\033[31m[FEHLER]\033[0m in Zeile ${line_no} bei Schritt: '${CURRENT_ACTION}'"
  echo -e "\033[31mDas Script wurde mit Fehlercode ${exit_code} abgebrochen.\033[0m"
  echo -e "\033[31m--------------------------------------------------------\033[0m"
  exit $exit_code
}
trap 'error_handler $LINENO' ERR

# -------------------------------------------------------
# Anzeige-Hilfen
# -------------------------------------------------------
draw_header() {
  tput clear
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
  CURRENT_ACTION="$1"
  draw_header
  echo -e "[${CURRENT_STEP}/${TOTAL_STEPS}] $1"
  echo
}

log_info() { echo -e "\033[32m[OK]\033[0m $1"; sleep 1; }

# -------------------------------------------------------
# 1. Gerätauswahl
# -------------------------------------------------------
progress "Starte Installation..."
DEVICES=("hmi3010_070c" "hmi3010_101c" "hmi3120_070c" "hmi3120_101c" "hmi3120_116c" "ipc3630")
progress "Gerät auswählen..."
select TARGET in "${DEVICES[@]}"; do
  [[ -n "$TARGET" ]] && break || echo "Ungültige Auswahl."
done
echo "Gerät ausgewählt: $TARGET"
sleep 1

# -------------------------------------------------------
# 2. Netzwerkkonfiguration
# -------------------------------------------------------
progress "Netzwerkkonfiguration..."
USE_STATIC_NET=false
read -p "Willst du eine statische IP-Adresse konfigurieren? (j/N): " netchoice
if [[ "$netchoice" =~ ^[JjYy]$ ]]; then
  USE_STATIC_NET=true
  echo
  read -p "Willst du die Standardkonfiguration verwenden (192.168.10.31 / 255.255.255.0 / 192.168.10.1 / 1.1.1.2)? (J/n): " stdchoice
  if [[ ! "$stdchoice" =~ ^[Nn]$ ]]; then
    STATIC_IP="192.168.10.31"; NETMASK="255.255.255.0"; GATEWAY="192.168.10.1"; DNS="1.1.1.2"
  else
    while true; do
      read -p "IP-Adresse [192.168.1.100]: " STATIC_IP; STATIC_IP=${STATIC_IP:-192.168.1.100}
      read -p "Subnetzmaske [255.255.255.0]: " NETMASK; NETMASK=${NETMASK:-255.255.255.0}
      read -p "Gateway [192.168.1.1]: " GATEWAY; GATEWAY=${GATEWAY:-192.168.1.1}
      read -p "DNS-Server [8.8.8.8]: " DNS; DNS=${DNS:-8.8.8.8}
      draw_header
      echo "--------------------------------------------------------"
      echo "  IP-Adresse:   ${STATIC_IP}"
      echo "  Subnetzmaske: ${NETMASK}"
      echo "  Gateway:      ${GATEWAY}"
      echo "  DNS:          ${DNS}"
      echo "--------------------------------------------------------"
      read -p "Sind diese Angaben korrekt? (J/n): " confirm
      [[ ! "$confirm" =~ ^[Nn]$ ]] && break
    done
  fi
fi

# -------------------------------------------------------
# 3. NetworkManager Setup (Bookworm + aktives Profil, Fix)
# -------------------------------------------------------
progress "Setze Netzwerkadresse (NetworkManager)..."
sudo apt-get install -y -qq network-manager

# Aktive Ethernet-Verbindung ermitteln
ACTIVE_CON=$(nmcli -t -f NAME,DEVICE,TYPE con show --active | awk -F: '$3=="ethernet"{print $1; exit}')
[[ -z "$ACTIVE_CON" ]] && ACTIVE_CON="Wired connection 1"

mask_to_cidr() {
  local mask=$1 bits=0
  IFS=. read -r i1 i2 i3 i4 <<< "$mask"
  for octet in $i1 $i2 $i3 $i4; do
    while [ $octet -gt 0 ]; do
      bits=$((bits + (octet & 1)))
      octet=$((octet >> 1))
    done
  done
  echo "$bits"
}
CIDR=$(mask_to_cidr "$NETMASK")

if $USE_STATIC_NET; then
  # Alte Werte sauber leeren (Bookworm-kompatibel)
  sudo nmcli con mod "$ACTIVE_CON" ipv4.addresses "" || true
  sudo nmcli con mod "$ACTIVE_CON" ipv4.gateway "" || true
  sudo nmcli con mod "$ACTIVE_CON" ipv4.dns "" || true

  # Neue Werte setzen (richtige Reihenfolge)
  sudo nmcli con mod "$ACTIVE_CON" ipv4.addresses "${STATIC_IP}/${CIDR}"
  sudo nmcli con mod "$ACTIVE_CON" ipv4.gateway "$GATEWAY"
  sudo nmcli con mod "$ACTIVE_CON" ipv4.dns "$DNS"
  sudo nmcli con mod "$ACTIVE_CON" ipv4.method manual ipv6.method ignore
else
  sudo nmcli con mod "$ACTIVE_CON" ipv4.method auto ipv6.method ignore
fi

sudo nmcli con down "$ACTIVE_CON" || true
sudo nmcli con up "$ACTIVE_CON" || true
log_info "Netzwerk gesetzt für: $ACTIVE_CON → ${STATIC_IP:-DHCP}/${CIDR:-auto}"

# -------------------------------------------------------
# 4. EDATEC-Setup
# -------------------------------------------------------
progress "EDATEC Setup..."
TMP_PATH="/tmp/eda-common"
mkdir -p "$TMP_PATH"
wget -q https://apt.edatec.cn/pubkey.gpg -O "${TMP_PATH}/edatec.gpg"
cat "${TMP_PATH}/edatec.gpg" | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/edatec-archive-stable.gpg >/dev/null
echo "deb https://apt.edatec.cn/raspbian stable main" | sudo tee /etc/apt/sources.list.d/edatec.list >/dev/null
sudo apt update -qq
sudo wget -q https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/img/splash.png -O /usr/share/plymouth/themes/pix/splash.png
cmd_file="/boot/firmware/cmdline.txt"
grep -q "net.ifnames=0" "$cmd_file" || sudo sed -i "1{s/$/ net.ifnames=0/}" "$cmd_file"
log_info "EDATEC-Repo & Splashscreen eingerichtet."

# -------------------------------------------------------
# 5. Docker-Installation
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
# 6. y-control-Dateien
# -------------------------------------------------------
progress "Lade y-control-Dateien..."
sudo mkdir -p /home/pi/docker /home/pi/y-red_Data /home/pi/ycontrol-data
sudo chown -R pi:pi /home/pi/docker /home/pi/y-red_Data /home/pi/ycontrol-data
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
# 8. X-Server / Kiosk-Modus
# -------------------------------------------------------
if [[ "$TARGET" =~ 070c$ || "$TARGET" =~ 101c$ ]]; then
  progress "Installiere X-Server & Kiosk..."
  sudo apt-get install -y -qq --no-install-recommends xserver-xorg-video-all xserver-xorg-input-all xserver-xorg-core xinit x11-xserver-utils vlc unclutter chromium
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
