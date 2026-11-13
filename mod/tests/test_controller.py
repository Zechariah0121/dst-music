"""Offline tests of the real Controller using a clock, scheduler and Bridge stub.

Uses the installed game's Class implementation; does not run DST or real HTTP.
"""
import argparse
from pathlib import Path
from zipfile import ZipFile
from lupa.lua51 import LuaRuntime

parser = argparse.ArgumentParser()
parser.add_argument("--scripts-zip", required=True)
args = parser.parse_args()
lua = LuaRuntime(unpack_returned_tuples=True)
with ZipFile(args.scripts_zip) as archive:
    lua.execute(archive.read("scripts/class.lua").decode("utf-8-sig"))
lua.execute(r'''
now = 0
function GetStaticTime() return now end
package.preload.dangomusic_assets = function()
    return Class(function(self)
        self.Acquire=function(_,descriptor)
            if not descriptor then return nil end
            return {atlas=descriptor.atlas,image=descriptor.image,Release=function(lease) lease.released=true end}
        end
        self.Close=function(s) s.closed=true end
    end)
end
package.preload.dangomusic_bridge = function()
    local Bridge = Class(function(self,inst,connection) self.requests={}; self.connection=connection end)
    Bridge.Escape = function(value) return tostring(value) end
    function Bridge:IsConfigured() return self.connection and self.connection.token~=nil end
    function Bridge:Request(path, method, body, cb)
        assert(not self.closed, 'Controller sent after close')
        self.requests[#self.requests+1]={path=path,method=method,body=body,cb=cb}
    end
    function Bridge:Close()
        self.closed=true
        for _, req in ipairs(self.requests) do req.cb=nil end
    end
    return Bridge
end
function Inst()
    return {tasks={},DoPeriodicTask=function(self, period, fn)
        local task={period=period,fn=fn,Cancel=function(self) self.cancelled=true end}
        self.tasks[#self.tasks+1]=task
        return task
    end}
end
function Count(c,path)
    local count=0
    for _, req in ipairs(c.bridge.requests) do if req.path==path then count=count+1 end end
    return count
end
function Pending(c,path)
    for _, req in ipairs(c.bridge.requests) do
        if req.path==path and not req.done then return req end
    end
    error('No pending request: '..path)
end
function Reply(c,path,data,err)
    local req=Pending(c,path)
    req.done=true
    if req.cb then req.cb(data,err) end
end
function State(id,position,playing,revision)
    return {ok=true,playerConnected=true,settingsRevision=revision or 1,
        player={track=id and {id=id,duration=20},position=position or 10,duration=20,
        playing=playing~=false,volume=.6}}
end
function Status(c,id,position,playing,revision)
    c:Poll()
    Reply(c,'/api/status',State(id,position,playing,revision))
end
''')
lua.globals().package.path = str(Path(__file__).resolve().parents[1] / "scripts" / "?.lua").replace("\\", "/") + ";" + lua.globals().package.path
lua.globals().Controller = lua.execute(
    (Path(__file__).resolve().parents[1] / "scripts/dangomusic_controller.lua").read_text(encoding="utf-8"))
lua.execute(r'''
-- Poll/position clock and old lyric versions.
local inst=Inst()
local c=Controller(inst,{},'mod/')
assert(#inst.tasks==2 and inst.tasks[1].period==.7 and inst.tasks[2].period==1.5)
assert(Count(c,'/api/environment')==0, 'no player: TTL must expire naturally')
c:Poll(); assert(Count(c,'/api/status')==1, 'no concurrent status requests')
Reply(c,'/api/settings',{settings={language='zh'},settingsRevision=1,schema={language={}}})
local notices=0
local unsubscribe=c:Subscribe(function() notices=notices+1 end)
Reply(c,'/api/status',State('A'))
assert(c:GetPosition()==10 and c.trackID=='A')
now=2
assert(c:GetPosition()==12)
now=100
assert(c:GetPosition()==20, 'position clamps to duration')
now=2
Status(c,'B',4,false)
assert(c:GetPosition()==4 and c.lyricsPending)
Reply(c,'/api/lyrics?trackId=A',{lines={{text='obsolete'}},timing='line'})
assert(#c:GetLyrics().lines==0 and c.lyricsPending, 'old lyrics cannot overwrite new track')
Reply(c,'/api/lyrics?trackId=B',nil,'temporary failure')
assert(c.lyricsRetryAt==12 and c:GetLyrics().error=='temporary failure')
now=11
Status(c,'B',5,false)
assert(Count(c,'/api/lyrics?trackId=B')==1)
now=12
Status(c,'B',5,true)
assert(Count(c,'/api/lyrics?trackId=B')==2 and c.lyricsPending)
Status(c,'B',5,true)
assert(Count(c,'/api/lyrics?trackId=B')==2, 'retry remains single flight')
Reply(c,'/api/lyrics?trackId=B',nil,'still unavailable')
assert(c.lyricsRetryAt==32, 'failure backs off to twenty seconds')
now=31; Status(c,'B')
assert(Count(c,'/api/lyrics?trackId=B')==2)
now=32; Status(c,'B')
Reply(c,'/api/lyrics?trackId=B',{lines={{text='current'}},timing='line'})
assert(c:GetLyrics().lines[1].text=='current' and c.lyricsRetryAt==nil)
now=33
c:Poll(); Reply(c,'/api/status',nil,'offline')
now=35
assert(c:GetPosition()==10 and not c:GetState().playerConnected)
unsubscribe()
local oldnotices=notices
c:Notify(); assert(notices==oldnotices)
local late=Pending(c,'/api/artwork?trackId=A').cb
local requestCount=#c.bridge.requests
c:Close(); c:Close()
late({asset={atlas='images/music_cache/a.xml',image='a.tex'}})
c:Poll(); c:Command({action='pause'}); c:SetSettings({a=1}); c:SampleEnvironment()
assert(#c.bridge.requests==requestCount and c.closed and c.inst==nil)
assert(inst.tasks[1].cancelled and inst.tasks[2].cancelled and c.bridge.closed)
assert(next(c.listeners)==nil and next(c.artworkDescriptors)==nil, 'close releases owner state')

-- Settings failures retry on status revision mismatch with a ten second gate.
-- Rapid scrolling must not burst 18 cover compilers or queue stale rows.
local glyph=Controller(Inst(),{},'mod/')
Reply(glyph,'/api/status',State('first'))
Reply(glyph,'/api/lyrics?trackId=first',{lines={{text='A'}},timing='line'})
assert(glyph.glyphsPending and glyph:GetLyricGlyphs()==nil)
Status(glyph,'second')
Reply(glyph,'/api/lyrics?trackId=second',{lines={{text='B'}},timing='line'})
Reply(glyph,'/api/lyric-glyphs?trackId=first',{trackId='first',asset={atlas='images/music_cache/a.xml',image='a.tex'},fonts={mono={}}})
assert(glyph:GetLyricGlyphs()==nil and glyph.glyphsPending,'stale glyphs cannot replace the current track')
glyph.lastError='playback error'
Reply(glyph,'/api/lyric-glyphs?trackId=second',nil,'conversion unavailable')
assert(glyph.lastError=='playback error' and glyph:GetLyrics().lines[1].text=='B')
local retry=glyph.glyphsRetryAt
now=retry-.1;Status(glyph,'second')
assert(Count(glyph,'/api/lyric-glyphs?trackId=second')==1)
now=retry;Status(glyph,'second')
assert(Count(glyph,'/api/lyric-glyphs?trackId=second')==2)
Reply(glyph,'/api/lyric-glyphs?trackId=second',{trackId='second',asset={atlas='images/music_cache/b.xml',image='b.tex'},fonts={mono={glyphs={}}}})
assert(glyph:GetLyricGlyphs().trackId=='second' and not glyph.glyphsPending and glyph.glyphsRetryAt==nil)
local glyphData=glyph:GetLyricGlyphs()
local glyphLease=glyph:TakeLyricGlyphLease(glyphData)
assert(glyphLease and not glyphLease.released)
assert(glyph:TakeLyricGlyphLease(glyphData)==nil,'lease ownership only handed off once')
assert(next(glyph.assetLeases)==nil,'song glyph atlases must not accumulate in permanent artwork cache')
Status(glyph,'third')
assert(glyph:GetLyricGlyphs()==nil)
assert(not glyphLease.released,'renderer releases only after destroying old sprites')
glyphLease:Release()
Reply(glyph,'/api/lyrics?trackId=third',{lines={{text='C'}},timing='line'})
local lateGlyph=Pending(glyph,'/api/lyric-glyphs?trackId=third').cb
glyph:Close();lateGlyph({trackId='third',asset={},fonts={}})
assert(glyph:GetLyricGlyphs()==nil and not glyph.glyphsPending)

local covers=Controller(Inst(),{},'mod/')
for id=1,18 do covers:RequestArtwork("trackId",id) end
assert(covers.artworkPendingCount==2)
assert(Count(covers,'/api/artwork?trackId=1')==1)
assert(Count(covers,'/api/artwork?trackId=3')==0)
Reply(covers,'/api/artwork?trackId=1',{asset={atlas='images/music_cache/a.xml',image='a.tex'}})
assert(covers.artworkPendingCount==1)
assert(covers:RequestArtwork('trackId',1).image=='a.tex')
assert(Count(covers,'/api/artwork?trackId=1')==1,'cached artwork does not re-request')
covers:RequestArtwork('trackId',18)
assert(covers.artworkPendingCount==2 and Count(covers,'/api/artwork?trackId=18')==1)
assert(Count(covers,'/api/artwork?trackId=3')==0,'stale rows were never queued')
Reply(covers,'/api/artwork?trackId=2',nil,'unavailable')
assert(covers.artworkPendingCount==1)
covers:Close()
assert(covers.artworkPendingCount==0)

now=0
local s=Controller(Inst(),{},'mod/')
Reply(s,'/api/settings',nil,'offline')
Reply(s,'/api/status',State(nil,0,false,2))
assert(Count(s,'/api/settings')==1 and s.settingsRetryAt==10)
now=9; Status(s,nil,0,false,2)
assert(Count(s,'/api/settings')==1)
now=10; Status(s,nil,0,false,2)
assert(Count(s,'/api/settings')==2)
Reply(s,'/api/settings',{settings={lyricSize=24},schema={lyricSize={}},settingsRevision=2})
assert(s:GetSettings().lyricSize==24 and s.settingsRetryAt==nil and s.settingsRevision==2)
local settingCallback=0
s:SetSettings({lyricSize=30},function(data,err) settingCallback=settingCallback+1; assert(data and not err) end)
assert(Pending(s,'/api/settings').method=='POST' and Pending(s,'/api/settings').body.lyricSize==30)
Reply(s,'/api/settings',{settings={lyricSize=30},settingsRevision=3})
assert(s:GetSettings().lyricSize==30 and settingCallback==1)
s:Close()

-- Environment is a full snapshot; rain uses replicated world state only.
now=0
ThePlayer={IsValid=function() return true end}
TheWorld={IsValid=function() return true end,HasTag=function(_,tag) return tag=='cave' end,
    state={israining=true,precipitationrate=.65}}
local e=Controller(Inst(),{},'mod/')
local env=Pending(e,'/api/environment')
assert(env.method=='POST' and env.body.cave and env.body.rain==.65)
assert(env.body.water==false and env.body.indoor==false)
assert(env.body.region=='cave')
local fields=0; for _ in pairs(env.body) do fields=fields+1 end
assert(fields==5, 'send all five supported fields')
e:SampleEnvironment(); assert(Count(e,'/api/environment')==1, 'single-flight telemetry')
e.lastError='music error'
Reply(e,'/api/environment',nil,'telemetry error')
assert(e.lastError=='music error' and not e.environmentPending)
TheWorld.state.precipitationrate=4
e.inst.tasks[2].fn()
assert(Pending(e,'/api/environment').body.rain==1)
Reply(e,'/api/environment',{ok=true})
TheWorld.state={issnowing=true,precipitationrate=.8}
e:SampleEnvironment(); assert(Pending(e,'/api/environment').body.rain==0)
Reply(e,'/api/environment',{ok=true})
TheWorld.state={isacidraining=true,precipitationrate=.4}
e:SampleEnvironment(); assert(Pending(e,'/api/environment').body.rain==.4)
Reply(e,'/api/environment',{ok=true})
TheWorld.state={israining=true,precipitationrate=0/0}
e:SampleEnvironment(); assert(Pending(e,'/api/environment').body.rain==0)
Reply(e,'/api/environment',{ok=true})
local n=Count(e,'/api/environment')
local world=TheWorld
TheWorld=nil; e:SampleEnvironment(); assert(Count(e,'/api/environment')==n)
TheWorld=world; ThePlayer=nil; e:SampleEnvironment(); assert(Count(e,'/api/environment')==n)
ThePlayer={IsValid=function() return false end}; e:SampleEnvironment()
assert(Count(e,'/api/environment')==n)
ThePlayer={IsValid=function() return true end}
e:SampleEnvironment()
assert(Pending(e,'/api/environment').body.region=='cave')
Reply(e,'/api/environment',{ok=true})
-- The next shard/player replaces all region evidence, including after no player.
TheWorld={IsValid=function() return true end,HasTag=function() return false end,state={}}
ThePlayer={IsValid=function() return true end,
    components={areaaware={GetCurrentArea=function() return {tags={'lunacyarea'}} end}}}
e:SampleEnvironment()
assert(Pending(e,'/api/environment').body.region=='lunar')
assert(Pending(e,'/api/environment').body.cave==false)
Reply(e,'/api/environment',{ok=true})
ThePlayer=nil
e:SampleEnvironment()
ThePlayer={IsValid=function() return true end}
e:SampleEnvironment()
assert(Pending(e,'/api/environment').body.region=='surface','no previous shard or player cache')
local latetelemetry=Pending(e,'/api/environment').cb
e:Close()
latetelemetry({ok=true})
assert(e.environmentPending==false and e.environmenttask==nil and e.polltask==nil)
-- A settings GET launched first must not undo a later successful POST.
local race=Controller(Inst(),{},'mod/')
local oldGet=Pending(race,'/api/settings'); oldGet.done=true
race:SetSettings({player={musicSource=1}})
Reply(race,'/api/settings',{settings={player={musicSource=1}},settingsRevision=2})
oldGet.cb({settings={player={musicSource=0}},settingsRevision=1,schema={player={}}})
assert(race.settings.player.musicSource==1 and race.settingsRevision==2 and race.state.provider=='qq',
    'late settings GET must not undo successful source write')
assert(Count(race,'/api/settings')==3,'discarded GET must be retried to load schema')
Reply(race,'/api/settings',{settings={player={musicSource=1}},settingsRevision=2,schema={player={musicSource={}}}})
assert(race.schema.player.musicSource and race.settings.player.musicSource==1)
race:Close()
-- A status response sent before a successful source write cannot restore its old account.
local switching=Controller(Inst(),{},'mod/')
Reply(switching,'/api/settings',{settings={player={musicSource=0}},settingsRevision=1})
switching:SetSettings({player={musicSource=1}})
Reply(switching,'/api/settings',{settings={player={musicSource=1}},settingsRevision=2})
assert(switching.state.provider=='qq' and switching.state.account==nil)
local stale=State('netease-track');stale.provider='netease';stale.account={nickname='old'}
Reply(switching,'/api/status',stale)
assert(switching.state.provider=='qq' and switching.state.account==nil and Count(switching,'/api/status')==2)
local fresh=State('netease-track',0,true,2);fresh.provider='qq';fresh.account={nickname='new'}
Reply(switching,'/api/status',fresh)
assert(switching.state.provider=='qq' and switching.state.account.nickname=='new' and switching.trackID=='netease-track')
switching:Close()
-- Catalog is controller-owned, coalesces requests and fences account changes.
local cache=Controller(Inst(),{},'mod/')
cache:ObserveCatalogAccount('netease',{id='one'})
local data,pending=cache:GetCatalog('netease','recommend')
assert(not data and pending)
local path='/api/discover?section=recommend&provider=netease'
local first=Pending(cache,path)
cache:GetCatalog('netease','recommend');assert(Count(cache,path)==1,'pending requests must coalesce')
Reply(cache,path,{playlists={{id='p1'}}})
data,pending=cache:GetCatalog('netease','recommend')
assert(data[1].id=='p1' and not pending and Count(cache,path)==1,'reopen within TTL must use cache')
now=now+301;data,pending=cache:GetCatalog('netease','recommend')
assert(data[1].id=='p1' and pending,'stale cache must remain visible while refreshing')
Reply(cache,path,nil,'offline');data,pending=cache:GetCatalog('netease','recommend')
assert(data[1].id=='p1' and not pending,'failed refresh must retain data')
cache:GetCatalog('netease','recommend',true);local old=Pending(cache,path);old.done=true
cache:ObserveCatalogAccount('netease',{id='two'})
old.cb({playlists={{id='wrong-account'}}})
data=cache:GetCatalog('netease','recommend');assert(data==nil,'late response must not cross accounts')
Reply(cache,path,{playlists={{id='p2'}}})
cache:ObserveCatalogAccount('qq',{id='one'})
assert(cache:GetCatalog('qq','recommend')==nil,'identical IDs from different providers must remain separate')
Reply(cache,'/api/discover?section=recommend&provider=qq',{playlists={{id='q1'}}})
assert(cache:GetCatalog('netease','recommend')[1].id=='p2')
cache:InvalidateCatalog('netease');assert(cache:GetCatalog('netease','recommend')==nil,'logout invalidates account cache')
cache:ObserveCatalogAccount('netease',{id='two'})
assert(cache:GetCatalog('netease','recommend')==nil,'re-login must refetch')
local late=Pending(cache,path).cb
cache:Close();late({playlists={{id='late'}}})
assert(next(cache.catalog)==nil,'HUD close clears cache and ignores late response')
-- Browsing caches bounded descriptors, not a persistent native lease per cover.
local artwork=Controller(Inst(),{},'mod/')
for i=1,260 do
 local id=tostring(i);assert(artwork:RequestArtwork('playlistId',id)==nil)
 Reply(artwork,'/api/artwork?playlistId='..id,{asset={atlas='images/music_cache/a'..id..'.xml',image='a'..id..'.tex'}})
end
assert(#artwork.artworkOrder==256 and artwork:PeekArtwork('playlistId','1')==nil)
assert(next(artwork.assetLeases)==nil,'browsing alone must not pin all textures')
local lease=artwork:AcquireArtwork(artwork:PeekArtwork('playlistId','260'));assert(lease);lease:Release();assert(lease.released)
artwork:Close()
-- Reload a generated connection after the game has already entered a world.
local nextConnection=nil
local reconnect=Controller(Inst(),{},'mod/',function() return nextConnection end)
Reply(reconnect,'/api/settings',{settings={player={musicSource=1}},settingsRevision=1})
Reply(reconnect,'/api/status',nil,'offline')
assert(reconnect.backendConnected==false)
local oldBridge=reconnect.bridge
local reconnectData,reconnectError
nextConnection={token='new-local-token'}
reconnect:Reconnect(function(data,err) reconnectData=data; reconnectError=err end)
assert(oldBridge.closed and reconnect.bridge~=oldBridge and reconnect.reconnecting)
assert(reconnect.backendConnected==nil and reconnect.artworkPendingCount==0)
Reply(reconnect,'/api/settings',{settings={player={musicSource=1,showTopLeftButton=false}},settingsRevision=2})
local connected=State(nil,0,false,2); connected.playerConnected=false; connected.provider='qq'
Reply(reconnect,'/api/status',connected)
assert(reconnectData==connected and reconnectError==nil and not reconnect.reconnecting)
assert(reconnect.backendConnected==true and reconnect.state.playerConnected==false,
    'backend online and native audio online are different states')
reconnect:Poll(); Reply(reconnect,'/api/status',{ok=true})
assert(reconnect.backendConnected==false and reconnect.lastError,
    'malformed status must not look like a successful reconnect')
nextConnection=nil; oldBridge=reconnect.bridge
reconnect:Reconnect(function(data,err) assert(data==nil and err) end)
assert(reconnect.bridge==oldBridge and not oldBridge.closed,'missing new file must not destroy the old connection')
reconnect:OpenModFolder(function(data,err) assert(data.ok and not err) end)
assert(next(Pending(reconnect,'/api/open-mod-folder').body)==nil)
Reply(reconnect,'/api/open-mod-folder',{ok=true})
reconnect:Close()
''')
print("PASS: Controller lyric versions/backoff, close/late callbacks, settings retry/write, position clock, telemetry")
