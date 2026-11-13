"""Lua ownership/ordering contract tests; not a replacement for game rendering."""
from pathlib import Path
from lupa.lua51 import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(r'''
function Class(init)
    local cls = {}; cls.__index = cls
    return setmetatable(cls, {__call=function(_, ...)
        local obj = setmetatable({}, cls); init(obj, ...); return obj
    end})
end
Prefabs = {}; events = {}; existing = true; fail_load = false
function event(value) events[#events+1] = value end
function resolvefilepath_soft(path) if existing then return path end end
function Asset(kind, file) return {type=kind, file=file} end
function Prefab(name, fn, assets) assert(fn == nil); return {name=name, fn=fn, assets=assets} end
function RegisterSinglePrefab(prefab)
    assert(Prefabs[prefab.name] == nil)
    assert(prefab.assets[1].type == 'ATLAS' and prefab.assets[2].type == 'IMAGE')
    assert(prefab.assets[1].file:match('^../mods/local_netease_music/images/music_cache/'))
    Prefabs[prefab.name] = prefab; event('register')
end
TheNet = {IsDedicated=function() return false end}
TheSim = {
    LoadPrefabs=function(_, names) assert(Prefabs[names[1]]); event('load') end,
    AtlasContains=function(_, atlas, image) event('contains'); return not fail_load end,
    UnloadPrefabs=function(_, names) event('unload') end,
    UnregisterPrefabs=function(_, names) event('unregister') end,
}
''')
lua.globals().Assets = lua.execute((root / 'mod/scripts/dangomusic_assets.lua').read_text(encoding='utf-8'))
lua.execute(r'''
local hash = string.rep('a', 64)
local desc = {atlas='images/music_cache/'..hash..'.xml', image=hash..'.tex'}
local one = Assets('../mods/local_netease_music/')
local two = Assets('../mods/local_netease_music/')
local lease = assert(one:Acquire(desc))
assert(lease.atlas == desc.atlas and lease.image == desc.image)
assert(table.concat(events, ',') == 'register,load,contains')
local second = assert(two:Acquire(desc))
assert(#events == 3) -- one native load, two independent ownership scopes
one:Close(); one:Close(); lease:Release()
assert(#events == 3) -- second widget scope still holds it
two:Close()
assert(table.concat(events, ',') == 'register,load,contains,unload,unregister')
assert(next(Prefabs) == nil)
assert(one:Acquire(desc) == nil)
local fresh = Assets('../mods/local_netease_music/')
assert(fresh:Acquire({atlas='../outside.xml',image='a.tex'}) == nil)
assert(#events == 5)
existing = false
assert(fresh:Acquire(desc) == nil)
assert(#events == 5)
existing = true; fail_load = true
local bad, err = fresh:Acquire(desc)
assert(bad == nil and err == 'ASSET_RESOURCE_LOAD_FAILED')
assert(next(Prefabs) == nil)
assert(table.concat(events, ','):match('register,load,contains,unload,unregister$'))
fail_load = false
local conflict = {foreign=true}; Prefabs['dangomusic_cache_'..hash] = conflict
local missing, reason = fresh:Acquire(desc)
assert(missing == nil and reason == 'ASSET_PREFAB_CONFLICT')
assert(Prefabs['dangomusic_cache_'..hash] == conflict)
''')
print('PASS Lua 5.1 assets: nil-fn resource prefab, load/verify ordering, shared leases, cleanup, invalid/missing assets, load failure, foreign ownership')
