module("luci.controller.linxdot.lora", package.seeall)

function index()
	entry({"admin", "services", "lora"}, firstchild(), _("LoRa Packet Forwarder"), 60).acl_depends = { "luci-app-linxdot-lora" }
	entry({"admin", "services", "lora", "status"}, template("linxdot/lora"), _("Status"), 1)
	entry({"admin", "services", "lora", "api", "status"}, call("action_status")).leaf = true
	entry({"admin", "services", "lora", "api", "restart"}, call("action_restart")).leaf = true
	entry({"admin", "services", "lora", "api", "stop"}, call("action_stop")).leaf = true
	entry({"admin", "services", "lora", "api", "set_region"}, call("action_set_region")).leaf = true
	entry({"admin", "services", "lora", "api", "set_server"}, call("action_set_server")).leaf = true
	entry({"admin", "services", "lora", "api", "set_port"}, call("action_set_port")).leaf = true
	entry({"admin", "services", "lora", "api", "set_coords"}, call("action_set_coords")).leaf = true
	entry({"admin", "services", "lora", "api", "set_tx_power"}, call("action_set_tx_power")).leaf = true
	entry({"admin", "services", "lora", "api", "set_tx_lut"}, call("action_set_tx_lut")).leaf = true
	entry({"admin", "services", "lora", "api", "logs"}, call("action_logs")).leaf = true
end

local function read_file(path, max_bytes)
	local fs = require "nixio.fs"
	if not fs.access(path) then return "" end
	if max_bytes then
		local pipe = io.popen("tail -c " .. max_bytes .. " " .. path .. " 2>/dev/null")
		if pipe then
			local out = pipe:read("*a") or ""
			pipe:close()
			return out
		end
	end
	return fs.readfile(path) or ""
end

local function run_cmd(cmd)
	local pipe = io.popen(cmd .. " 2>&1")
	if pipe then
		local out = pipe:read("*a") or ""
		pipe:close()
		return out:gsub("^%s+", ""):gsub("%s+$", "")
	end
	return ""
end

local function parse_json(path)
	local content = read_file(path)
	if content == "" then return nil end
	local jsonc = require "luci.jsonc"
	local ok, data = pcall(jsonc.parse, content)
	if ok then return data end
	return nil
end

local function write_json(path, data)
	local jsonc = require "luci.jsonc"
	local f = io.open(path, "w")
	if not f then return false end
	f:write(jsonc.stringify(data, true))
	f:close()
	return true
end

local function get_current_region()
	local line = run_cmd("grep '^thisRegion=' /etc/init.d/linxdot-lora-pkt-fwd | sed 's/.*=//' | tr -d '\"'")
	if line ~= "" then return line end
	return "EU868"
end

local function list_regions()
	local regions = {}
	local pipe = io.popen("ls /etc/lora/global_conf.json.sx1250.* 2>/dev/null")
	if pipe then
		for line in pipe:lines() do
			local r = line:match("global_conf%.json%.sx1250%.([%w_%-]+)$")
			if r then table.insert(regions, r) end
		end
		pipe:close()
	end
	if #regions == 0 then regions = {"EU868", "RU864"} end
	table.sort(regions)
	return regions
end

local function get_config_path(region)
	return "/etc/lora/global_conf.json.sx1250." .. region
end

local function read_thermal_temp()
	local fs = require "nixio.fs"
	local temp_paths = {
		"/sys/class/thermal/thermal_zone0/temp",
		"/sys/class/thermal/thermal_zone1/temp"
	}
	local max_temp = nil
	for _, p in ipairs(temp_paths) do
		if fs.access(p) then
			local f = io.open(p, "r")
			if f then
				local val = f:read("*l")
				f:close()
				local t = tonumber(val)
				if t then
					if t > 1000 then t = t / 1000 end
					if not max_temp or t > max_temp then
						max_temp = t
					end
				end
			end
		end
	end
	return max_temp
end

function action_status()
	local status = {}

	status.running = (run_cmd("pidof lora_pkt_fwd") ~= "")
	status.region = get_current_region()
	status.regions = list_regions()

	local cfg = parse_json(get_config_path(status.region))
	if cfg and cfg.gateway_conf then
		local gc = cfg.gateway_conf
		status.gateway_id = gc.gateway_ID or "unknown"
		status.server_address = gc.server_address or "unknown"
		status.server_port_up = gc.serv_port_up or 0
		status.server_port_down = gc.serv_port_down or 0
		status.ref_latitude = gc.ref_latitude or 0
		status.ref_longitude = gc.ref_longitude or 0
		status.ref_altitude = gc.ref_altitude or 0
		status.fake_gps = gc.fake_gps or false
	else
		status.gateway_id = "unknown"
		status.server_address = "unknown"
		status.server_port_up = 0
		status.server_port_down = 0
		status.ref_latitude = 0
		status.ref_longitude = 0
		status.ref_altitude = 0
		status.fake_gps = false
	end

	local max_tx = 0
	if cfg and cfg.SX130x_conf and cfg.SX130x_conf.radio_0 and cfg.SX130x_conf.radio_0.tx_gain_lut then
		status.tx_gain_lut = cfg.SX130x_conf.radio_0.tx_gain_lut
		for _, entry in ipairs(cfg.SX130x_conf.radio_0.tx_gain_lut) do
			if entry.rf_power and entry.rf_power > max_tx then
				max_tx = entry.rf_power
			end
		end
	else
		status.tx_gain_lut = {}
	end
	status.max_tx_power = max_tx

	local log = read_file("/var/log/lora_pkt_fwd.log", 32768)
	status.log_snippet = log

	local chip = log:match("chip version is 0x([0-9a-fA-F]+)")
	status.chip_version = chip and ("0x" .. chip) or "unknown"

	local temp = read_thermal_temp()
	if not temp then
		temp = log:match("Concentrator temperature:%s+([%d%.]+)")
		temp = temp and tonumber(temp) or 0
	end
	status.temperature = temp

	local last_report = log:match("#####[%s%S]-##### END #####")
	if last_report then
		local rxnb = last_report:match("RF packets received by concentrator:%s+(%d+)")
		local rxok = last_report:match("CRC_OK:%s+([%d%.]+)")
		local rxfw = last_report:match("RF packets forwarded:%s+(%d+)")
		local push_ack = last_report:match("PUSH_DATA acknowledged:%s+([%d%.]+)")
		status.rx_packets_total = rxnb and tonumber(rxnb) or 0
		status.crc_ok_percent = rxok and tonumber(rxok) or 0
		status.rx_forwarded = rxfw and tonumber(rxfw) or 0
		status.push_ack_percent = push_ack and tonumber(push_ack) or 0

		local txnb = last_report:match("RF packets sent to concentrator:%s+(%d+)")
		status.tx_packets = txnb and tonumber(txnb) or 0
	else
		status.rx_packets_total = 0
		status.crc_ok_percent = 0
		status.rx_forwarded = 0
		status.push_ack_percent = 0
		status.tx_packets = 0
	end

	local uptime = run_cmd("cat /proc/uptime | awk '{print $1}'")
	status.uptime_seconds = tonumber(uptime) or 0

	status.ip_address = run_cmd("ip addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1")
	if status.ip_address == "" then
		status.ip_address = run_cmd("ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1")
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json(status)
end

function action_restart()
	os.execute("/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = true })
end

function action_stop()
	os.execute("/etc/init.d/linxdot-lora-pkt-fwd stop >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = true })
end

function action_set_region()
	local region = luci.http.formvalue("region")
	if not region or region == "" then
		luci.http.status(400, "Bad Request")
		return
	end
	region = region:gsub("[^%w_-]", "")
	if region == "" then
		luci.http.status(400, "Bad Request")
		return
	end

	local cfg_path = get_config_path(region)
	local fs = require "nixio.fs"
	if not fs.access(cfg_path) then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "Region config not found" })
		return
	end

	local old_region = get_current_region()
	local old_cfg = parse_json(get_config_path(old_region))
	local new_cfg = parse_json(cfg_path)
	if old_cfg and old_cfg.gateway_conf and new_cfg and new_cfg.gateway_conf then
		if old_cfg.gateway_conf.server_address then
			new_cfg.gateway_conf.server_address = old_cfg.gateway_conf.server_address
		end
		if old_cfg.gateway_conf.serv_port_up then
			new_cfg.gateway_conf.serv_port_up = old_cfg.gateway_conf.serv_port_up
		end
		if old_cfg.gateway_conf.serv_port_down then
			new_cfg.gateway_conf.serv_port_down = old_cfg.gateway_conf.serv_port_down
		end
		if old_cfg.gateway_conf.ref_latitude ~= nil then
			new_cfg.gateway_conf.ref_latitude = old_cfg.gateway_conf.ref_latitude
		end
		if old_cfg.gateway_conf.ref_longitude ~= nil then
			new_cfg.gateway_conf.ref_longitude = old_cfg.gateway_conf.ref_longitude
		end
		if old_cfg.gateway_conf.ref_altitude ~= nil then
			new_cfg.gateway_conf.ref_altitude = old_cfg.gateway_conf.ref_altitude
		end
		if old_cfg.gateway_conf.fake_gps ~= nil then
			new_cfg.gateway_conf.fake_gps = old_cfg.gateway_conf.fake_gps
		end
		write_json(cfg_path, new_cfg)
	end
	if old_cfg and old_cfg.SX130x_conf and old_cfg.SX130x_conf.radio_0 and old_cfg.SX130x_conf.radio_0.tx_gain_lut then
		if new_cfg and new_cfg.SX130x_conf and new_cfg.SX130x_conf.radio_0 then
			new_cfg.SX130x_conf.radio_0.tx_gain_lut = old_cfg.SX130x_conf.radio_0.tx_gain_lut
			write_json(cfg_path, new_cfg)
		end
	end

	local safe_region = region:gsub("'", "'\\''")
	os.execute("sed -i \"s/^thisRegion=.*/thisRegion=" .. safe_region .. "/\" /etc/init.d/linxdot-lora-pkt-fwd")

	local settings_path = "/etc/linxdot-opensource/web/settings.json"
	local cfg = parse_json(settings_path)
	if cfg then
		cfg.lora_config_file = "global_conf.json.sx1250." .. region
		write_json(settings_path, cfg)
	end

	os.execute("/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = true })
end

function action_set_server()
	local server = luci.http.formvalue("server")
	if not server or server == "" then
		luci.http.status(400, "Bad Request")
		return
	end
	server = server:gsub("%s+", "")
	if server:match("[;|&`$]") then
		luci.http.status(400, "Bad Request")
		return
	end

	local updated = false
	for _, r in ipairs(list_regions()) do
		local cfg = parse_json(get_config_path(r))
		if cfg and cfg.gateway_conf then
			cfg.gateway_conf.server_address = server
			if write_json(get_config_path(r), cfg) then updated = true end
		end
	end

	os.execute("/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = updated })
end

function action_set_port()
	local port = luci.http.formvalue("port")
	if not port or port == "" then
		luci.http.status(400, "Bad Request")
		return
	end
	local port_num = tonumber(port)
	if not port_num or port_num < 1 or port_num > 65535 then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "Invalid port" })
		return
	end

	local updated = false
	for _, r in ipairs(list_regions()) do
		local cfg = parse_json(get_config_path(r))
		if cfg and cfg.gateway_conf then
			cfg.gateway_conf.serv_port_up = port_num
			cfg.gateway_conf.serv_port_down = port_num
			if write_json(get_config_path(r), cfg) then updated = true end
		end
	end

	os.execute("/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = updated })
end

function action_set_coords()
	local lat = luci.http.formvalue("lat")
	local lon = luci.http.formvalue("lon")
	local alt = luci.http.formvalue("alt")

	if lat == nil or lat == "" or lon == nil or lon == "" then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "Latitude and longitude required" })
		return
	end

	local lat_num = tonumber(lat)
	local lon_num = tonumber(lon)
	local alt_num = tonumber(alt) or 0

	if lat_num == nil or lon_num == nil then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "Invalid coordinates" })
		return
	end

	if lat_num < -90 or lat_num > 90 or lon_num < -180 or lon_num > 180 then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "Coordinates out of range" })
		return
	end

	local updated = false
	for _, r in ipairs(list_regions()) do
		local cfg = parse_json(get_config_path(r))
		if cfg and cfg.gateway_conf then
			cfg.gateway_conf.ref_latitude = lat_num
			cfg.gateway_conf.ref_longitude = lon_num
			cfg.gateway_conf.ref_altitude = alt_num
			cfg.gateway_conf.fake_gps = true
			if write_json(get_config_path(r), cfg) then updated = true end
		end
	end

	os.execute("/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = updated })
end

function action_set_tx_power()
	local max_pwr = luci.http.formvalue("max_power")
	if not max_pwr or max_pwr == "" then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "max_power required" })
		return
	end
	local p = tonumber(max_pwr)
	if not p or p < 0 or p > 27 then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "Invalid max_power (0-27)" })
		return
	end

	local backup_path = "/etc/linxdot-opensource/tx_gain_lut_backup.json"
	local backup = parse_json(backup_path)
	if not backup then
		backup = {}
		for _, r in ipairs(list_regions()) do
			local cfg = parse_json(get_config_path(r))
			if cfg and cfg.SX130x_conf and cfg.SX130x_conf.radio_0 and cfg.SX130x_conf.radio_0.tx_gain_lut then
				backup[r] = cfg.SX130x_conf.radio_0.tx_gain_lut
			end
		end
		write_json(backup_path, backup)
	end

	local updated = false
	for _, r in ipairs(list_regions()) do
		local cfg = parse_json(get_config_path(r))
		if cfg and cfg.SX130x_conf and cfg.SX130x_conf.radio_0 then
			local lut = backup[r] or cfg.SX130x_conf.radio_0.tx_gain_lut or {}
			local new_lut = {}
			for _, entry in ipairs(lut) do
				if entry.rf_power and entry.rf_power <= p then
					table.insert(new_lut, entry)
				end
			end
			cfg.SX130x_conf.radio_0.tx_gain_lut = new_lut
			if write_json(get_config_path(r), cfg) then updated = true end
		end
	end

	os.execute("/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = updated })
end

function action_set_tx_lut()
	local lut_json = luci.http.formvalue("lut")
	if not lut_json or lut_json == "" then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "lut required" })
		return
	end

	local jsonc = require "luci.jsonc"
	local ok, lut = pcall(jsonc.parse, lut_json)
	if not ok or type(lut) ~= "table" then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({ result = false, error = "Invalid LUT JSON" })
		return
	end

	for i, entry in ipairs(lut) do
		if type(entry) ~= "table" then
			luci.http.status(400, "Bad Request")
			luci.http.write_json({ result = false, error = "LUT entry " .. i .. " is not an object" })
			return
		end
		local rp = tonumber(entry.rf_power)
		local pg = tonumber(entry.pa_gain)
		local pi = tonumber(entry.pwr_idx)
		if not rp or rp < 0 or rp > 27 then
			luci.http.status(400, "Bad Request")
			luci.http.write_json({ result = false, error = "LUT entry " .. i .. ": rf_power must be 0-27" })
			return
		end
		if not pg or (pg ~= 0 and pg ~= 1) then
			luci.http.status(400, "Bad Request")
			luci.http.write_json({ result = false, error = "LUT entry " .. i .. ": pa_gain must be 0 or 1" })
			return
		end
		if not pi or pi < 0 or pi > 22 then
			luci.http.status(400, "Bad Request")
			luci.http.write_json({ result = false, error = "LUT entry " .. i .. ": pwr_idx must be 0-22" })
			return
		end
		entry.rf_power = rp
		entry.pa_gain = pg
		entry.pwr_idx = pi
	end

	-- sort by rf_power ascending
	table.sort(lut, function(a, b) return a.rf_power < b.rf_power end)

	local updated = false
	for _, r in ipairs(list_regions()) do
		local cfg = parse_json(get_config_path(r))
		if cfg and cfg.SX130x_conf and cfg.SX130x_conf.radio_0 then
			cfg.SX130x_conf.radio_0.tx_gain_lut = lut
			if write_json(get_config_path(r), cfg) then updated = true end
		end
	end

	-- update backup so set_tx_power continues to work with the new table
	local backup_path = "/etc/linxdot-opensource/tx_gain_lut_backup.json"
	local backup = {}
	for _, r in ipairs(list_regions()) do
		backup[r] = lut
	end
	write_json(backup_path, backup)

	os.execute("/etc/init.d/linxdot-lora-pkt-fwd restart >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ result = updated })
end

function action_logs()
	local lines = luci.http.formvalue("lines") or "50"
	local n = tonumber(lines) or 50
	if n > 500 then n = 500 end
	if n < 1 then n = 1 end

	local log = run_cmd("tail -n " .. n .. " /var/log/lora_pkt_fwd.log 2>/dev/null")
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(log)
end
