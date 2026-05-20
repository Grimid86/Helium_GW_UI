# Helium GW UI

Improved LuCI UI for Linxdot LM-1001 LoRa Gateway (OpenWrt-based, RK3566).

## Changes

### LoRa Packet Forwarder Page (`lora.lua` + `lora.htm`)
- Fixed multiline log parsing — RX/TX/ACK statistics now work correctly
- Added command injection protection for region/server/port inputs
- Dynamic region list from filesystem (`global_conf.json.sx1250.*`)
- Settings sync between regions when switching
- Pre-filled input fields with current values
- Start / Stop / Restart buttons with smart visibility
- Auto-scroll logs (stays at bottom if already there)
- Improved uptime formatting (Xd Xh Xm Xs)

### Dashboard Widget (`70_lora.js`)
- Added LoRa status card to Status → Overview
- Live stats: running state, region, gateway ID, server, temperature, RX/TX packets, ACK rate
- Quick link to LoRa settings page

## Installation

Copy files to the gateway preserving directory structure:

```bash
scp files/usr/lib/lua/luci/controller/linxdot/lora.lua root@gw:/usr/lib/lua/luci/controller/linxdot/
scp files/usr/lib/lua/luci/view/linxdot/lora.htm root@gw:/usr/lib/lua/luci/view/linxdot/
scp www/luci-static/resources/view/status/include/70_lora.js root@gw:/www/luci-static/resources/view/status/include/
```

Then restart nginx/uhttpd and clear LuCI cache:
```bash
rm -rf /tmp/luci-* /var/luci-*
/etc/init.d/nginx restart
```

## License

Apache 2.0 (same as upstream Linxdot code)
