module("luci.controller.jxnu_srun", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local util = require "luci.util"
local fs = require "nixio.fs"

local STATE_FILE = "/var/run/jxnu_srun/state.json"
local ACTION_FILE = "/var/run/jxnu_srun/action.json"
local LOG_FILE = "/var/log/jxnu_srun.log"

function index()
    entry({"admin", "services", "jxnu_srun"}, cbi("jxnu_srun"), _("JXNU SRun"), 80).dependent = true
    entry({"admin", "services", "jxnu_srun", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "jxnu_srun", "enqueue"}, call("action_enqueue")).leaf = true
    entry({"admin", "services", "jxnu_srun", "log_tail"}, call("action_log_tail")).leaf = true
end

local function read_json_file(path)
    local raw = fs.readfile(path)
    if not raw or raw == "" then
        return {}
    end

    local parsed = jsonc.parse(raw)
    if type(parsed) ~= "table" then
        return {}
    end
    return parsed
end

local function write_json_file(path, payload)
    local dir = path:match("^(.+)/[^/]+$")
    if dir and not fs.access(dir) then
        fs.mkdirr(dir)
    end
    fs.writefile(path, (jsonc.stringify(payload) or "{}") .. "\n")
end

function action_status()
    local data = read_json_file(STATE_FILE)
    local action = read_json_file(ACTION_FILE)
    local text = tostring(data.message or "未知")
    local pending = tostring(action.action or data.pending_action or "")
    local last_log = util.trim(sys.exec("tail -n 1 " .. LOG_FILE .. " 2>/dev/null") or "")
    local enabled = true
    if data.enabled == false or tostring(data.enabled or "") == "0" then
        enabled = false
    end

    http.prepare_content("application/json")
    http.write(jsonc.stringify({
        status = text,
        enabled = enabled,
        mode = tostring(data.current_mode or ""),
        mode_label = tostring(data.mode_label or ""),
        in_quiet = data.in_quiet and true or false,
        pending_action = pending,
        current_ssid = tostring(data.current_ssid or ""),
        current_bssid = tostring(data.current_bssid or ""),
        current_ip = tostring(data.current_ip or ""),
        current_iface = tostring(data.current_iface or ""),
        campus_account_label = tostring(data.campus_account_label or ""),
        online_account_label = tostring(data.online_account_label or ""),
        hotspot_profile_label = tostring(data.hotspot_profile_label or ""),
        campus_ssid = tostring(data.campus_ssid or ""),
        campus_bssid = tostring(data.campus_bssid or ""),
        connectivity = tostring(data.connectivity or ""),
        connectivity_level = tostring(data.connectivity_level or "offline"),
        last_action = tostring(data.last_action or ""),
        action_result = tostring(data.action_result or ""),
        last_action_ts = tonumber(data.last_action_ts) or 0,
        last_log = last_log,
        updated_at = tonumber(data.updated_at) or 0,
        ts = os.time(),
    }))
end

-- 表格 CRUD 需要的配置读写
local CONFIG_FILE = "/usr/lib/jxnu_srun/config.json"

local GLOBAL_SCALAR_KEYS_SET = {}
for _, k in ipairs({
    "enabled", "quiet_hours_enabled", "quiet_start", "quiet_end",
    "force_logout_in_quiet", "failover_enabled", "backoff_enable",
    "backoff_max_retries", "backoff_initial_duration", "backoff_max_duration",
    "manual_terminal_check_max_attempts",
    "backoff_exponent_factor", "backoff_inter_const_factor",
    "backoff_outer_const_factor", "interval", "developer_mode",
    "sta_iface", "n", "type", "enc",
}) do GLOBAL_SCALAR_KEYS_SET[k] = true end

local POINTER_KEYS_LIST = {
    "active_campus_id", "default_campus_id",
    "active_hotspot_id", "default_hotspot_id",
}
local LIST_KEYS_LIST = { "campus_accounts", "hotspot_profiles" }

local function load_config_json()
    local raw = fs.readfile(CONFIG_FILE) or "{}"
    local parsed = jsonc.parse(raw)
    return type(parsed) == "table" and parsed or {}
end

local function save_config_json(data)
    fs.writefile(CONFIG_FILE, (jsonc.stringify(data) or "{}") .. "\n")
end

local function find_index_by_id(items, target_id)
    if type(items) ~= "table" then return nil end
    for i, item in ipairs(items) do
        if type(item) == "table" and tostring(item.id or "") == target_id then
            return i
        end
    end
    return nil
end

local function next_id(items, prefix)
    local max_num = 0
    if type(items) == "table" then
        for _, item in ipairs(items) do
            local ns = tostring(item.id or ""):match("^" .. prefix .. "%-(%d+)$")
            if ns then
                local n = tonumber(ns)
                if n and n > max_num then max_num = n end
            end
        end
    end
    return prefix .. "-" .. (max_num + 1)
end

local function fv(name)
    return tostring(http.formvalue(name) or ""):match("^%s*(.-)%s*$")
end

function action_enqueue()
    local action = fv("action")

    -- 原有的 daemon action 处理
    local daemon_actions = {
        switch_hotspot = "已提交切到热点请求",
        switch_campus = "已提交切回校园网请求",
        manual_login = "已提交手动登录请求",
        manual_logout = "已提交手动登出请求",
    }
    if daemon_actions[action] then
        local requested_at = os.time()
        write_json_file(ACTION_FILE, {
            action = action,
            requested_at = requested_at,
        })
        sys.call("(sleep 1; /etc/init.d/jxnu_srun restart >/dev/null 2>&1) >/dev/null 2>&1 &")
        http.prepare_content("application/json")
        http.write(jsonc.stringify({ ok = true, message = daemon_actions[action], requested_at = requested_at }))
        return
    end

    -- 表格 CRUD 操作
    local cfg = load_config_json()
    if type(cfg.campus_accounts) ~= "table" then cfg.campus_accounts = {} end
    if type(cfg.hotspot_profiles) ~= "table" then cfg.hotspot_profiles = {} end
    local ok = false
    local message = "不支持的动作"

    if action == "add_campus" or action == "edit_campus" then
        local id = fv("id")
        local item = {
            label = fv("label"), user_id = fv("user_id"),
            operator = fv("operator"), password = fv("password"),
            base_url = fv("base_url"), ac_id = fv("ac_id"),
            ssid = fv("ssid"), bssid = fv("bssid"), radio = fv("radio"),
        }
        if item.label == "" then
            local op = item.operator or ""
            if item.user_id ~= "" and op ~= "" and op ~= "xn" then
                item.label = item.user_id .. "@" .. op
            elseif item.user_id ~= "" then
                item.label = item.user_id
            else
                item.label = "未命名账号"
            end
        end
        if action == "edit_campus" and id ~= "" then
            local idx = find_index_by_id(cfg.campus_accounts, id)
            if idx then
                item.id = id
                cfg.campus_accounts[idx] = item
                ok = true; message = "已更新"
            else
                ok = false; message = "未找到 ID: " .. id
            end
        else
            item.id = next_id(cfg.campus_accounts, "campus")
            cfg.campus_accounts[#cfg.campus_accounts + 1] = item
            if #cfg.campus_accounts == 1 then
                cfg.active_campus_id = item.id
                cfg.default_campus_id = item.id
            end
            ok = true; message = "已添加"
        end

    elseif action == "add_hotspot" or action == "edit_hotspot" then
        local id = fv("id")
        local item = {
            label = fv("label"), ssid = fv("ssid"),
            encryption = fv("encryption"), key = fv("key"),
            radio = fv("radio"),
        }
        if item.label == "" then
            item.label = item.ssid ~= "" and item.ssid or "未命名热点"
        end
        if action == "edit_hotspot" and id ~= "" then
            local idx = find_index_by_id(cfg.hotspot_profiles, id)
            if idx then
                item.id = id
                cfg.hotspot_profiles[idx] = item
                ok = true; message = "已更新"
            else
                ok = false; message = "未找到 ID: " .. id
            end
        else
            item.id = next_id(cfg.hotspot_profiles, "hotspot")
            cfg.hotspot_profiles[#cfg.hotspot_profiles + 1] = item
            if #cfg.hotspot_profiles == 1 then
                cfg.active_hotspot_id = item.id
                cfg.default_hotspot_id = item.id
            end
            ok = true; message = "已添加"
        end

    elseif action == "delete_campus" then
        local id = fv("id")
        local idx = find_index_by_id(cfg.campus_accounts, id)
        if idx then
            table.remove(cfg.campus_accounts, idx)
            if tostring(cfg.active_campus_id or "") == id then
                cfg.active_campus_id = #cfg.campus_accounts > 0 and cfg.campus_accounts[1].id or ""
            end
            if tostring(cfg.default_campus_id or "") == id then
                cfg.default_campus_id = cfg.active_campus_id
            end
            ok = true; message = "已删除"
        else
            ok = false; message = "未找到"
        end

    elseif action == "delete_hotspot" then
        local id = fv("id")
        local idx = find_index_by_id(cfg.hotspot_profiles, id)
        if idx then
            table.remove(cfg.hotspot_profiles, idx)
            if tostring(cfg.active_hotspot_id or "") == id then
                cfg.active_hotspot_id = #cfg.hotspot_profiles > 0 and cfg.hotspot_profiles[1].id or ""
            end
            if tostring(cfg.default_hotspot_id or "") == id then
                cfg.default_hotspot_id = cfg.active_hotspot_id
            end
            ok = true; message = "已删除"
        else
            ok = false; message = "未找到"
        end

    elseif action == "set_active_campus" then
        local id = fv("id")
        if find_index_by_id(cfg.campus_accounts, id) then
            cfg.active_campus_id = id
            cfg.default_campus_id = id
            ok = true; message = "已切换"
        else
            ok = false; message = "未找到"
        end

    elseif action == "set_active_hotspot" then
        local id = fv("id")
        if find_index_by_id(cfg.hotspot_profiles, id) then
            cfg.active_hotspot_id = id
            cfg.default_hotspot_id = id
            ok = true; message = "已切换"
        else
            ok = false; message = "未找到"
        end
    end

    if ok then
        save_config_json(cfg)
        sys.call("(sleep 1; /etc/init.d/jxnu_srun restart >/dev/null 2>&1) >/dev/null 2>&1 &")
    end

    http.prepare_content("application/json")
    http.write(jsonc.stringify({ ok = ok, message = message, action = action, ts = os.time() }))
end

function action_log_tail()
    local since = tonumber(http.formvalue("since")) or 0
    local lines = tonumber(http.formvalue("lines")) or 400
    if lines < 10 then
        lines = 10
    elseif lines > 1000 then
        lines = 1000
    end

    local text = sys.exec("tail -n " .. lines .. " /var/log/jxnu_srun.log 2>/dev/null") or ""
    if since > 0 and text ~= "" then
        local kept = {}
        for line in text:gmatch("[^\n]+") do
            local y, m, d, hh, mm, ss = line:match("^%[(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)%]")
            if y then
                local ts = os.time({
                    year = tonumber(y), month = tonumber(m), day = tonumber(d),
                    hour = tonumber(hh), min = tonumber(mm), sec = tonumber(ss)
                }) or 0
                if ts >= since then
                    kept[#kept + 1] = line
                end
            end
        end
        text = table.concat(kept, "\n")
    end
    if text == "" then
        text = "No logs yet."
    end

    http.prepare_content("application/json")
    http.write(jsonc.stringify({
        log = text,
        ts = os.time(),
    }))
end
