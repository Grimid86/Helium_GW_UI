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
	else
		status.gateway_id = "unknown"
		status.server_address = "unknown"
		status.server_port_up = 0
		status.server_port_down = 0
	end

	local log = read_file("/var/log/lora_pkt_fwd.log", 32768)
	status.log_snippet = log

	local chip = log:match("chip version is 0x([0-9a-fA-F]+)")
	status.chip_version = chip and ("0x" .. chip) or "unknown"

	local temp = log:match("Concentrator temperature:%s+([%d%.]+)")
	status.temperature = temp and tonumber(temp) or 0

	-- Parse last report block (multiline safe)
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
	-- Sanitize: only alphanumeric, underscore, hyphen
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

	-- Sync settings from old region to new region
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
		write_json(cfg_path, new_cfg)
	end

	-- Update init script
	local safe_region = region:gsub("'", "'\\''")
	os.execute("sed -i \"s/^thisRegion=.*/thisRegion=" .. safe_region .. "/\" /etc/init.d/linxdot-lora-pkt-fwd")

	-- Update settings.json
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

function action_logs()
	local lines = luci.http.formvalue("lines") or "50"
	local n = tonumber(lines) or 50
	if n > 500 then n = 500 end
	if n < 1 then n = 1 end

	local log = run_cmd("tail -n " .. n .. " /var/log/lora_pkt_fwd.log 2>/dev/null")
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(log)
end
