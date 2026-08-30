if package.loaded["re2_vr_reload_ext_5"] then
    return package.loaded["re2_vr_reload_ext_5"]
end

local M = {}

local Drop = {}

local CFG = nil

function Drop.init(deps)
    CFG = deps and deps.CFG
end

function Drop.fall_duration(cfg)
    cfg = cfg or CFG
    local anim = cfg and cfg.anim
    if type(anim) ~= "table" then return 0.5 end
    return math.max(0.01, tonumber(anim.fall_sec) or 0.5)
end

function Drop.fall_distance(cfg)
    cfg = cfg or CFG
    local anim = cfg and cfg.anim
    if type(anim) ~= "table" then return 1.2 end
    return tonumber(anim.fall_distance) or 1.2
end

function Drop.cache_frozen_rotation(st, rot)
    if not rot then return end
    st.frozen_rot_x = rot.x
    st.frozen_rot_y = rot.y
    st.frozen_rot_z = rot.z
    st.frozen_rot_w = rot.w
end

function Drop.get_frozen_rotation(st)
    return Quaternion.new(
        st.frozen_rot_w or 1.0,
        st.frozen_rot_x or 0.0,
        st.frozen_rot_y or 0.0,
        st.frozen_rot_z or 0.0)
end

function Drop.set_frozen_world(st, pos, rot)
    if not st or not pos then return end
    st.freeze_pose = true
    st.freeze_wx = pos.x
    st.freeze_wy = pos.y
    st.freeze_wz = pos.z
    if rot then Drop.cache_frozen_rotation(st, rot) end
end

function Drop.clear_freeze(st)
    if not st then return end
    st.freeze_pose = false
end

function Drop.clear_release(st)
    if not st then return end
    st.release_fall_active = false
    Drop.clear_freeze(st)
end

function Drop.begin_release(st, pos, rot)
    if not st or not pos then return false end
    st.release_fall_active = true
    st.release_start = os.clock()
    st.release_sx = pos.x
    st.release_sy = pos.y
    st.release_sz = pos.z
    if rot then
        st.release_rx = rot.x
        st.release_ry = rot.y
        st.release_rz = rot.z
        st.release_rw = rot.w
    end
    Drop.set_frozen_world(st, pos, rot)
    return true
end

function Drop.apply_frozen_pose(st, target, target_kind, write_world_pos, write_world_rot)
    if not st or not st.freeze_pose or not target then return end
    if not write_world_pos then return end
    write_world_pos(target, target_kind,
        Vector3f.new(st.freeze_wx or 0.0, st.freeze_wy or 0.0, st.freeze_wz or 0.0))
    if write_world_rot and st.frozen_rot_w then
        write_world_rot(target, target_kind, Drop.get_frozen_rotation(st))
    end
end

function Drop.tick_release(st, io)
    if not st or not st.release_fall_active or not io or not io.target then return false end
    if io.ensure_visible then io.ensure_visible() end

    local elapsed = os.clock() - (st.release_start or 0.0)
    local duration = io.fall_duration or Drop.fall_duration()
    local t = elapsed / duration
    if t > 1.0 then t = 1.0 end
    local fall = (io.fall_distance or Drop.fall_distance()) * (t * t)
    local pos = Vector3f.new(st.release_sx or 0.0, (st.release_sy or 0.0) - fall, st.release_sz or 0.0)
    local rot = Quaternion.new(
        st.release_rw or 1.0,
        st.release_rx or 0.0,
        st.release_ry or 0.0,
        st.release_rz or 0.0)

    Drop.set_frozen_world(st, pos, rot)
    if io.write_world_pos then io.write_world_pos(io.target, io.target_kind, pos) end
    if io.write_world_rot then io.write_world_rot(io.target, io.target_kind, rot) end

    if t < 1.0 then return true end

    st.release_fall_active = false
    Drop.clear_freeze(st)
    if io.on_complete then io.on_complete() end
    return false
end

function Drop.resolve_drop_joint_name(cfg, wp)
    if type(cfg) ~= "table" or type(wp) ~= "string" then return "_04" end
    local by = cfg.reload_drop_joint_by_wp
    if type(by) == "table" and type(by[wp]) == "string" and by[wp] ~= "" then
        return by[wp]
    end
    by = cfg.bullet_joint_by_wp
    if type(by) == "table" and type(by[wp]) == "string" and by[wp] ~= "" then
        return by[wp]
    end
    by = cfg.shell_joint_by_wp
    if type(by) == "table" and type(by[wp]) == "string" and by[wp] ~= "" then
        return by[wp]
    end
    by = cfg.mag_node_by_wp
    if type(by) == "table" and type(by[wp]) == "string" and by[wp] ~= "" then
        return by[wp]
    end
    return "_04"
end

function Drop.reload_drop_slots(cfg, wp, entry)
    if type(entry) == "table" and type(entry.reload_drop_slots) == "number" then
        return math.max(1, math.floor(entry.reload_drop_slots))
    end
    if type(cfg) == "table" and type(cfg.reload_drop_slots_by_wp) == "table" then
        local n = cfg.reload_drop_slots_by_wp[wp]
        if type(n) == "number" then return math.max(1, math.floor(n)) end
    end
    return 6
end




M.drop = Drop

local SOUND_KINDS = {
    "mag_drop",
    "mag_floor",
    "mag_grab",
    "mag_insert",
    "slide_rack_pull",
    "slide_rack_release",
    "pump_fire",
    "dry_fire",
}

local DEFAULT_SOUND_ENTRY = {
    mag_drop = "",
    mag_floor = "",
    mag_grab = "",
    mag_insert = "",
    slide_rack_pull = "",
    slide_rack_release = "",
    pump_fire = "",
    dry_fire = "",
}

local KIND_VOLUME_DEFAULT = 1.0
local KIND_VOLUME_MIN = 0.0
local KIND_VOLUME_MAX = 2.0

local CFG = nil
local get_weapon_go_name = nil
local weapon_display_name = nil
local is_weapon_enabled = nil
local mark_tuning_dirty = nil
local get_vr_controller_world_pos = nil

local DEBOUNCE_S = 0.10
local debounce = {}
local last_play = {
    kind = nil,
    wp = nil,
    file = nil,
    folder = nil,
    path = nil,
    ok = false,
    reason = nil,
}

local file_cache = { wp = nil, files = nil, t = 0.0 }
local folder_cache = { names = nil, t = 0.0 }
local CACHE_TTL = 2.0

local ui = {
    edit_wp = nil,
    lock_selection = false,
    status = nil,
}
local clipboard = { source_wp = nil, entry = nil }

local PATH_SEP = "[\\\\/]"
local FOLDER_SUFFIX = "_media"

local function normalize_rel_path(rel)
    if type(rel) ~= "string" then return "" end
    return rel:gsub("\\", "/")
end

local function canonical_wp(wp)
    if type(wp) ~= "string" or wp == "" then
        return wp
    end
    return wp:gsub("_media$", "")
end

local function wp_from_folder_name(folder)
    if not folder then return nil end
    return folder:gsub("_media$", "")
end

local function sfx_folder_names_for_wp(wp)
    if not wp or wp == "" then return {} end
    local out = {}
    local seen = {}
    local function add(name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    add(wp)
    if not wp:match("_media$") then
        add(wp .. FOLDER_SUFFIX)
    end
    if wp:match("_media$") then
        add(wp:gsub("_media$", ""))
    end
    return out
end

local function config_keys_for_wp(wp)
    local keys = {}
    local seen = {}
    local function add(key)
        if key and key ~= "" and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    local canon = canonical_wp(wp)
    add(canon)
    for _, folder_name in ipairs(sfx_folder_names_for_wp(canon or wp)) do
        add(folder_name)
    end
    return keys
end

local function glob_rel_paths(pattern)
    if fs == nil or type(fs.glob) ~= "function" then
        return {}
    end
    local ok, results = pcall(fs.glob, pattern)
    if not ok or type(results) ~= "table" then
        return {}
    end
    local paths = {}
    for _, rel in pairs(results) do
        if type(rel) == "string" and rel ~= "" then
            paths[#paths + 1] = normalize_rel_path(rel)
        end
    end
    table.sort(paths)
    return paths
end

local function glob_basenames(pattern)
    local files = {}
    for _, rel in ipairs(glob_rel_paths(pattern)) do
        local name = rel:match("([^/]+)$")
        if name and name ~= "" then
            files[#files + 1] = name
        end
    end
    table.sort(files)
    return files
end

local folder_map_cache = { t = 0.0, by_weapon = nil, disk_folders = nil }

local function invalidate_folder_map_cache()
    folder_map_cache.by_weapon = nil
    folder_map_cache.disk_folders = nil
    folder_map_cache.t = 0.0
end

local function rebuild_folder_map()
    local now = os.clock()
    if folder_map_cache.by_weapon and (now - folder_map_cache.t) < CACHE_TTL then
        return folder_map_cache.by_weapon, folder_map_cache.disk_folders
    end

    local by_weapon = {}
    local disk_folders = {}
    local disk_seen = {}

    for _, rel in ipairs(glob_rel_paths("custom_sfx" .. PATH_SEP .. ".*\\.(ogg|wav)")) do
        local folder, subpath = rel:match("^custom_sfx/([^/]+)/(.+)$")
        if folder and subpath and folder ~= "common" then
            if not disk_seen[folder] then
                disk_seen[folder] = true
                disk_folders[#disk_folders + 1] = folder
            end
            by_weapon[folder] = by_weapon[folder] or {}
            by_weapon[folder][#by_weapon[folder] + 1] = subpath
        end
    end

    table.sort(disk_folders)
    for _, files in pairs(by_weapon) do
        table.sort(files)
    end

    folder_map_cache.by_weapon = by_weapon
    folder_map_cache.disk_folders = disk_folders
    folder_map_cache.t = now
    return by_weapon, disk_folders
end

local function deep_copy(tbl)
    if type(tbl) ~= "table" then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = deep_copy(v)
    end
    return out
end

local function clamp_kind_volume(v)
    v = tonumber(v)
    if not v then return KIND_VOLUME_DEFAULT end
    if v < KIND_VOLUME_MIN then return KIND_VOLUME_MIN end
    if v > KIND_VOLUME_MAX then return KIND_VOLUME_MAX end
    return v
end

local function ensure_volume_by_kind(tbl)
    if type(tbl) ~= "table" then return end
    tbl.volume_by_kind = tbl.volume_by_kind or {}
end

local function get_kind_volume(tbl, kind)
    if type(tbl) ~= "table" or type(tbl.volume_by_kind) ~= "table" then
        return KIND_VOLUME_DEFAULT
    end
    return clamp_kind_volume(tbl.volume_by_kind[kind])
end

local function set_kind_volume(tbl, kind, value)
    if type(tbl) ~= "table" or not kind then return end
    ensure_volume_by_kind(tbl)
    tbl.volume_by_kind[kind] = clamp_kind_volume(value)
end

local function resolve_global_table(name)
    local v = rawget(_G, name)
    if v == nil then
        local ok, env = pcall(function() return _ENV end)
        if ok and type(env) == "table" then
            v = env[name]
        end
    end
    if type(v) == "table" then
        return v
    end
    return nil
end

local function audio_api()
    for _, name in ipairs({ "re_audio", "my_audio" }) do
        local api = resolve_global_table(name)
        if api ~= nil and type(api.play_path) == "function" then
            local usable = true
            if type(api.is_available) == "function" then
                local ok, avail = pcall(api.is_available)
                if ok and avail == false then
                    usable = false
                end
            end
            if usable then
                return api
            end
        end
    end
    return nil
end

local function weapon_sfx_cfg()
    return CFG and CFG.weapon_sfx
end

local function sfx_enabled()
    local ws = weapon_sfx_cfg()
    return ws ~= nil and ws.enabled == true and audio_api() ~= nil
end

local function raw_entry(wp)
    local ws = weapon_sfx_cfg()
    if not ws or type(ws.by_wp) ~= "table" or not wp then
        return nil
    end
    return ws.by_wp[wp]
end

local function resolve_kind_volume_multiplier(ws, config_wp, kind, opts)
    local entry = raw_entry(canonical_wp(config_wp))
    local mul = get_kind_volume(ws, kind) * get_kind_volume(entry, kind)
    local opts_vol = opts and tonumber(opts.volume)
    if opts_vol then
        mul = mul * clamp_kind_volume(opts_vol)
    end
    return mul
end

local function resolve_sfx_folder(config_wp)
    if not config_wp or config_wp == "" then
        return nil
    end

    local canon = canonical_wp(config_wp)
    local entry = raw_entry(canon)
    if entry and type(entry.sfx_folder) == "string" and entry.sfx_folder ~= "" then
        return entry.sfx_folder
    end

    local by_weapon, disk_folders = rebuild_folder_map()
    for _, folder_name in ipairs(sfx_folder_names_for_wp(canon)) do
        if by_weapon[folder_name] ~= nil then
            return folder_name
        end
    end

    for _, folder in ipairs(disk_folders) do
        local wp = wp_from_folder_name(folder)
        if wp == canon then
            return folder
        end
    end

    for _, folder_name in ipairs(sfx_folder_names_for_wp(canon)) do
        if folder_name:match("_media$") then
            return folder_name
        end
    end

    return nil
end

local function scan_files_for_folder(folder)
    if not folder or folder == "" then
        return {}
    end
    local now = os.clock()
    local cache_key = "folder:" .. folder
    if file_cache.wp == cache_key and file_cache.files and (now - file_cache.t) < CACHE_TTL then
        return file_cache.files
    end

    local by_weapon = rebuild_folder_map()
    local files = {}
    if by_weapon[folder] then
        for _, subpath in ipairs(by_weapon[folder]) do
            files[#files + 1] = subpath
        end
    end

    file_cache.wp = cache_key
    file_cache.files = files
    file_cache.t = now
    return files
end

local function scan_files_for_wp(wp)
    local folder = resolve_sfx_folder(wp)
    if not folder then
        return {}
    end
    return scan_files_for_folder(folder)
end

local function discover_weapon_folders()
    local now = os.clock()
    if folder_cache.names and (now - folder_cache.t) < CACHE_TTL then
        return folder_cache.names
    end

    local seen = {}
    local names = {}
    local function add_wp(wp)
        wp = canonical_wp(wp)
        if wp and wp ~= "" and not seen[wp] then
            seen[wp] = true
            names[#names + 1] = wp
        end
    end

    local _, disk_folders = rebuild_folder_map()
    for _, folder in ipairs(disk_folders) do
        add_wp(wp_from_folder_name(folder))
    end

    table.sort(names)
    folder_cache.names = names
    folder_cache.t = now
    return names
end

local function ensure_sound_entry(wp)
    local ws = weapon_sfx_cfg()
    if not ws then return nil end
    wp = canonical_wp(wp or (get_weapon_go_name and get_weapon_go_name()) or nil)
    if not wp then return nil end
    ws.by_wp = ws.by_wp or {}
    local entry = ws.by_wp[wp]
    if not entry then
        entry = deep_copy(DEFAULT_SOUND_ENTRY)
        entry.fallback_wp = ""
        entry.sfx_folder = ""
        ws.by_wp[wp] = entry
    end
    if entry.fallback_wp == nil then
        entry.fallback_wp = ""
    end
    if entry.sfx_folder == nil then
        entry.sfx_folder = ""
    end
    ensure_volume_by_kind(ws)
    ensure_volume_by_kind(entry)
    local legacy_blocked = entry.fire_blocked_mag_out
    if type(legacy_blocked) == "string" and legacy_blocked ~= ""
        and (type(entry.dry_fire) ~= "string" or entry.dry_fire == "") then
        entry.dry_fire = legacy_blocked
    end
    return entry, wp
end

local function resolve_playback_folder(config_wp)
    local canon = canonical_wp(config_wp)
    if not canon or canon == "" then
        return nil
    end

    local folder = resolve_sfx_folder(canon)
    if folder then
        return folder
    end

    local entry = raw_entry(canon)
    local fb = entry and entry.fallback_wp or ""
    if fb ~= "" then
        folder = resolve_sfx_folder(fb)
        if folder then return folder end
    end

    local ws = weapon_sfx_cfg()
    local default_fb = ws and ws.default_fallback_wp or ""
    if default_fb ~= "" then
        folder = resolve_sfx_folder(default_fb)
        if folder then return folder end
    end

    return nil
end

local function assignment_from_keys(keys, kind)
    for _, key in ipairs(keys) do
        local entry = raw_entry(key)
        local filename = entry and entry[kind]
        if type(filename) == "string" and filename ~= "" then
            return filename, canonical_wp(key)
        end
    end
    return nil, nil
end

local function resolve_assignment(config_wp, kind)
    local canon = canonical_wp(config_wp)
    if not canon or not kind then
        return nil, nil
    end

    if kind == "fire_blocked_mag_out" then
        kind = "dry_fire"
    end

    local filename, assignment_wp = assignment_from_keys(config_keys_for_wp(canon), kind)
    if filename then
        return filename, assignment_wp
    end

    local entry = raw_entry(canon)
    local fb = entry and entry.fallback_wp or ""
    if fb ~= "" then
        filename, assignment_wp = assignment_from_keys(config_keys_for_wp(fb), kind)
        if filename then
            return filename, assignment_wp
        end
    end

    local ws = weapon_sfx_cfg()
    local default_fb = ws and ws.default_fallback_wp or ""
    if default_fb ~= "" then
        filename, assignment_wp = assignment_from_keys(config_keys_for_wp(default_fb), kind)
        if filename then
            return filename, assignment_wp
        end
    end

    return nil, nil
end

local function count_assigned(entry)
    if not entry then return 0 end
    local n = 0
    for _, kind in ipairs(SOUND_KINDS) do
        if type(entry[kind]) == "string" and entry[kind] ~= "" then
            n = n + 1
        end
    end
    return n
end

local function set_last_play(fields)
    last_play.kind = fields.kind
    last_play.wp = fields.wp
    last_play.file = fields.file
    last_play.folder = fields.folder
    last_play.path = fields.path
    last_play.ok = fields.ok == true
    last_play.reason = fields.reason
end

local function migrate_weapon_sfx_config()
    local ws = weapon_sfx_cfg()
    if not ws then return false end
    ws.by_wp = ws.by_wp or {}

    local changed = false

    if ws.by_wp.common then
        ws.by_wp.common = nil
        changed = true
    end

    local to_remove = {}
    for wp, entry in pairs(ws.by_wp) do
        if type(entry) == "table" and wp:match("_media$") then
            local canon = canonical_wp(wp)
            local canon_entry = ws.by_wp[canon]
            if not canon_entry then
                canon_entry = deep_copy(DEFAULT_SOUND_ENTRY)
                canon_entry.fallback_wp = ""
                canon_entry.sfx_folder = ""
                ws.by_wp[canon] = canon_entry
                changed = true
            end

            if (canon_entry.sfx_folder or "") == "" then
                canon_entry.sfx_folder = wp
                changed = true
            end

            for _, kind in ipairs(SOUND_KINDS) do
                local src = entry[kind]
                if type(src) == "string" and src ~= "" and (canon_entry[kind] or "") == "" then
                    canon_entry[kind] = src
                    changed = true
                end
            end

            if (canon_entry.fallback_wp or "") == "" and type(entry.fallback_wp) == "string" and entry.fallback_wp ~= "" then
                canon_entry.fallback_wp = canonical_wp(entry.fallback_wp)
                changed = true
            end

            to_remove[#to_remove + 1] = wp
        end
    end

    for _, wp in ipairs(to_remove) do
        ws.by_wp[wp] = nil
        changed = true
    end

    for wp, entry in pairs(ws.by_wp) do
        if type(entry) == "table" and type(entry.fallback_wp) == "string" and entry.fallback_wp ~= "" then
            local fixed = canonical_wp(entry.fallback_wp)
            if fixed ~= entry.fallback_wp then
                entry.fallback_wp = fixed
                changed = true
            end
        end
        if type(entry) == "table" then
            ensure_volume_by_kind(entry)
        end
    end

    ensure_volume_by_kind(ws)

    return changed
end

local function sync_edit_wp_to_current()
    if ui.lock_selection then
        return
    end
    local wp = get_weapon_go_name and get_weapon_go_name()
    if wp then
        ui.edit_wp = canonical_wp(wp)
    end
end

local function vec3_from_vrmod(index)
    if vrmod == nil or type(vrmod.get_position) ~= "function" then
        return nil
    end
    local ok, v = pcall(vrmod.get_position, vrmod, index)
    if not ok or v == nil then
        return nil
    end
    if type(v) == "table" and v.x ~= nil then
        return { x = v.x, y = v.y, z = v.z }
    end
    return nil
end

function M.update_listener()
    if not sfx_enabled() then return end
    local api = audio_api()
    if api == nil or type(api.set_listener) ~= "function" then
        return
    end
    local hmd_pos = vec3_from_vrmod(0)
    if hmd_pos == nil then
        return
    end
    local forward = { x = 0.0, y = 0.0, z = 1.0 }
    local up = { x = 0.0, y = 1.0, z = 0.0 }
    if type(vrmod.get_rotation) == "function" then
        local ok, rot = pcall(vrmod.get_rotation, vrmod, 0)
        if ok and rot ~= nil and type(rot) == "table" then
            if rot.z ~= nil then
                forward = { x = rot.x or 0, y = rot.y or 0, z = rot.z or 1 }
            end
            if rot.up_x ~= nil then
                up = { x = rot.up_x or 0, y = rot.up_y or 1, z = rot.up_z or 0 }
            end
        end
    end
    pcall(api.set_listener, {
        pos = hmd_pos,
        forward = forward,
        up = up,
    })
end

function M.play(kind, opts)
    if not kind then
        set_last_play({ kind = nil, wp = nil, file = nil, folder = nil, path = nil, ok = false, reason = "invalid" })
        return false
    end

    if not sfx_enabled() then
        set_last_play({ kind = kind, wp = nil, file = nil, folder = nil, path = nil, ok = false, reason = "disabled" })
        return false
    end

    local t = os.clock()
    if debounce[kind] and (t - debounce[kind]) < DEBOUNCE_S then
        set_last_play({ kind = kind, wp = nil, file = nil, folder = nil, path = nil, ok = false, reason = "debounced" })
        return false
    end
    debounce[kind] = t

    local config_wp = canonical_wp((opts and opts.wp) or (get_weapon_go_name and get_weapon_go_name()))
    if not config_wp then
        set_last_play({ kind = kind, wp = nil, file = nil, folder = nil, path = nil, ok = false, reason = "no_weapon" })
        return false
    end

    ensure_sound_entry(config_wp)

    local filename, assignment_wp = resolve_assignment(config_wp, kind)
    if type(filename) ~= "string" or filename == "" then
        set_last_play({
            kind = kind,
            wp = config_wp,
            file = nil,
            folder = nil,
            path = nil,
            ok = false,
            reason = "no_assignment",
        })
        return false
    end

    local playback_folder = resolve_playback_folder(assignment_wp or config_wp)
    if not playback_folder or playback_folder == "" then
        set_last_play({
            kind = kind,
            wp = config_wp,
            file = filename,
            folder = nil,
            path = nil,
            ok = false,
            reason = "no_file",
        })
        return false
    end

    local ws = weapon_sfx_cfg()
    local api = audio_api()
    local master = tonumber(ws.master_volume) or 1.0
    if master < 0.0 then master = 0.0 elseif master > 1.0 then master = 1.0 end
    local kind_mul = resolve_kind_volume_multiplier(ws, config_wp, kind, opts)
    local play_opts = {
        volume = master * kind_mul,
        spatial = ws.spatial == true,
    }
    if play_opts.spatial then
        local pos = nil
        if get_vr_controller_world_pos then
            pos = get_vr_controller_world_pos(1)
        end
        if pos == nil then
            pos = vec3_from_vrmod(1) or vec3_from_vrmod(0)
        end
        if pos ~= nil then
            play_opts.pos = pos
        end
    end

    local play_path_str
    if filename:match("^common/") then
        play_path_str = filename
    else
        play_path_str = playback_folder .. "/" .. filename
    end

    local ok, result = pcall(api.play_path, play_path_str, play_opts)
    local played = ok and result == true
    set_last_play({
        kind = kind,
        wp = config_wp,
        file = filename,
        folder = playback_folder,
        path = play_path_str,
        ok = played,
        reason = played and "ok" or "api_error",
    })
    return played
end

function M.on_weapon_swap()
    file_cache.wp = nil
    file_cache.files = nil
    invalidate_folder_map_cache()
    folder_cache.names = nil
    sync_edit_wp_to_current()
end

function M.get_last_play()
    return last_play
end

function M.get_sound_kinds()
    return SOUND_KINDS
end

local function collect_edit_wp_names()
    local seen = {}
    local names = {}
    local function add(wp)
        wp = canonical_wp(wp)
        if wp and wp ~= "" and not seen[wp] then
            seen[wp] = true
            names[#names + 1] = wp
        end
    end
    add(get_weapon_go_name and get_weapon_go_name())
    if type(CFG.weapons) == "table" then
        for wp in pairs(CFG.weapons) do
            add(wp)
        end
    end
    for _, wp in ipairs(discover_weapon_folders()) do
        add(wp)
    end
    table.sort(names)
    return names
end

local function combo_index_for_value(values, value)
    for i, v in ipairs(values) do
        if v == value then return i end
    end
    return 1
end

local function build_file_combo_list(config_wp)
    local folder = resolve_playback_folder(config_wp)
    local files = folder and scan_files_for_folder(folder) or {}
    local common = glob_basenames("custom_sfx" .. PATH_SEP .. "common" .. PATH_SEP .. "[^" .. PATH_SEP .. "]+\\.(ogg|wav)")
    local seen = {}
    local out = { "(none)" }
    for _, f in ipairs(files) do
        if not seen[f] then
            seen[f] = true
            out[#out + 1] = f
        end
    end
    for _, f in ipairs(common) do
        local key = "common/" .. f
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    return out
end

local function init_audio(deps)
    CFG = deps.CFG
    get_weapon_go_name = deps.get_weapon_go_name
    weapon_display_name = deps.weapon_display_name
    is_weapon_enabled = deps.is_weapon_enabled
    mark_tuning_dirty = deps.mark_tuning_dirty
    get_vr_controller_world_pos = deps.get_vr_controller_world_pos
    if migrate_weapon_sfx_config() and mark_tuning_dirty then
        mark_tuning_dirty()
    end
    sync_edit_wp_to_current()
end



local function init_lhp(deps)
    local get_mag_hand = deps.get_mag_hand
    local get_weapon_go_name = deps.get_weapon_go_name
    local weapon_display_name = deps.weapon_display_name or function(wp) return tostring(wp) end
    local current_profile_key = deps.current_profile_key
    local mark_tuning_dirty = deps.mark_tuning_dirty or function() end
    local shell_pose_active = deps.shell_pose_active
    local revolver_pose_active = deps.revolver_pose_active
    local CFG = deps.CFG
    local sc = deps.sc
    local re2 = deps.re2


local LEFT_HAND_POSE_BONES = {
    "l_hand_index_0", "l_hand_index_1", "l_hand_index_2",
    "l_hand_middle_0", "l_hand_middle_1", "l_hand_middle_2",
    "l_hand_ring_0", "l_hand_ring_1", "l_hand_ring_2", "l_hand_ring_3",
    "l_hand_little_0", "l_hand_little_1", "l_hand_little_2", "l_hand_little_3",
    "l_hand_thumb_0", "l_hand_thumb_1", "l_hand_thumb_2",
}

local LEFT_HAND_POSE_BONE_SET = {}
for _, bone in ipairs(LEFT_HAND_POSE_BONES) do
    LEFT_HAND_POSE_BONE_SET[bone] = true
end

local LEFT_HAND_POSE_GROUPS = {
    { id = "index", label = "Index", bones = {
        "l_hand_index_0", "l_hand_index_1", "l_hand_index_2",
    }},
    { id = "middle", label = "Middle", bones = {
        "l_hand_middle_0", "l_hand_middle_1", "l_hand_middle_2",
    }},
    { id = "ring", label = "Ring", bones = {
        "l_hand_ring_0", "l_hand_ring_1", "l_hand_ring_2", "l_hand_ring_3",
    }},
    { id = "little", label = "Little", bones = {
        "l_hand_little_0", "l_hand_little_1", "l_hand_little_2", "l_hand_little_3",
    }},
    { id = "thumb", label = "Thumb", bones = {
        "l_hand_thumb_0", "l_hand_thumb_1", "l_hand_thumb_2",
    }},
}

local LHP_CONTEXT_MAG = "mag_hold"
local LHP_CONTEXT_SLIDE = "slide_rack"
local LHP_CONTEXT_SHELL = "shell_hold"
local LHP_CONTEXT_BULLET = "bullet_hold"

local lhp_preview = {
    mag_hold = { active = false, until_t = 0.0 },
    slide_rack = { active = false, until_t = 0.0 },
    shell_hold = { active = false, until_t = 0.0 },
    bullet_hold = { active = false, until_t = 0.0 },
}

local lhp_ui = {
    edit_context = LHP_CONTEXT_MAG,
    status = nil,
}

local lhp_runtime = {
    mag_factor = 0.0,
    slide_factor = 0.0,
    shell_factor = 0.0,
    bullet_factor = 0.0,
    last_t = nil,
}


local function get_player_transform()
    local player = re2.get_localplayer()
    if player then
        local tf = sc(player, "get_Transform")
        if tf then return tf end
    end
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then return nil end
    local ctx = sc(cm, "get_PlayerContextFast")
    if not ctx then return nil end
    local go = sc(ctx, "get_GameObject")
    if not go then return nil end
    return sc(go, "get_Transform")
end

local function lhp_preview_sec()
    local lhp = CFG.left_hand_pose or {}
    return tonumber(lhp.preview_sec) or 5.0
end

local function lhp_blend_sec()
    local lhp = CFG.left_hand_pose or {}
    return tonumber(lhp.blend_sec) or 0.12
end

local function lhp_active_profile_key()
    if current_profile_key then
        return current_profile_key()
    end
    return "leon"
end

local function lhp_active_weapon_key()
    if get_weapon_go_name then
        return get_weapon_go_name()
    end
    return nil
end

local function ensure_lhp_wp_profile_table(context_key, wp_name, profile_key)
    CFG.left_hand_pose = CFG.left_hand_pose or {}
    CFG.left_hand_pose[context_key] = CFG.left_hand_pose[context_key] or {}
    local ctx = CFG.left_hand_pose[context_key]
    ctx.by_wp = ctx.by_wp or {}
    ctx.by_wp[wp_name] = ctx.by_wp[wp_name] or {}
    local wp_entry = ctx.by_wp[wp_name]
    wp_entry[profile_key] = wp_entry[profile_key] or {}
    local entry = wp_entry[profile_key]
    if type(entry.pose) ~= "table" then entry.pose = {} end
    return entry
end

local function resolve_lhp_context_entry(context_key)
    CFG.left_hand_pose = CFG.left_hand_pose or {}
    CFG.left_hand_pose[context_key] = CFG.left_hand_pose[context_key] or {}
    local ctx = CFG.left_hand_pose[context_key]

    local wp = lhp_active_weapon_key()
    local profile = lhp_active_profile_key()
    if wp and type(ctx.by_wp) == "table" and type(ctx.by_wp[wp]) == "table" then
        local wp_entry = ctx.by_wp[wp]
        local prof_entry = wp_entry[profile] or wp_entry.leon
        if type(prof_entry) == "table" then
            return prof_entry
        end
    end

    if type(ctx.pose) == "table" then
        return ctx
    end
    return ctx
end

local function ensure_lhp_context(context_key)
    local wp = lhp_active_weapon_key()
    if wp then
        return ensure_lhp_wp_profile_table(context_key, wp, lhp_active_profile_key())
    end
    CFG.left_hand_pose[context_key] = CFG.left_hand_pose[context_key] or {}
    local entry = CFG.left_hand_pose[context_key]
    if type(entry.pose) ~= "table" then entry.pose = {} end
    return entry
end

local function lhp_normalize_angle(a)
    while a > 180.0 do a = a - 360.0 end
    while a < -180.0 do a = a + 360.0 end
    return a
end

local function lhp_lerp_angle(from_a, to_a, t)
    local d = lhp_normalize_angle(to_a - from_a)
    return lhp_normalize_angle(from_a + d * t)
end

local function read_joint_local_euler(joint)
    if not joint then return nil end
    local e = sc(joint, "get_LocalEulerAngle")
    if not e then
        e = sc(joint, "get_LocalRotation")
    end
    if not e then return nil end
    if type(e.x) == "number" then
        return { tonumber(e.x) or 0.0, tonumber(e.y) or 0.0, tonumber(e.z) or 0.0 }
    end
    return nil
end

local function capture_left_hand_bone_pose()
    local tf = get_player_transform()
    if not tf then return nil end
    local out = {}
    local count = 0
    for _, bone in ipairs(LEFT_HAND_POSE_BONES) do
        local joint = sc(tf, "getJointByName", bone)
        local euler = joint and read_joint_local_euler(joint)
        if euler then
            out[bone] = euler
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return out
end

local function capture_lhp_context_pose(context_key)
    local pose = capture_left_hand_bone_pose()
    if not pose then
        lhp_ui.status = "Capture failed — no left hand bones resolved"
        return false
    end
    local entry = ensure_lhp_context(context_key)
    entry.pose = pose
    lhp_preview[context_key].active = true
    lhp_preview[context_key].until_t = os.clock() + lhp_preview_sec()
    local n = 0
    for _ in pairs(pose) do n = n + 1 end
    lhp_ui.status = string.format("Captured %s (%d bones)", context_key, n)
    log.info(string.format("[re2_vr_reload] Left hand pose captured [%s]: %d bones", context_key, n))
    return true
end

local function extend_lhp_preview(context_key)
    lhp_preview[context_key].active = true
    lhp_preview[context_key].until_t = os.clock() + lhp_preview_sec()
end

local function cancel_lhp_preview(context_key)
    if context_key then
        lhp_preview[context_key].active = false
        lhp_preview[context_key].until_t = 0.0
        return
    end
    lhp_preview.mag_hold.active = false
    lhp_preview.mag_hold.until_t = 0.0
    lhp_preview.slide_rack.active = false
    lhp_preview.slide_rack.until_t = 0.0
    lhp_preview.shell_hold.active = false
    lhp_preview.shell_hold.until_t = 0.0
    lhp_preview.bullet_hold.active = false
    lhp_preview.bullet_hold.until_t = 0.0
end

local function tick_lhp_preview()
    local now = os.clock()
    for _, key in ipairs({ LHP_CONTEXT_MAG, LHP_CONTEXT_SLIDE, LHP_CONTEXT_SHELL, LHP_CONTEXT_BULLET }) do
        local p = lhp_preview[key]
        if p.active and now >= p.until_t then
            p.active = false
        end
    end
end

local function lhp_pose_has_bones(pose)
    return type(pose) == "table" and next(pose) ~= nil
end

local function lhp_update_blend(want_mag, want_slide, want_shell, want_bullet)
    local now = os.clock()
    local last = lhp_runtime.last_t
    lhp_runtime.last_t = now
    local dt = (last == nil) and (1 / 60) or (now - last)
    if dt < 0 or dt > 0.25 then dt = 1 / 60 end
    local bt = lhp_blend_sec()
    local step = (bt <= 0.0001) and 1.0 or math.min(1.0, dt / bt)
    lhp_runtime.mag_factor = lhp_runtime.mag_factor + ((want_mag and 1.0 or 0.0) - lhp_runtime.mag_factor) * step
    lhp_runtime.slide_factor = lhp_runtime.slide_factor + ((want_slide and 1.0 or 0.0) - lhp_runtime.slide_factor) * step
    lhp_runtime.shell_factor = lhp_runtime.shell_factor + ((want_shell and 1.0 or 0.0) - lhp_runtime.shell_factor) * step
    lhp_runtime.bullet_factor = lhp_runtime.bullet_factor + ((want_bullet and 1.0 or 0.0) - lhp_runtime.bullet_factor) * step
end

local function bullet_in_hand_for_pose()
    if type(revolver_pose_active) == "function" then
        return revolver_pose_active() == true
    end
    return rawget(_G, "__vr_bullet_in_left_hand") == true
end

local function resolve_bullet_hold_pose_entry()
    local bullet_entry = resolve_lhp_context_entry(LHP_CONTEXT_BULLET)
    if bullet_entry.apply_enabled ~= false and lhp_pose_has_bones(bullet_entry.pose) then
        return bullet_entry
    end
    return resolve_lhp_context_entry(LHP_CONTEXT_MAG)
end

local function shell_in_hand_for_pose()
    if type(shell_pose_active) == "function" then
        return shell_pose_active() == true
    end
    return rawget(_G, "__vr_shell_in_left_hand") == true
end

local function resolve_shell_hold_pose_entry()
    local shell_entry = resolve_lhp_context_entry(LHP_CONTEXT_SHELL)
    if shell_entry.apply_enabled ~= false and lhp_pose_has_bones(shell_entry.pose) then
        return shell_entry
    end
    return resolve_lhp_context_entry(LHP_CONTEXT_MAG)
end

local function apply_left_hand_pose_table(pose, factor)
    if not lhp_pose_has_bones(pose) or factor <= 0.0001 then return false end
    local tf = get_player_transform()
    if not tf then return false end
    local full = factor >= 0.9999
    for bone, target in pairs(pose) do
        if LEFT_HAND_POSE_BONE_SET[bone] and type(target) == "table" then
            local joint = sc(tf, "getJointByName", bone)
            if joint then
                local tx = tonumber(target[1]) or 0.0
                local ty = tonumber(target[2]) or 0.0
                local tz = tonumber(target[3]) or 0.0
                if full then
                    sc(joint, "set_LocalEulerAngle", Vector3f.new(tx, ty, tz))
                else
                    local cur = read_joint_local_euler(joint)
                    if cur then
                        sc(joint, "set_LocalEulerAngle", Vector3f.new(
                            lhp_lerp_angle(cur[1], tx, factor),
                            lhp_lerp_angle(cur[2], ty, factor),
                            lhp_lerp_angle(cur[3], tz, factor)))
                    end
                end
            end
        end
    end
    return true
end

local function tick_left_hand_pose_apply()
    tick_lhp_preview()
    local lhp = CFG.left_hand_pose or {}
    local master = lhp.apply_enabled == true
    local want_mag = false
    local want_slide = false
    local want_shell = false
    local want_bullet = false

    if lhp_preview.mag_hold.active then
        want_mag = true
    elseif master then
        local mh = resolve_lhp_context_entry(LHP_CONTEXT_MAG)
        if mh.apply_enabled ~= false and lhp_pose_has_bones(mh.pose) and get_mag_hand() and get_mag_hand().active then
            want_mag = true
        end
    end

    if lhp_preview.shell_hold.active then
        want_shell = true
    elseif master then
        local pose_entry = resolve_shell_hold_pose_entry()
        if pose_entry.apply_enabled ~= false and lhp_pose_has_bones(pose_entry.pose)
            and shell_in_hand_for_pose() then
            want_shell = true
        end
    end

    if lhp_preview.bullet_hold.active then
        want_bullet = true
    elseif master then
        local pose_entry = resolve_bullet_hold_pose_entry()
        if pose_entry.apply_enabled ~= false and lhp_pose_has_bones(pose_entry.pose)
            and bullet_in_hand_for_pose() then
            want_bullet = true
        end
    end

    if lhp_preview.slide_rack.active then
        want_slide = true
    elseif master then
        local sr = resolve_lhp_context_entry(LHP_CONTEXT_SLIDE)
        if sr.apply_enabled ~= false and lhp_pose_has_bones(sr.pose) then
            if rawget(_G, "__vr_slide_rack_active") == true
                or rawget(_G, "__vr_needs_rack") == true then
                want_slide = true
            end
        end
    end

    if want_mag and want_slide and not lhp_preview.mag_hold.active and not lhp_preview.slide_rack.active then
        want_slide = false
    end
    if want_shell and want_slide and not lhp_preview.shell_hold.active and not lhp_preview.slide_rack.active then
        want_slide = false
    end
    if want_shell and want_mag and not lhp_preview.shell_hold.active and not lhp_preview.mag_hold.active then
        want_mag = false
    end

    if want_bullet and want_mag and not lhp_preview.bullet_hold.active and not lhp_preview.mag_hold.active then
        want_mag = false
    end
    if want_bullet and want_shell and not lhp_preview.bullet_hold.active and not lhp_preview.shell_hold.active then
        want_shell = false
    end

    if lhp_preview.mag_hold.active or lhp_preview.slide_rack.active
        or lhp_preview.shell_hold.active or lhp_preview.bullet_hold.active then
        lhp_runtime.mag_factor = want_mag and 1.0 or 0.0
        lhp_runtime.slide_factor = want_slide and 1.0 or 0.0
        lhp_runtime.shell_factor = want_shell and 1.0 or 0.0
        lhp_runtime.bullet_factor = want_bullet and 1.0 or 0.0
    else
        lhp_update_blend(want_mag, want_slide, want_shell, want_bullet)
    end

    _G.__vr_left_hand_pose_mag_active = (lhp_runtime.mag_factor or 0) > 0.001
    _G.__vr_left_hand_pose_slide_active = (lhp_runtime.slide_factor or 0) > 0.001
    _G.__vr_left_hand_pose_shell_active = (lhp_runtime.shell_factor or 0) > 0.001
    _G.__vr_left_hand_pose_bullet_active = (lhp_runtime.bullet_factor or 0) > 0.001

    if lhp_runtime.mag_factor > 0.001 then
        local pose = resolve_lhp_context_entry(LHP_CONTEXT_MAG).pose
        apply_left_hand_pose_table(pose, lhp_runtime.mag_factor)
    end
    if lhp_runtime.shell_factor > 0.001 then
        local pose = resolve_shell_hold_pose_entry().pose
        apply_left_hand_pose_table(pose, lhp_runtime.shell_factor)
    end
    if lhp_runtime.bullet_factor > 0.001 then
        local pose = resolve_bullet_hold_pose_entry().pose
        apply_left_hand_pose_table(pose, lhp_runtime.bullet_factor)
    end
    if lhp_runtime.slide_factor > 0.001 then
        local pose = resolve_lhp_context_entry(LHP_CONTEXT_SLIDE).pose
        apply_left_hand_pose_table(pose, lhp_runtime.slide_factor)
    end
end

    function M.on_late_update()
        tick_left_hand_pose_apply()
    end

    function M.on_prepare_rendering()
        tick_left_hand_pose_apply()
    end

    function M.on_tuning_restored()
        cancel_lhp_preview(nil)
        lhp_ui.status = "Restored saved finger pose tuning"
    end

end


function M.init(deps)
    if deps and deps.CFG then
        Drop.init({ CFG = deps.CFG })
    end
    init_audio(deps)
    init_lhp(deps)
end

package.loaded["re2_vr_reload_ext_5"] = M
return M
