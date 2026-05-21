#!/bin/sh
# Linxdot TX Power setter
# Usage: set-tx-power.sh <max_power_dBm>
# Example: set-tx-power.sh 14

MAX_PWR="$1"

if [ -z "$MAX_PWR" ]; then
    echo "Usage: $0 <max_power_dBm (0-27)>"
    exit 1
fi

if ! echo "$MAX_PWR" | grep -Eq '^[0-9]+$'; then
    echo "Invalid power: $MAX_PWR"
    exit 1
fi

if [ "$MAX_PWR" -lt 0 ] || [ "$MAX_PWR" -gt 27 ]; then
    echo "Power must be between 0 and 27 dBm"
    exit 1
fi

BACKUP="/etc/linxdot-opensource/tx_gain_lut_backup.json"
if [ ! -f "$BACKUP" ]; then
    echo "Creating backup..."
    python3 -c "
import json, glob
backup = {}
for f in glob.glob('/etc/lora/global_conf.json.sx1250.*'):
    with open(f) as fp:
        cfg = json.load(fp)
    region = f.split('.')[-1]
    backup[region] = cfg['SX130x_conf']['radio_0']['tx_gain_lut']
with open('$BACKUP', 'w') as fp:
    json.dump(backup, fp, indent=2)
" 2>/dev/null || jq -n '{}' > "$BACKUP"
fi

for f in /etc/lora/global_conf.json.sx1250.*; do
    if [ -f "$f" ]; then
        jq --argjson max "$MAX_PWR" '
            if .SX130x_conf.radio_0.tx_gain_lut then
                .SX130x_conf.radio_0.tx_gain_lut = [
                    .SX130x_conf.radio_0.tx_gain_lut[] | select(.rf_power <= $max)
                ]
            else
                .
            end
        ' "$f" > /tmp/tx_tmp.json && mv /tmp/tx_tmp.json "$f"
        echo "Updated $f"
    fi
done

/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1
echo "LoRa Packet Forwarder restarted with max TX power ${MAX_PWR} dBm."
