-- Read-only local-client telemetry. No events, tasks, entities or saved state.
-- player_common adds areaaware before its non-master return. Its cached area
-- contains topology id/tags (components/areaaware.lua:GetCurrentArea).
local Environment = {}

local DECIDUOUS_ROOMS = {
    BGDeciduous = true,
    DeepDeciduous = true,
    MagicalDeciduous = true,
    DeciduousMole = true,
    MolesvilleDeciduous = true,
    DeciduousClearing = true,
}

-- Optional client APIs can be absent or replaced by another mod. Failed reads
-- contribute no evidence, so an old/custom player falls back to its shard.
local function Read(object, method, ...)
    local kind = type(object)
    if (kind ~= "table" and kind ~= "userdata") or type(object[method]) ~= "function" then return nil end
    local ok, a, b, c = pcall(object[method], object, ...)
    if ok then return a, b, c end
end

local function HasAreaTag(area, tag)
    if type(area) ~= "table" or type(area.tags) ~= "table" then return false end
    for _, value in ipairs(area.tags) do
        if value == tag then return true end
    end
    return false
end

local function IsDeciduousArea(area)
    if type(area) ~= "table" or type(area.id) ~= "string" then return false end
    -- storygen uses numeric room IDs and BG_<n> for background rooms. Exact room
    -- identity survives terraforming and avoids planted trees/turf as proxies.
    local room = area.id:match("^[^:]+:%d+:([%w_]+)$")
        or area.id:match("^[^:]+:BG_%d+:([%w_]+)$")
    return DECIDUOUS_ROOMS[room] == true
end

local function Region(player, world, cave)
    local area = Read(player.components and player.components.areaaware, "GetCurrentArea")
    if cave then
        if HasAreaTag(area, "Atrium") then return "atrium" end
        if HasAreaTag(area, "Nightmare") then return "ruins" end
        return "cave"
    end
    -- These two tags are also consumed by the original dynamicmusic component.
    if HasAreaTag(area, "lunacyarea") then return "lunar" end
    local x, _, z = Read(player.Transform, "GetWorldPosition")
    if type(x) == "number" and type(z) == "number" then
        -- allow_boats=true classifies the sea below a boat. Map excludes visual
        -- land overhangs itself. This says nothing about being underwater.
        if Read(world.Map, "IsOceanAtPoint", x, 0, z, true) == true then return "ocean" end
    end
    if IsDeciduousArea(area) then return "forest" end
    return "surface"
end

function Environment.Sample(player, world)
    -- Loading/migration/disconnect must let the backend sample expire by TTL.
    if Read(player, "IsValid") ~= true or Read(world, "IsValid") ~= true then return nil end
    local state = type(world.state) == "table" and world.state or {}
    local raining = state.israining == true or state.isacidraining == true
    local rain = raining and (tonumber(state.precipitationrate) or 0) or 0
    if rain ~= rain or rain == math.huge or rain == -math.huge then rain = 0 end
    rain = math.max(0, math.min(1, rain))
    local cave = Read(world, "HasTag", "cave") == true
    return {
        water = false,
        cave = cave,
        indoor = false,
        rain = rain,
        region = Region(player, world, cave),
    }
end

return Environment
