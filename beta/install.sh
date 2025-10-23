#!/bin/bash
set -Eeuo pipefail

# =====================================================================
#  Y-Control Raspberry Pi Installer – v5 (Bookworm 64-bit)
#  - EDATEC BSP & Firmware (JSON-Logik wie ed-install.sh)
#  - Splash von GitHub
#  - NetworkManager (ohne Down/Up während Installation)
#  - Docker + Compose + Y-Control Dateien
#  - Kiosk-Setup (optional je Gerät)
# =====================================================================

TOTAL_STEPS=12
CURRENT_STEP=0
CURRENT_ACTION="Initialisierung"

# ----------------------------- Fehlerbehandlung -----------------------------
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

# JSON-Helfer wie im ed-install.sh (robust, via Python)
json_has_key() {
  echo "$1" | python3 - "$2" <<'PY'
import sys,json
data=json.load(sys.stdin); key=sys.argv[1]
print("True" if key in data else "False")
PY
}
json_len() {
  echo "$1" | python3 - "$2" <<'PY'
import sys,json
data=json.load(sys.stdin); key=sys.argv[1]
print(len(data[key]))
PY
}
json_get() {
  # json_get "<json>" key [idx]
  if [ $# -eq 2 ]; then
    echo "$1" | python3 - "$2" <<'PY'
import sys,json
data=json.load(sys.stdin); key=sys.argv[1]
print(data[key])
PY
  else
    echo "$1" | python3 - "$2" "$3" <<'PY'
import sys,json
data=json.load(sys.stdin); key=sys.argv[1]; idx=int(sys.argv[2])
print(data[key][idx])
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
  echo
  read -p "Standard-IP verwenden (192.168.10.31 / 255.255.255.0 / 192.168.10.1 / 1.1.1.2)? (J/n): " stdchoice
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

# ----------------------------- 4. EDATEC BSP/Firmware ------------------------
progress "EDATEC BSP & Firmware..."
BASE_URL="https://apt.edatec.cn/bsp"
TMP_PATH="/tmp/eda-common"
sudo mkdir -p "$TMP_PATH"

# Repo & Key (wie im Original)
wget -q https://apt.edatec.cn/pubkey.gpg -O "${TMP_PATH}/edatec.gpg"
cat "${TMP_PATH}/edatec.gpg" | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/edatec-archive-stable.gpg >/dev/null
echo "deb https://apt.edatec.cn/raspbian stable main" | sudo tee /etc/apt/sources.list.d/edatec.list >/dev/null
sudo apt update -qq

# cmdline: net.ifnames=0 hinzufügen (wie Original)
cmd_file="/boot/firmware/cmdline.txt"
grep -q "net.ifnames=0" "$cmd_file" || sudo sed -i '1{s/$/ net.ifnames=0/}' "$cmd_file"

# Gerätespezifisches JSON laden
DEVICE_JSON="$(curl -fsSL --connect-timeout 30 "${BASE_URL}/devices/${TARGET}.json")"
if [[ -z "$DEVICE_JSON" ]]; then
  echo "Geräte-JSON konnte nicht geladen werden: ${BASE_URL}/devices/${TARGET}.json"
  exit 2
fi

# debs installieren
if [[ "$(json_has_key "$DEVICE_JSON" "debs")" == "True" ]]; then
  DEBS="$(json_get "$DEVICE_JSON" "debs")"
  log_info "Installiere Pakete: $DEBS"
  sudo apt install -y $DEBS
fi

# cmd[] ausführen (in Reihenfolge)
if [[ "$(json_has_key "$DEVICE_JSON" "cmd")" == "True" ]]; then
  LEN="$(json_len "$DEVICE_JSON" "cmd")"
  for ((i=0;i<LEN;i++)); do
    T_CMD="$(json_get "$DEVICE_JSON" "cmd" "$i")"
    echo "[CMD] $T_CMD"
    eval "$T_CMD"
  done
fi

# Auf EEPROM-/Flash-Operationen warten (wie im Original)
echo "Warte auf eventuell laufende EEPROM/Flash-Updates..."
while pgrep -f flashrom >/dev/null; do sleep 0.5; done
while pgrep -f rpi-eeprom-update >/dev/null; do sleep 0.5; done
# ggf. auf erfolgreichen Service warten, wenn vorhanden
if systemctl list-units | grep -q rpi-eeprom-update.service; then
  while true; do
    if [ "$(systemctl show -p Result rpi-eeprom-update.service --value)" = "success" ]; then break; fi
    sleep 0.5
  done
fi
log_info "EDATEC BSP/Firmware erfolgreich installiert."

# ----------------------------- 5. Splash von GitHub --------------------------
progress "Installiere Splashscreen (GitHub)..."
sudo apt -y install rpd-plym-splash plymouth-themes || true
sudo raspi-config nonint do_boot_splash 0 || true
sudo raspi-config nonint do_boot_behaviour B2 || true
sudo mkdir -p /usr/share/plymouth/themes/pix
sudo wget -q https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/img/splash.png -O /usr/share/plymouth/themes/pix/splash.png

KERNEL_VER="$(uname -r)"
sudo update-initramfs -c -k "$KERNEL_VER"
if [ -d /boot/firmware ]; then
  if [ -f "/boot/initrd.img-${KERNEL_VER}" ]; then
    sudo cp "/boot/initrd.img-${KERNEL_VER}" /boot/firmware/ 2>/dev/null || true
    sudo mv "/boot/firmware/initrd.img-${KERNEL_VER}" /boot/firmware/initramfs_2712 2>/dev/null || true
  fi
fi
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

# ----------------------------- 7. Verzeichnisse/Dateien ----------------------
progress "Lege Verzeichnisse & Y-Control Dateien an..."
sudo mkdir -p /home/pi/docker /home/pi/y-red_Data /home/pi/ycontrol-data
sudo chown -R pi:pi /home/pi/docker /home/pi/y-red_Data /home/pi/ycontrol-data
sudo -u pi mkdir -p /home/pi/ycontrol-data/assets /home/pi/ycontrol-data/external

# vis/assets + vis/external aus GitHub (nur die Ordner)
sudo -u pi curl -fsSL https://github.com/ikulx/ycontrol-sh/archive/refs/heads/main.tar.gz \
  | sudo -u pi tar -xz --strip-components=2 -C /home/pi/ycontrol-data ycontrol-sh-main/vis/assets
sudo -u pi curl -fsSL https://github.com/ikulx/ycontrol-sh/archive/refs/heads/main.tar.gz \
  | sudo -u pi tar -xz --strip-components=2 -C /home/pi/ycontrol-data ycontrol-sh-main/vis/external

# docker-compose.yml in /home/pi/docker
sudo -u pi curl -fsSL -o /home/pi/docker/docker-compose.yml \
  https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/docker/dis/docker-compose.yml
log_info "Dateien bereitgestellt."

# ----------------------------- 8. Docker Compose -----------------------------
progress "Starte Docker Compose..."
cd /home/pi/docker
if groups pi | grep -q docker; then
  sudo -u pi docker compose pull
  sudo -u pi docker compose up -d
else
  log_info "Benutzer pi noch nicht in Docker-Gruppe aktiv – verwende root..."
  sudo docker compose pull
  sudo docker compose up -d
fi
log_info "Container gestartet."

# ----------------------------- 9. Kiosk / X-Server ---------------------------
if [[ "$TARGET" =~ 070c$ || "$TARGET" =~ 101c$ ]]; then
  progress "Installiere X-Server & Kiosk..."
  sudo apt-get install -y -qq --no-install-recommends \
    xserver-xorg-video-all xserver-xorg-input-all xserver-xorg-core xinit x11-xserver-utils vlc unclutter chromium
  sudo -u pi curl -fsSL -o /home/pi/.bash_profile https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/kiosk/.bash_profile
  if [[ "$TARGET" =~ 070c$ ]]; then
    sudo -u pi curl -fsSL -o /home/pi/.xinitrc https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/kiosk/7z/.xinitrc
  else
    sudo -u pi curl -fsSL -o /home/pi/.xinitrc https://raw.githubusercontent.com/ikulx/ycontrol-sh/main/kiosk/10z/.xinitrc
    # Touchscreen-Matrix für 10" setzen
    if [ -f /usr/share/X11/xorg.conf.d/40-libinput.conf ]; then
      sudo sed -i '/MatchIsTouchscreen "on"/a \ \ Option "CalibrationMatrix" "0 -1 1 1 0 0 0 0 0 1"' /usr/share/X11/xorg.conf.d/40-libinput.conf
    fi
  fi
  sudo chown pi:pi /home/pi/.bash_profile /home/pi/.xinitrc
  log_info "Kioskmodus eingerichtet."
fi

# ----------------------------- 10. Abschluss --------------------------------
progress "Abschluss..."
log_info "Alle Installationen abgeschlossen. Neue Netzwerkeinstellungen aktiv nach Neustart."

# ----------------------------- 11. Reboot -----------------------------------
progress "Starte System neu..."
sleep 3
sudo reboot
