if _RE2CharacterLib ~= nil then
    return _RE2CharacterLib
end

local CHAR = {}

local PROFILE_LEON = "leon"
local PROFILE_CLAIRE = "claire"
local PROFILE_ADA = "ada"
local PROFILE_HUNK = "hunk"
local PROFILE_TOFU = "tofu"
local PROFILE_CARLOS = "carlos"
local PROFILE_JILL = "jill"

CHAR.PROFILE_LEON = PROFILE_LEON
CHAR.PROFILE_CLAIRE = PROFILE_CLAIRE
CHAR.PROFILE_ADA = PROFILE_ADA
CHAR.PROFILE_HUNK = PROFILE_HUNK
CHAR.PROFILE_TOFU = PROFILE_TOFU
CHAR.PROFILE_CARLOS = PROFILE_CARLOS
CHAR.PROFILE_JILL = PROFILE_JILL

CHAR.ALL_PROFILE_KEYS = {
    PROFILE_LEON,
    PROFILE_CLAIRE,
    PROFILE_ADA,
    PROFILE_HUNK,
    PROFILE_TOFU,
    PROFILE_CARLOS,
    PROFILE_JILL,
}

local ALIAS_TO_PROFILE = {
    leon = PROFILE_LEON,
    claire = PROFILE_CLAIRE,
    ada = PROFILE_ADA,
    hunk = PROFILE_HUNK,
    tofu = PROFILE_TOFU,
    carlos = PROFILE_CARLOS,
    jill = PROFILE_JILL,
}

local RE2_PL_MAP = {
    pl0000 = PROFILE_LEON,
    pl1000 = PROFILE_CLAIRE,
    pl2000 = PROFILE_ADA,
    pl4000 = PROFILE_HUNK,
    pl4100 = PROFILE_TOFU,
}

local POSE_FALLBACK = {
    [PROFILE_ADA] = PROFILE_CLAIRE,
    [PROFILE_HUNK] = PROFILE_LEON,
    [PROFILE_TOFU] = PROFILE_LEON,
    [PROFILE_CARLOS] = PROFILE_LEON,
    [PROFILE_JILL] = PROFILE_CLAIRE,
}

function CHAR.extract_pl_id(name)
    if type(name) ~= "string" then return nil end
    name = name:lower()
    local pl_id = name:match("(pl%d%d%d%d)")
    if pl_id then return pl_id end
    return nil
end

function CHAR.map_pl_id_to_profile(pl_id)
    if type(pl_id) ~= "string" then return nil end
    pl_id = pl_id:lower()
    local mapped = RE2_PL_MAP[pl_id]
    if mapped then return mapped end
    if pl_id:find("^pl10", 1, true) then
        return PROFILE_CLAIRE
    end
    return nil
end

function CHAR.normalize_profile_name(raw)
    if raw == nil then
        return CHAR.get_default_profile_key()
    end
    local name = tostring(raw):lower()
    if ALIAS_TO_PROFILE[name] then
        return ALIAS_TO_PROFILE[name]
    end
    for alias, profile in pairs(ALIAS_TO_PROFILE) do
        if name:find(alias, 1, true) then
            return profile
        end
    end
    local pl_id = CHAR.extract_pl_id(name)
    if pl_id then
        local mapped = CHAR.map_pl_id_to_profile(pl_id)
        if mapped then return mapped end
    end
    if name:find("pl1000", 1, true) or name:find("pl10", 1, true) then
        return PROFILE_CLAIRE
    end
    return CHAR.get_default_profile_key()
end

function CHAR.get_default_profile_key()
    return PROFILE_LEON
end

function CHAR.get_pose_fallback_profile(profile)
    profile = CHAR.normalize_profile_name(profile)
    local fallback = POSE_FALLBACK[profile]
    if fallback then return fallback end
    return CHAR.get_default_profile_key()
end

function CHAR.is_known_profile_key(key)
    if type(key) ~= "string" then return false end
    for _, known in ipairs(CHAR.ALL_PROFILE_KEYS) do
        if known == key then return true end
    end
    return false
end

function CHAR.profile_key_from_name(name)
    return CHAR.normalize_profile_name(name)
end

function CHAR.get_active_profile_key(player)
    local vr_char = rawget(_G, "__vr_active_char")
    if vr_char ~= nil then
        return CHAR.normalize_profile_name(vr_char)
    end
    if player == nil then
        local re2 = require("utility/RE2")
        player = re2.get_localplayer()
    end
    if player then
        local go_name = ""
        pcall(function() go_name = player:call("get_Name") or "" end)
        return CHAR.normalize_profile_name(go_name)
    end
    return CHAR.get_default_profile_key()
end

_RE2CharacterLib = CHAR
_G.__vr_re2_character = CHAR

return CHAR
