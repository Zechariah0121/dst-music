-- Client-only dynamic resource leases. No entity is created by these prefabs.
-- Source contract (760944): widgets/redux/modstab.lua:1368-1379 loads icon
-- ATLAS+IMAGE via a nil-fn prefab; 1324-1331 unloads then unregisters it.
local records = {}

local function Dispose(record)
    -- Only remove our own registration; never overwrite a foreign prefab.
    if Prefabs[record.name] ~= record.prefab then return end
    TheSim:UnloadPrefabs({record.name})
    TheSim:UnregisterPrefabs({record.name})
    if Prefabs[record.name] == record.prefab then Prefabs[record.name] = nil end
end

local Assets = Class(function(self, modroot)
    assert(type(modroot) == "string" and #modroot > 0, "DangoMusic assets require modroot")
    self.modroot = modroot:sub(-1) == "/" and modroot or (modroot.."/")
    self.leases = {}
end)

local function Validate(descriptor)
    if type(descriptor) ~= "table" or type(descriptor.atlas) ~= "string"
        or type(descriptor.image) ~= "string" then return nil end
    local hash = descriptor.atlas:match("^images/music_cache/([a-f0-9]+)%.xml$")
    if hash == nil or #hash ~= 64 or descriptor.image ~= hash..".tex" then return nil end
    return hash
end

function Assets:Acquire(descriptor)
    if self.closed then return nil, "ASSET_MANAGER_CLOSED" end
    if TheNet ~= nil and TheNet:IsDedicated() then return nil, "ASSET_CLIENT_ONLY" end
    local hash = Validate(descriptor)
    if hash == nil then return nil, "ASSET_DESCRIPTOR_INVALID" end
    local atlas = self.modroot..descriptor.atlas
    local texture = self.modroot.."images/music_cache/"..descriptor.image
    local record = records[atlas]
    if record == nil then
        -- Verify both files before registering. The bridge publishes the XML
        -- last, but a removed installation must still fail without an assert.
        local resolvedAtlas = resolvefilepath_soft(atlas)
        local resolvedTexture = resolvefilepath_soft(texture)
        if resolvedAtlas == nil or resolvedTexture == nil then return nil, "ASSET_FILE_MISSING" end
        local name = "dangomusic_cache_"..hash
        if Prefabs[name] ~= nil then return nil, "ASSET_PREFAB_CONFLICT" end
        local prefab = Prefab(name, nil, {
            Asset("ATLAS", resolvedAtlas),
            Asset("IMAGE", resolvedTexture),
        }, nil)
        record = {name=name, prefab=prefab, refs=0}
        local ok = pcall(function()
            RegisterSinglePrefab(prefab)
            TheSim:LoadPrefabs({name})
            -- SetTexture does not load files; reject a missing resource/element
            -- here instead of handing an invalid handle to the UI widget.
            assert(TheSim:AtlasContains(resolvedAtlas, descriptor.image))
        end)
        if not ok then
            pcall(Dispose, record)
            return nil, "ASSET_RESOURCE_LOAD_FAILED"
        end
        records[atlas] = record
    end
    record.refs = record.refs + 1
    local manager = self
    local lease = {atlas=descriptor.atlas, image=descriptor.image}
    function lease:Release()
        if self.released then return end
        self.released = true
        manager.leases[self] = nil
        record.refs = record.refs - 1
        if record.refs == 0 then
            Dispose(record)
            records[atlas] = nil
        end
    end
    self.leases[lease] = true
    return lease
end

-- Call after all widgets displaying these leases have been killed or switched
-- to another texture. Releasing while an Image still draws it is unsafe.
function Assets:Close()
    if self.closed then return end
    self.closed = true
    local leases = {}
    for lease in pairs(self.leases) do leases[#leases+1] = lease end
    for _, lease in ipairs(leases) do lease:Release() end
end

return Assets
