#!/usr/bin/env sh

/home/pi/wg_mqtt_listener.sh &


xset s on
xset s blank
xset s 1800  # Bildschirmschoner aktiviert sich nach 10 Minuten




# Start video in fullscreen loop mode
cvlc --fullscreen --loop --no-osd --no-mouse-events --no-audio /home/pi/ygnis_loading_black.mp4 &
pid=$!
sleep 5

# Loop for checking if the webpage is accessible
while :
do
    # Check if the webpage is accessible using curl
    if curl -s --head --request GET http://127.0.0.1:80 | grep -q "200 OK"; then
        sleep 20  # Wait 20 seconds after detecting the webpage is accessible
        unclutter -idle 0.01 &
	

	chromium-browser http://127.0.0.1:80 \
        --kiosk \
        --noerrdialogs \
        --no-first-run \
        --fast \
        --fast-start \
        --disable-infobars \
        --touch-events \
	      --lang=de-CH \
        --force-dark-mode \
        --overscroll-history-navigation=0 &
        kill $pid
        break  # Exit the loop if the webpage is accessible
    else
        echo "Die Webseite ist nicht erreichbar. Warte 10 Sekunden und versuche erneut."
        sleep 10  # Wait 10 seconds before trying again
    fi

done

# Wait for the Chromium process to end and then exit the script
wait
