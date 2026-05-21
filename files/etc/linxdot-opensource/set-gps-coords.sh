#!/bin/sh
# Linxdot manual GPS coordinates setter
# Usage: set-gps-coords.sh <latitude> <longitude> [altitude]
# Example: set-gps-coords.sh 55.7558 37.6173 150

LAT="$1"
LON="$2"
ALT="${3:-0}"

if [ -z "$LAT" ] || [ -z "$LON" ]; then
    echo "Usage: $0 <latitude> <longitude> [altitude]"
    echo "Example: $0 55.7558 37.6173 150"
    exit 1
fi

if ! echo "$LAT" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then
    echo "Invalid latitude: $LAT"
    exit 1
fi

if ! echo "$LON" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then
    echo "Invalid longitude: $LON"
    exit 1
fi

if ! echo "$ALT" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then
    echo "Invalid altitude: $ALT"
    exit 1
fi

for f in /etc/lora/global_conf.json.sx1250.*; do
    if [ -f "$f" ]; then
        jq ".gateway_conf.ref_latitude = ($LAT | tonumber) | .gateway_conf.ref_longitude = ($LON | tonumber) | .gateway_conf.ref_altitude = ($ALT | tonumber) | .gateway_conf.fake_gps = true" "$f" > /tmp/gps_tmp.json && mv /tmp/gps_tmp.json "$f"
        echo "Updated $f"
    fi
done

/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1
echo "LoRa Packet Forwarder restarted."
