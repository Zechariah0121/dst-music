"""Execute real telemetry Lua in Lua 5.1, with bounded client API stubs.

This tests classification contracts, not a networked DST client session.
"""
import argparse
from pathlib import Path
from zipfile import ZipFile
from lupa.lua51 import LuaRuntime

parser = argparse.ArgumentParser()
parser.add_argument("--scripts-zip", help="Also run the installed areaaware/Class contract")
args = parser.parse_args()
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().Environment = lua.execute(
    (Path(__file__).resolve().parents[1] / "scripts/dangomusic_environment.lua").read_text(encoding="utf-8"))
lua.execute(r'''
local area, cave, ocean, mapcalls = nil, false, false, 0
local valid = function() return true end
local player = {IsValid=valid,components={areaaware={GetCurrentArea=function() return area end}},
    Transform={GetWorldPosition=function() return 2, 3, 4 end}}
local world = {IsValid=valid,HasTag=function(_,tag) return tag=='cave' and cave end,
    state={},Map={IsOceanAtPoint=function(_,x,y,z,allow_boats)
        assert(x==2 and y==0 and z==4 and allow_boats==true)
        mapcalls=mapcalls+1; return ocean
    end}}
local function Check(region, rain)
    local result = Environment.Sample(player,world)
    assert(result.region==region, 'expected '..region..', got '..result.region)
    assert(result.cave==cave and result.rain==(rain or 0))
    assert(result.water==false and result.indoor==false)
    local fields=0; for _ in pairs(result) do fields=fields+1 end
    assert(fields==5)
    return result
end
Check('surface')
world.state={israining=true,precipitationrate=.65}
area={tags={'lunacyarea'},id='Task:1:DeepDeciduous'}
ocean=true
Check('lunar',.65)
area=nil
Check('ocean',.65)
ocean=false
for _,room in ipairs({'DeepDeciduous','MagicalDeciduous','DeciduousMole',
    'MolesvilleDeciduous','DeciduousClearing','BGDeciduous'}) do
    area={id='Task:3:'..room}; Check('forest',.65)
end
area={id='Task:BG_12:BGDeciduous'};Check('forest',.65)
-- Exact identities: substrings and similarly named custom rooms do not match.
for _,id in ipairs({'DeepDeciduous','Task:1:DeepDeciduousCustom','Task:1:CustomDeciduous',
    'Task:bogus:DeepDeciduous','Task:1:DeepDeciduous:extra'}) do
    area={id=id}; Check('surface',.65)
end
-- A planted tree, tree shelter, boat or laid turf supplies no region evidence.
player.HasTag=function() return true end
player.components.rainimmunity={}; player.components.sheltered={}
world.Map.GetTileAtPoint=function() error('terrain alone must not define a biome') end
area={id='Task:2:Plain',tags={'Mist','ExitPiece'}}
Check('surface',.65)
cave=true
area={tags={'Nightmare','Atrium','lunacyarea'}}
local previouscalls=mapcalls
Check('atrium',.65)
assert(mapcalls==previouscalls,'caves do not query sea')
area={tags={'Nightmare'}};Check('ruins',.65)
area={tags={'lunacyarea'},id='Task:1:DeepDeciduous'};Check('cave',.65)
area=nil;Check('cave',.65)
cave=false
area={tags={'Atrium','Nightmare'}};Check('surface',.65)
-- Missing/foreign area data never retains a previous region.
for _,data in ipairs({false,1,'invalid',{id=false,tags='Nightmare'}}) do
    area=data;Check('surface',.65)
end
player.components.areaaware.GetCurrentArea=function() error('custom component unavailable') end
Check('surface',.65)
player.components=nil;Check('surface',.65)
world.Map=nil;player.Transform=nil;Check('surface',.65)
world.HasTag=nil;Check('surface',.65)
-- Rain is independent of all classifications and rejects invalid numbers.
for _,value in ipairs({-1,0,1,4,math.huge,-math.huge,0/0,'invalid'}) do
    world.state={israining=true,precipitationrate=value}
    local expected=type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
        and math.max(0,math.min(1,value)) or 0
    Check('surface',expected)
end
world.state={issnowing=true,precipitationrate=.8};Check('surface')
world.state={isacidraining=true,precipitationrate='.4'};Check('surface',.4)
world.state=nil;Check('surface')
world.state='bad';Check('surface')
assert(Environment.Sample(nil,world)==nil and Environment.Sample(player,nil)==nil)
player.IsValid=function() return false end
assert(Environment.Sample(player,world)==nil)
player.IsValid=valid;world.IsValid=function() return false end
assert(Environment.Sample(player,world)==nil)
world.IsValid=nil;assert(Environment.Sample(player,world)==nil)
-- No state survives a migration: a new player/world gives only its own snapshot.
local nextworld={IsValid=valid,HasTag=function() return true end,state={}}
assert(Environment.Sample({IsValid=valid},nextworld).region=='cave')
assert(Environment.Sample({IsValid=valid},{IsValid=valid}).region=='surface')
''')
print("PASS: environment Lua 5.1 regions/priority, independent rain, missing APIs, migration and bounded reads")

if args.scripts_zip:
    with ZipFile(args.scripts_zip) as archive:
        lua.execute(archive.read("scripts/class.lua").decode("utf-8-sig"))
        lua.execute(r'''
        function Vector3(x,y,z) return {x=x,y=y,z=z} end
        function distsq(x,z,a,b) return (x-a)^2+(z-b)^2 end
        ''')
        lua.globals().AreaAware = lua.execute(
            archive.read("scripts/components/areaaware.lua").decode("utf-8-sig"))
    lua.execute(r'''
    local x=0
    local player={components={},IsValid=function() return true end,
        Transform={GetWorldPosition=function() return x,0,0 end},
        StartUpdatingComponent=function() end,ListenForEvent=function() end,
        PushEvent=function() end}
    TheWorld={IsValid=function() return true end,HasTag=function() return false end,
        topology={ids={'Plain:1:Plain','Island:1:Moon'}},state={},
        Map={FindVisualNodeAtPoint=function(_,px)
            if px>=2 then return nil,nil end
            local index=px>.1 and 2 or 1
            return {tags=index==2 and {'lunacyarea'} or {}},index
        end}}
    player.components.areaaware=AreaAware(player)
    local aware=player.components.areaaware
    aware:SetUpdateDist(.45)
    assert(Environment.Sample(player,TheWorld).region=='surface')
    aware:OnUpdate(0)
    assert(aware:GetCurrentArea().id=='Plain:1:Plain')
    x=.2;aware:OnUpdate(0)
    assert(Environment.Sample(player,TheWorld).region=='surface','original area cache has movement threshold')
    x=.6;aware:OnUpdate(0)
    assert(Environment.Sample(player,TheWorld).region=='lunar')
    x=2;aware:OnUpdate(0)
    assert(aware:GetCurrentArea()==nil and Environment.Sample(player,TheWorld).region=='surface')
    ''')
    print("PASS: installed Class/areaaware position threshold, area id/tags, missing-node fallback in Lua 5.1")
