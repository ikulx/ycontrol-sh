#!/bin/bash
set -Eeuo pipefail

# =====================================================================
#  Y-Control Raspberry Pi Installer – v6 (Bookworm 64-bit)
# =====================================================================
TOTAL_STEPS=13
CURRENT_STEP=0
CURRENT_ACTION="Initialisierung"

# ----------------------------- Fehlerbehandlung -----------------------------
error_handler() {
  local exit_code=$?
  local line_no=$1
  echo -e "\n\033[31m--------------------------------------------------------\033[0m"
  echo -e "\033[31m[FEHLER]\\033[0m in Zeile ${line_no} bei Schritt: '${CURRENT_ACTION}'"
  echo -e "\033[31mDas Script wurde mit Fehlercode ${exit_code} abgebrochen.\033[0m"
  echo -e "\033[31m--------------------------------------------------------\033[0m"
  exit $exit_code
}
trap 'error_handler $LINENO' ERR

# ----------------------------- Anzeige/UI -----------------------------------
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
log_info() { echo -e "\033[32m[OK]\033[0m $1"; }

# ----------------------------- Hilfsfunktionen -------------------------------
mask_to_cidr() {
  local mask=$1 bits=0
  IFS=. read -r i1 i2 i3 i4 <<< "$mask"
  for o in $i1 $i2 $i3 $i4; do
    while [ "$o" -gt 0 ]; do bits=$((bits + (o & 1))); o=$((o >> 1)); done
  done
  echo "$bits"
}

json_has_key() {
  echo "$1" | python3 - "$2" <<'PY'
import sys,json;d=json.load(sys.stdin);print("True" if sys.argv[1] in d else "False")
PY
}
json_len() {
  echo "$1" | python3 - "$2" <<'PY'
import sys,json;d=json.load(sys.stdin);print(len(d[sys.argv[1]]))
PY
}
json_get() {
  if [ $# -eq 2 ]; then
    echo "$1" | python3 - "$2" <<'PY'
import sys,json;d=json.load(sys.stdin);print(d[sys.argv[1]])
PY
  else
    echo "$1" | python3 - "$2" "$3" <<'PY'
import sys,json;d=json.load(sys.stdin);print(d[sys.argv[1]][int(sys.argv[2])])
PY
  fi
}

# ----------------------------- 1. Gerätauswahl -------------------------------
progress "Starte Installation..."
DEVICES=("hmi3010_070c" "hmi3010_101c" "hmi3120_070c" "hmi3120_101c" "hmi3120_116c" "ipc3630")
progress "Gerät auswählen..."
select TARGET in "${DEVICES[@]}"; do
  [[ -n "$TARGET" ]] && break || echo "Ungültige Auswahl."
done
echo "Gerät ausgewählt: $TARGET"
sleep 1

# ----------------------------- 2. Netzwerkkonfiguration ----------------------
progress "Netzwerkkonfiguration..."
USE_STATIC_NET=false
read -p "Willst du eine statische IP-Adresse konfigurieren? (j/N): " netchoice
if [[ "$netchoice" =~ ^[JjYy]$ ]]; then
  USE_STATIC_NET=true
  read -p "Standard-IP verwenden (192.168.10.31 / 255.255.255.0 / 192.168.10.1 / 1.1.1.2)? (J/n): " stdchoice
  if [[ ! "$stdchoice" =~ ^[Nn]$ ]]; then
    STATIC_IP="192.168.10.31"; NETMASK="255.255.255.0"; GATEWAY="192.168.10.1"; DNS="1.1.1.2"
  else
    read -p "IP-Adresse: " STATIC_IP
    read -p "Subnetzmaske: " NETMASK
    read -p "Gateway: " GATEWAY
    read -p "DNS: " DNS
  fi
fi

# ----------------------------- 3. NetworkManager -----------------------------
progress "Setze Netzwerkadresse (NetworkManager)..."
sudo apt-get install -y -qq network-manager
if ! nmcli -t -f NAME con show | grep -q '^eth0$'; then
  sudo nmcli con add type ethernet ifname eth0 con-name eth0
fi
if $USE_STATIC_NET; then
  CIDR=$(mask_to_cidr "$NETMASK")
  sudo nmcli con mod eth0 ipv4.method manual ipv4.addresses "${STATIC_IP}/${CIDR}" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" ipv6.method ignore
else
  sudo nmcli con mod eth0 ipv4.method auto ipv6.method ignore
fi
log_info "Netzwerk­konfiguration gespeichert (aktiv nach Reboot)."

# ----------------------------- 4. EDATEC Firmware ----------------------------
progress "EDATEC BSP & Firmware (Debug-Modus)..."
BASE_URL="https://apt.edatec.cn/bsp"
TMP_PATH="/tmp/eda-common"
sudo mkdir -p "$TMP_PATH"

wget -q https://apt.edatec.cn/pubkey.gpg -O "${TMP_PATH}/edatec.gpg"
cat "${TMP_PATH}/edatec.gpg" | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/edatec-archive-stable.gpg >/dev/null
echo "deb https://apt.edatec.cn/raspbian stable main" | sudo tee /etc/apt/sources.list.d/edatec.list >/dev/null
sudo apt update -qq

DEVICE_JSON="$(curl -fsSL --connect-timeout 30 "${BASE_URL}/devices/${TARGET}.json")"
if [[ -z "$DEVICE_JSON" ]]; then
  echo "Geräte-JSON konnte nicht geladen werden! (${BASE_URL}/devices/${TARGET}.json)"
  exit 2
fi

if [[ "$(json_has_key "$DEVICE_JSON" "debs")" == "True" ]]; then
  DEBS="$(json_get "$DEVICE_JSON" "debs")"
  log_info "Installiere Pakete: $DEBS"
  sudo apt install -y $DEBS
fi

# Debug: Logge alle CMDs in /tmp/eda-debug.log
if [[ "$(json_has_key "$DEVICE_JSON" "cmd")" == "True" ]]; then
  LEN="$(json_len "$DEVICE_JSON" "cmd")"
  echo "Starte ${LEN} Gerätekonfigurationsbefehle ..." | tee /tmp/eda-debug.log
  for ((i=0;i<LEN;i++)); do
    T_CMD="$(json_get "$DEVICE_JSON" "cmd" "$i")"
    echo -e "\033[33m[CMD $((i+1))/$LEN]\033[0m $T_CMD" | tee -a /tmp/eda-debug.log
    bash -x -c "$T_CMD" 2>&1 | tee -a /tmp/eda-debug.log
    RC=${PIPESTATUS[0]}
    if [ "$RC" -ne 0 ]; then
      echo -e "\033[31m[FEHLER]\033[0m Befehl fehlgeschlagen: $T_CMD" | tee -a /tmp/eda-debug.log
      exit 99
    fi
  done
fi

# Warte auf EEPROM/Flash-Prozesse
while pgrep -f flashrom >/dev/null; do sleep 0.5; done
while pgrep -f rpi-eeprom-update >/dev/null; do sleep 0.5; done
log_info "EDATEC Firmwareinstallation abgeschlossen. Logs unter /tmp/eda-debug.log"

# ----------------------------- 5. Splash von GitHub --------------------------
progress "Installiere Splashscreen (GitHub)..."
sudo apt -y install rpd-plym-splash plymouth-themes || true
sudo raspi-config nonint do_boot_splash 0 || true
sudo raspi-config nonint do_boot_behaviour B2 || true
sudo mkdir -p /usr/share/plymouth/themes/pix
sudo wget -q https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/img/splash.png -O /usr/share/plymouth/themes/pix/splash.png
sudo update-initramfs -u
sudo plymouth-set-default-theme --rebuild-initrd pix || true
log_info "Splashscreen eingerichtet."

# ----------------------------- 6. Docker installieren ------------------------
progress "Installiere Docker..."
sudo apt-get remove -y -qq docker.io docker-doc docker-compose podman-docker containerd runc || true
sudo apt-get install -y -qq ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker pi
log_info "Docker installiert."

# ----------------------------- 7b. Docker Login -----------------------------
progress "Docker Login..."
if [ -f /home/pi/docker.txt ]; then
  DOCKER_USER=$(head -n1 /home/pi/docker.txt | tr -d '\r')
  DOCKER_TOKEN=$(sed -n '2p' /home/pi/docker.txt | tr -d '\r')
  if [ -n "$DOCKER_USER" ] && [ -n "$DOCKER_TOKEN" ]; then
    echo "$DOCKER_TOKEN" | sudo -u pi docker login -u "$DOCKER_USER" --password-stdin
    log_info "Docker Login erfolgreich für '$DOCKER_USER'."
    sudo rm -f /home/pi/docker.txt
  else
    echo -e "\033[33mWarnung:\033[0m /home/pi/docker.txt unvollständig."
  fi
else
  echo -e "\033[33mHinweis:\033[0m Keine /home/pi/docker.txt gefunden – Login übersprungen."
fi

# ----------------------------- 8. Y-Control Dateien --------------------------
progress "Lade Y-Control Dateien..."
sudo mkdir -p /home/pi/docker /home/pi/y-red_Data /home/pi/ycontrol-data
sudo chown -R pi:pi /home/pi
sudo -u pi curl -fsSL -o /home/pi/docker/docker-compose.yml \
  https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/docker/dis/docker-compose.yml
sudo -u pi curl -fsSL https://github.com/ikulx/ycontrol-sh/archive/refs/heads/main.tar.gz \
  | sudo -u pi tar -xz --strip-components=2 -C /home/pi/ycontrol-data ycontrol-sh-main/vis/assets
sudo -u pi curl -fsSL https://github.com/ikulx/ycontrol-sh/archive/refs/heads/main.tar.gz \
  | sudo -u pi tar -xz --strip-components=2 -C /home/pi/ycontrol-data ycontrol-sh-main/vis/external
log_info "Dateien geladen."

# ----------------------------- 9. Docker Compose -----------------------------
progress "Starte Docker Compose..."
cd /home/pi/docker
sudo -u pi docker compose pull
sudo -u pi docker compose up -d
log_info "Container gestartet."

# ----------------------------- 10. Kiosk ------------------------------------
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

# ----------------------------- 11. Abschluss --------------------------------
progress "Abschluss..."
log_info "Installation abgeschlossen. Reboot in 5 Sekunden..."
sleep 5
sudo reboot
