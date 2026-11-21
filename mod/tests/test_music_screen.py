"""Lua 5.1 screen contracts with real vanilla TrueScrollList/Area and grid factory.
UI/entity services are stubs: this verifies caching/lifecycle/virtualization, not pixels.
"""
import argparse
from pathlib import Path
from zipfile import ZipFile
from lupa.lua51 import LuaRuntime
parser=argparse.ArgumentParser()
parser.add_argument("--scripts-zip",required=True)
args=parser.parse_args()
z=ZipFile(args.scripts_zip)
lua=LuaRuntime(unpack_returned_tuples=True)
lua.execute(z.read("scripts/class.lua").decode("utf-8-sig"))
lua.execute(r"""
DEFAULTFONT='opensans'; CHATFONT='chat'; UIFONT='ui'; BRANCH='release'
ANCHOR_LEFT=1; ANCHOR_MIDDLE=2; ANCHOR_RIGHT=3; SCALEMODE_FILLSCREEN=1
CONTROL_SCROLLFWD=10; CONTROL_SCROLLBACK=11; CONTROL_CANCEL=12
CONTROL_ACCEPT=13; CONTROL_MOVE_LEFT=14; CONTROL_MOVE_RIGHT=15
MOVE_UP=1; MOVE_DOWN=2
MOUSEBUTTON_LEFT=1; KEY_ESCAPE=27; KEY_DELETE=127
local time=0
function GetStaticTime() return time end
function Lerp(a,b,t) return a+(b-a)*t end
function math.clamp(v,a,b) return math.max(a,math.min(b,v)) end
function ClickMouseoverSoundReduction() return 1 end
TheInput={ResolveVirtualControls=function(_,c) return c end,ControllerAttached=function() return false end,GetControllerID=function() return 0 end,AddMoveHandler=function() return {Remove=function() end} end,GetScreenPosition=function() return {x=0,y=0} end}
TheFrontEnd={DoHoverFocusUpdate=function() end,LockFocus=function() end,GetActiveScreen=function() return nil end,GetSound=function() return {PlaySound=function() end} end}
metrics={string=0,truncate=0,texture=0,show=0,hide=0,scale=0}
local function noop() end
Widget=Class(function(self,name)
 self.name=name; self.children={}; self.shown=true; self.valid=true; self.enabled=true
 self.image=self; self.text=self; self.pos={x=0,y=0}
 self.inst={IsValid=function() return self.valid end,
  DoStaticPeriodicTask=function(_,p,fn) return {fn=fn,Cancel=noop} end,
  DoStaticTaskInTime=function(_,p,fn) return {fn=fn,seconds=p,Cancel=noop} end}
end)
function Widget:AddChild(w) self.children[#self.children+1]=w; w.parent=self; self.nextdraworder=(self.nextdraworder or 0)+1;w.draworder=self.nextdraworder; return w end
function Widget:SetPosition(x,y) self.pos={x=x,y=y} end
function Widget:GetPosition() return self.pos end
function Widget:GetLocalPosition() return self.pos end
function Widget:ResetPreClickPosition() end
function Widget:IsSelected() return false end
function Widget:GetWorldPosition() return self.pos end
function Widget:GetScale() return {x=1,y=1} end
function Widget:SetText(s) self.value=s end
function Widget:GetText() return self.value end
function Widget:SetString(s) metrics.string=metrics.string+1; self.value=s end
function Widget:SetTruncatedString(s) metrics.truncate=metrics.truncate+1; self.value=s end
function Widget:Show() metrics.show=metrics.show+1; self.shown=true end
function Widget:Hide() metrics.hide=metrics.hide+1; self.shown=false end
function Widget:IsVisible() return self.shown end
function Widget:Disable() self.enabled=false end
function Widget:IsEnabled() return self.enabled end
function Widget:SetOnClick(fn) self.onclick=fn end
function Widget:SetTexture(a,b) metrics.texture=metrics.texture+1; self.texture=b end
function Widget:Kill() self.valid=false; for _,c in ipairs(self.children) do c:Kill() end end
function Widget:MoveToFront() self.front=true; if self.parent then self.parent.nextdraworder=self.parent.nextdraworder+1;self.draworder=self.parent.nextdraworder end end
function Widget:SetImageNormalColour(...) self.normalColour={...} end
function Widget:SetClickable(v) self.clickable=v end
function Widget:SetScissor(x,y,w,h) self.clip={x=x,y=y,width=w,height=h} end
function Widget:OnControl() return false end
function Widget:OnRawKey() return false end
function Widget:GetRegionSize() return 100,30 end
function Widget:GetSize() return 64,64 end
function Widget:ScaleToSize() metrics.scale=metrics.scale+1 end
for _,n in ipairs({'ResetRegionSize','SetTint','MoveToBack','SetScale',
'SetVAnchor','SetHAnchor','SetScaleMode','SetRegionSize','SetHAlign','SetColour','SetTextSize','SetTextColour',
'SetTextFocusColour','SetTextDisabledColour','SetFont','SetDisabledFont','ForceImageSize',
'SetImageFocusColour','SetImageDisabledColour','SetTooltip','SetTextLengthLimit','SetIdleTextColour',
'SetEditTextColour','SetEditCursorColour','SetTextPrompt','SetForceEdit','SetEditing','SetWhileDown',
'SetOnDown','StartUpdating','StopUpdating','SetFocusChangeDir','SetFocus','OnDestroy'}) do Widget[n]=noop end
for _,n in ipairs({'widgets/widget','widgets/screen','widgets/image','widgets/text','widgets/textedit','widgets/imagebutton'}) do package.preload[n]=function() return Widget end end
Grid=Class(Widget,function(self) Widget._ctor(self,'grid') end)
function Grid:FillGrid() end
""")
# Exercise the current game's actual focus-gated Widget and ImageButton dispatch.
# Native entities and mouse hit selection remain stubs; this is not a visual test.
def vanilla_method(file, name):
    source=z.read(f"scripts/widgets/{file}.lua").decode("utf-8-sig").replace("\r", "")
    start=source.index(f"function {name}(")
    end=source.index("\nend", start)+len("\nend")
    return source[start:end]
lua.execute(vanilla_method("widget", "Widget:OnControl"))
lua.execute("ImageButton=Class(Widget,function(self,name) Widget._ctor(self,name);self.control=CONTROL_ACCEPT end)")
lua.execute(vanilla_method("imagebutton", "ImageButton:OnControl"))
lua.execute("package.preload['widgets/imagebutton']=function() return ImageButton end")
for name in ["truescrolllist","truescrollarea"]:
    value=lua.execute(z.read(f"scripts/widgets/{name}.lua").decode("utf-8-sig"))
    lua.globals()[{"truescrolllist":"TrueScrollList","truescrollarea":"TrueScrollArea"}[name]]=value
lua.execute("package.preload['widgets/truescrollarea']=function() return TrueScrollArea end")
templates=z.read("scripts/widgets/redux/templates.lua").decode("utf-8-sig")
factory=templates[templates.index("function TEMPLATES.ScrollingGrid"):templates.index("-----------------",templates.index("function TEMPLATES.ScrollingGrid"))]
lua.execute("TEMPLATES={ScreenRoot=function() return Widget('root') end}" + factory)
lua.execute("package.preload['widgets/redux/templates']=function() return TEMPLATES end")
root=Path(__file__).resolve().parents[1]
lua.globals().ui_source=(root/"scripts/widgets/music_ui_common.lua").read_text(encoding="utf8")
lua.execute("package.preload['widgets/music_ui_common']=function() return assert(loadstring(ui_source))() end")
Screen=lua.execute((root/"scripts/screens/dangomusicscreen.lua").read_text(encoding="utf8"))
lua.globals().MusicScreen=Screen
lua.execute(r"""
controller={modroot='',schema={lyrics={}},settings={lyrics={}},state={player={}},
 requests={},commands={},artworkCalls=0,
 Command=function(self,body,cb) self.commands[#self.commands+1]=body; if cb then cb({}) end end,
 Request=function(self,path,method,body,cb) self.requests[#self.requests+1]={path=path,method=method,body=body,cb=cb} end,
 Subscribe=function() return function() end end,
 GetArtwork=function(self) self.artworkCalls=self.artworkCalls+1 end,
 RequestArtwork=function(self,kind,id) return self:GetArtwork(id) end,
 GetPlaylistArtwork=function(self) self.artworkCalls=self.artworkCalls+1 end,
 GetPosition=function() return 0 end,
 RefreshSettings=function() end,Poll=function() end,GetLyrics=function() return {} end,
 SetSettings=function(self,patch,cb) self.writes=self.writes or {};self.writes[#self.writes+1]={patch=patch,cb=cb} end}
s=MusicScreen(controller)
function click(button)
 local function clear(w) w.focus=false;for _,c in pairs(w.children) do clear(c) end end
 clear(s)
 local w=button;while w do w.focus=true;w=w.parent end
 assert(s:OnControl(CONTROL_ACCEPT,true))
 assert(s:OnControl(CONTROL_ACCEPT,false))
end
controller.state.mode='loop';controller.state.player.mode='single'
s:UpdateState();assert(s.mode:GetText()=='列表循环')
click(s.mode);assert(controller.commands[#controller.commands].value=='shuffle')
controller.state.mode='shuffle';s:UpdateState();assert(s.mode:GetText()=='随机播放')
click(s.mode);assert(controller.commands[#controller.commands].value=='single')
controller.state.mode='single';s:UpdateState();assert(s.mode:GetText()=='单曲循环')
click(s.mode);assert(controller.commands[#controller.commands].value=='loop')
assert(s.mode.parent==s.playerRoot and s.queueButton.parent==s.playerRoot)
assert(s.playerRoot.draworder>s.content.draworder,'content creation must raise persistent player hit targets')
assert(s.queueButton.icon.clickable==false,'decorative icon must not steal button focus')
s:SelectPlaylist({id=77,name='test'})
function req() return controller.requests[#controller.requests] end
assert(req().path:match('limit=100$'))
local batch={tracks={},total=4000}
for i=1,100 do batch.tracks[i]={id=i,name='song '..i,artists='artist',duration=100} end
req().cb(batch)
local list=s.scrollList
assert(#list:GetListWidgets()==12, 'must create fixed visible rows plus two buffers')
assert(#s.artTargets==13, 'artwork targets must be bounded to pooled rows plus header')
local version=s.viewVersion
local requests=#controller.requests
local content=s.content
for i=1,80 do
 s:OnControl(CONTROL_SCROLLFWD,true); s:OnControl(CONTROL_SCROLLFWD,false)
 list:OnUpdate(.016)
end
assert(#controller.requests==requests,'wheel must not issue HTTP')
assert(s.content==content and s.viewVersion==version,'wheel must not rebuild content')
assert(#s.artTargets==13,'wheel must not grow artwork target list')
assert(list.current_scroll_pos>1 and list.current_scroll_pos<list.target_scroll_pos,'vanilla interpolation must remain active')
s:PrefetchTracks()
assert(#controller.requests==requests+1,'timer must fetch upcoming missing batch')
local pending=req()
s.grid=true;s:RenderTracks();s:RefreshTrackData()
pending.cb({tracks={{id=201,name='new batch'}},total=4000})
assert(not next(s.pendingBatches),'switching layout must accept in-flight data')
assert(#s.artTargets==25,'grid pool must remain bounded: 24 plus header')
local stale=req()
s:Search('new')
assert(req().path:match('limit=50$'),'search must respect API cap')
local oldtotal=s.total
pending.cb({tracks={{id=999,name='stale'}},total=9000})
assert(s.total==oldtotal,'stale source callback must be ignored')
req().cb({tracks={{id=5,name='found'}},total=1})
assert(s.trackCache[1].id==5)

for i=1,35 do controller.schema.lyrics['test'..i]={type='boolean',default=true} end
s:ShowSettings('lyrics')
local area=s.settingsScroll
local body=area.context_root
assert(body.clip and body.clip.y==-200,'moving settings body must own an explicit clip')
assert(#body.children>0,'body must contain widgets')
local hidden=0
for _,r in ipairs(s.settingRows) do
 if not r.widget.shown then hidden=hidden+1 end
end
assert(hidden>0,'offscreen setting controls must be hidden, not just visually clipped')
assert(body.parent==area.scissored_root,'settings body must remain under vanilla clipped root')
local settingsContent=s.content
local before=#controller.requests
for i=1,10 do s:OnControl(CONTROL_SCROLLFWD,true);area:OnUpdate(.016) end
assert(area.current_scroll_pos>0,'settings must scroll continuously')
assert(body.clip.y==-200-area.current_scroll_pos,'body-local clip must counteract scrolling')
assert(body.clip.height==390 and body.clip.width==880,'clip must stay within content viewport')
for _,r in ipairs(s.settingRows) do
 if r.widget.shown then
  assert(r.y+area.current_scroll_pos-26>=-200 and r.y+area.current_scroll_pos+26<=190,
   'no visible control may overlap player bar or settings tabs')
 end
end
assert(s.content==settingsContent and before==#controller.requests,'settings wheel must not rebuild/request')
local pos=area.current_scroll_pos
s:ShowSettings('lyrics')
assert(s.settingsScroll.current_scroll_pos==pos,'setting save refresh must retain scroll position')

-- Queue uses the real list callback and real ImageButton press/release dispatch.
click(s.queueButton)
assert(s.view=='queue' and req().path=='/api/queue?offset=0&limit=100')
assert(s.playerRoot.draworder>s.content.draworder)
req().cb({tracks={},total=0,queueRevision=1})
assert(s.total==0 and #s.tracks==0,'empty queue remains an explicit queue page')
s:ShowQueue()
req().cb({tracks={{id=41,name='queued'}},total=201,queueRevision=2})
local row=s.scrollList:GetListWidgets()[1]
controller.state.player.track={id=41,name='queued'};s:UpdateState()
assert(row.button.normalColour[4]==.65,'queue current song must be highlighted')
click(row.button)
local command=controller.commands[#controller.commands]
assert(command.source=='queue' and command.trackId==41 and command.queueRevision==2)
s:FetchTrackBatch(100)
req().cb({tracks={{id=141,name='second page'}},total=201,queueRevision=2})
assert(s.trackCache[101].id==141,'queue paging must use absolute indices')
s:FetchTrackBatch(200)
local previous=req()
previous.cb({tracks={{id=241,name='changed queue'}},total=1,queueRevision=3})
assert(s.queueRevision==nil and s.total==0,'changed revision must discard entire prior cache')
assert(req()~=previous,'revision change must refresh the first page')
req().cb({tracks={{id=71,name='new queue'}},total=1,queueRevision=3})
assert(s.queueRevision==3 and s.trackCache[1].id==71 and not s.trackCache[101])
previous.cb({tracks={{id=999,name='late'}},total=999,queueRevision=2})
assert(s.total==1,'stale queue page must not mix into refreshed queue')


-- Stationary snapshots must avoid repeated native text/layout/texture work.
s:UpdateState();s:UpdateProgress()
local texts,truncs,textures,scales=metrics.string,metrics.truncate,metrics.texture,metrics.scale
for i=1,100 do s:UpdateState();s:UpdateProgress() end
assert(metrics.string==texts and metrics.truncate==truncs,'unchanged labels must skip native string and truncation calls')
assert(metrics.texture==textures and metrics.scale==scales,'unchanged playback must skip texture and slider geometry work')
print('METRIC unchanged 100 state/progress updates: native string=0 truncation=0 texture=0 slider geometry=0')

-- Vanilla interpolation calls binders every frame, including unchanged rows.
s:SelectPlaylist({id=80,name='pool metrics'})
req().cb(batch)
local stable=s.scrollList
stable:RefreshView()
local shows,truncs=metrics.show,metrics.truncate
for i=1,100 do stable:RefreshView() end
assert(metrics.truncate==truncs,'stationary row bind must skip all truncation')
-- Vanilla scrollbar visibility still runs once per RefreshView.
assert(metrics.show-shows<=100,'row binder must not Show every visible row on each refresh')
local placeholder=s.tracks[101]
s:FetchTrackBatch(200)
req().cb({tracks={{id=201,name='other batch'}},total=4000})
assert(s.tracks[101]==placeholder,'loading placeholders must retain identity across unrelated batches')
local filterRequests=#controller.requests
local filterView=s.viewVersion
local filterItems=s.scrollList.items
s.filterEdit.OnTextEntered('')
assert(s.scrollList.items==filterItems,'unchanged filter must skip rebuilding the data array')
assert(#controller.requests==filterRequests and s.viewVersion==filterView,'same filter submit must remain local')
print('METRIC 100 stationary vanilla row refreshes: row text writes=0 row Show calls=0')

-- Real input dispatch, held drag, release outside focus, and keyboard limits.
local UI=require('widgets/music_ui_common')
local mouseX,mouseDown=0,true
TheInput.GetScreenPosition=function() return {x=mouseX,y=0} end
TheInput.IsMouseDown=function() return mouseDown end
local commits,previews=0,0
local slider=UI.Slider(s.root,0,0,100,.5,0,1,false,function() commits=commits+1 end)
slider.onpreview=function() previews=previews+1 end
click(slider.rail)
assert(commits==0 and previews==0,'unchanged press/release must not preview or commit')
slider.rail.focus=true
slider.rail:OnControl(CONTROL_ACCEPT,true)
mouseX=25
slider:OnUpdate(.016)
local sc=metrics.scale
for i=1,100 do slider:OnUpdate(.016) end
assert(metrics.scale==sc and previews==1 and commits==0,'held stationary drag must not relayout/preview or POST')
slider.rail.focus=false;mouseDown=false;slider:OnUpdate(.016)
assert(commits==1 and slider.value==.75 and not slider.dragging,'outside-focus release must commit once')
slider:SetValue(1);slider.rail.focus=true
slider.rail:OnControl(CONTROL_MOVE_RIGHT,false)
assert(commits==1,'keyboard limit must not issue duplicate commit')
slider.rail:OnControl(CONTROL_MOVE_LEFT,false)
assert(commits==2 and slider.value<1,'keyboard step must commit changed value')
print('METRIC 100 stationary held-drag frames: geometry=0 preview=0 writes=0; outside release commits=1')

controller.schema.player={envLunar={type='boolean',default=true},envOcean={type='boolean',default=true},
 envRuins={type='boolean',default=true},envAtrium={type='boolean',default=true},envForest={type='boolean',default=true},
 envRain={type='boolean',default=true},volume={type='number',min=0,max=1,default=.7}}
controller.settings.player={envRain=true,volume=.7}
s:ShowSettings('player')
local settingContent,settingArea=s.content,s.settingsScroll
for _,key in ipairs({'envLunar','envOcean','envRuins','envAtrium','envForest','envRain'}) do
 assert(s.settingControls[key],key..' must have a setting control')
end
s:SaveSetting('player','volume',.2)
s:SaveSetting('player','volume',.4)
s:SaveSetting('player','volume',.6)
s:SaveSetting('player','envRain',false)
assert(#controller.writes==1,'settings must serialize HTTP writes')
assert(s.content==settingContent and s.settingsScroll==settingArea,'pending settings must preserve exact widget tree')
local function finishWrite(index,err)
 local w=controller.writes[index]
 if not err then
  for group,values in pairs(w.patch) do
   controller.settings[group]=controller.settings[group] or {}
   for key,value in pairs(values) do controller.settings[group][key]=value end
  end
 end
 w.cb({settings=controller.settings},err)
end
finishWrite(1)
assert(#controller.writes==2 and controller.writes[2].patch.player.volume==.6,'intermediate queued values must coalesce')
assert(controller.writes[2].patch.player.envRain==false,'independent switch must share queued patch')
finishWrite(2)
assert(controller.settings.player.volume==.6 and controller.settings.player.envRain==false)
assert(s.content==settingContent and s.settingsScroll==settingArea,'successful settings save must never rebuild UI')
s:SaveSetting('player','volume',.9);finishWrite(3,'simulated failure')
assert(s.content==settingContent and not s.settingsWrite and not s.queuedSettings,'failed write must release queue and keep controls')
print('METRIC 4 rapid settings commits: POSTs=2 content rebuilds=0; failure recovery passed')
local rainToggle,settingSlider
for _,r in ipairs(s.settingRows) do
 if r.widget.children[1].value=='雨天音频柔化' then rainToggle=r.widget.children[3] end
 for _,w in ipairs(r.widget.children) do if w.name=='music_slider' then settingSlider=w end end
end
assert(rainToggle and settingSlider,'real setting controls must be available')
click(rainToggle)
assert(rainToggle.musicValue==true and controller.writes[4].patch.player.envRain==true,'vanilla button entry must update switch immediately')
click(rainToggle)
assert(rainToggle.musicValue==false and #controller.writes==4,'rapid toggle must remain responsive during in-flight save')
finishWrite(4);assert(rainToggle.musicValue==false,'queued switch value must survive earlier response')
finishWrite(5)
mouseDown=true;mouseX=settingSlider:GetWorldPosition().x
click(settingSlider.rail)
finishWrite(#controller.writes)
local writesBefore=#controller.writes
settingSlider.rail.focus=true;settingSlider.rail:OnControl(CONTROL_ACCEPT,true)
mouseX=settingSlider:GetWorldPosition().x+settingSlider.width/4
settingSlider:OnUpdate(.016)
local dragged=settingSlider.value
s:UpdateState()
assert(settingSlider.value==dragged and #controller.writes==writesBefore,'state refresh during drag must preserve preview and avoid POST')
mouseDown=false;settingSlider.rail.focus=false;settingSlider:OnUpdate(.016)
assert(#controller.writes==writesBefore+1,'setting slider release must save once through real control entry')
finishWrite(#controller.writes)
assert(s.content==settingContent and s.settingsScroll==settingArea,'toggle and slider entry must preserve settings tree')

-- Large sorted lyric timelines and backwards seek use the normal Now page.
local lyricLines={};local probes=0;local position=3072.5
for i=1,4096 do
 local index=i
 lyricLines[i]=setmetatable({}, {__index=function(_,key)
  if key=='start' then probes=probes+1;return index-1 end
  if key=='text' then return 'line '..index end
 end})
end
controller.GetLyrics=function() return {lines=lyricLines} end
controller.GetPosition=function() return position end
controller.state.player.track={id=777,name='lyrics'}
s:ShowNow();probes=0
s:UpdateProgress()
assert(s.lyricLabels[3].value=='line 3073' and probes<=13,'long lyrics must find active line in logarithmic work')
local truncs=metrics.truncate
local lyricCalls,colourCalls=0,0
for _,label in ipairs(s.lyricLabels) do
 local truncate,colour=label.SetTruncatedString,label.SetColour
 label.SetTruncatedString=function(self,...) lyricCalls=lyricCalls+1;return truncate(self,...) end
 label.SetColour=function(self,...) colourCalls=colourCalls+1;return colour(self,...) end
end
for i=1,100 do s:UpdateProgress() end
assert(metrics.truncate==truncs and lyricCalls==0 and colourCalls==0,'same active lyric window must skip label setters entirely')
position=0;s:UpdateProgress();assert(s.lyricLabels[3].value=='line 1','backwards seek must reset active lyric')
position=9999;s:UpdateProgress();assert(s.lyricLabels[3].value=='line 4096','past-end playback must keep last lyric')
local replacement={{start=0,text='replacement'}}
controller.GetLyrics=function() return {lines=replacement} end
position=0;s:UpdateProgress()
assert(s.lyricLabels[3].value=='replacement','replaced lyric data must refresh at same position')
controller.GetPosition=function() return 0 end
print('METRIC 4096-line Now page: active-line lookup <=13 timeline probes; 100 same-window truncation calls=0')

-- A late cover must still appear from the periodic path without a new state event.
controller.GetArtwork=function() return {atlas='late.xml',image='cover.tex'} end
controller.state.player.track={id=812,name='late'}
s:UpdateArtwork()
assert(s.playerCover.texture=='cover.tex','timer must apply completed player artwork')
local textures=metrics.texture
for i=1,50 do s:UpdateArtwork() end
assert(metrics.texture==textures,'same artwork must not rebind texture')
controller.state.player.track=nil;s:UpdateArtwork()
assert(s.playerCover.texture=='card.tex','track removal must clear stale player artwork')

-- Switch while source-specific requests and login polling are pending.
controller.state.provider='netease';controller.state.account={id=1,nickname='same'};s:UpdateState()
s:Search('old');local oldSearch=req()
s:LoadPlaylists();local oldLists=req()
s:StartLogin();local oldLogin=req()
assert(oldLogin.path=='/api/login/start')
controller.state.provider='qq';controller.state.account={id=1,nickname='same'};s:UpdateState()
assert(s.provider=='qq' and s.account.value=='QQ · same' and s.sourceButton.value=='QQ音乐 ⇄')
local qqHome=req()
oldSearch.cb({tracks={{id=99,name='stale'}},total=1})
oldLists.cb({playlists={{id=99,name='stale'}}})
oldLogin.cb({key='obsolete'})
assert(#s.playlists==0 and s.view=='home' and req().path=='/api/login/cancel' and req().body.key=='obsolete' and req().body.provider=='netease','late start must cancel its own key without altering the new source')
s:Search('qq');assert(req().path:find('provider=qq',1,true))
s:SelectPlaylist({id='qq:playlist:12',name='QQ'});assert(req().path:find('provider=qq',1,true))
s:StartLogin();local qqLogin=req();local beforeQR=#controller.requests;qqLogin.cb({key='qq-key'})
assert(controller.requests[beforeQR+1].path=='/api/login/artwork?key=qq-key','QQ QR without a URL must use the key artwork endpoint')
assert(req().path:find('/api/login/check?key=',1,true),'QQ login must start polling its key')
local oldPoll=req();controller.state.provider='netease';controller.state.account=nil;s:UpdateState()
local cancelled=false;for _,r in ipairs(controller.requests) do if r.path=='/api/login/cancel' and r.body.key=='qq-key' and r.body.provider=='qq' then cancelled=true end end
assert(cancelled,'switching source must cancel the active QR key')
local newHome=req();oldPoll.cb({status='success'})
assert(req()==newHome and s.view=='home','late QQ login polling must not change NetEase view')
s:ShowQueue();local oldQueue=req()
controller.state.provider='qq';s:UpdateState();local newQueue=req()
assert(s.view=='queue' and newQueue~=oldQueue,'switching source must restart a pending queue load')
oldQueue.cb({tracks={{id=111,name='old queue'}},total=1,queueRevision=1})
newQueue.cb({tracks={{id=222,name='new queue'}},total=1,queueRevision=2})
assert(s.trackCache[1].id==222 and not next(s.pendingBatches),'queue must remain usable after source switch')
for _,status in ipairs({'failed','canceled'}) do
 s:StartLogin();local start=req();start.cb({key='terminal-'..status})
 local artwork=controller.requests[#controller.requests-1];local check=req()
 check.cb({status=status,message='登录已结束：'..status})
 assert(s.loginTask==nil and s.loginKey==nil and s.subtitle.value=='登录已结束：'..status,'terminal login must stop polling and show message')
 local count=#controller.requests
 s:CheckLogin(s.viewVersion,'terminal-'..status)
 assert(#controller.requests==count,'terminal login key must not issue another check')
 artwork.cb({asset={atlas='late.xml',image='qr.tex'}})
 assert(s.subtitle.value=='登录已结束：'..status,'late QR artwork must not overwrite terminal message')
end
-- 临时错误只有限重试原二维码，并保留服务器实际原因。
s:StartLogin();req().cb({key='retry-key'})
local startCount=#controller.requests
s:CheckLogin(s.viewVersion,'retry-key')
assert(#controller.requests==startCount,'已有确认请求时不能重复发出')
for attempt=1,4 do
 local check=req();assert(check.path:find('/api/login/check?key=retry-key',1,true))
 check.cb(nil,'手机已确认，但本机保存失败')
 assert(s.message.value=='手机已确认，但本机保存失败' and s.loginKey=='retry-key')
 if attempt<=3 then
  assert(s.loginTask and s.loginTask.seconds==attempt*2)
  s.loginTask.fn()
 else assert(s.loginTask==nil and s.subtitle.value:find('重试确认',1,true)) end
end
s.loginErrors=0;s:CheckLogin(s.viewVersion,'retry-key')
req().cb({status='success',account={id='restored',nickname='登录已恢复'}})
assert(s.loginKey==nil and controller.state.account.id=='restored')
s:StartLogin();req().cb({key='leave-key'})
s:ShowNow();assert(req().path=='/api/login/cancel' and req().body.key=='leave-key','leaving login must cancel its active key')
s:StartLogin();req().cb({key='destroy-key'})
s:Stop();assert(req().path=='/api/login/cancel' and req().body.key=='destroy-key','screen stop must cancel its active key')

-- Sidebar source choice waits for the saved controller state, including failures.
controller.state.provider='qq';controller.settings.player.musicSource=1;s:UpdateState()
s:ShowHome('recommend');local writes=#controller.writes
click(s.sourceButton)
assert(#controller.writes==writes+1 and controller.writes[#controller.writes].patch.player.musicSource==0)
assert(s.provider=='qq' and s.sourceButton.value=='QQ音乐 ⇄','pending write must not change source or theme')
if UI.Theme then assert(UI.Theme(s.root).accent[2]>.7,'QQ source must use green theme') end
controller.writes[#controller.writes].cb(nil,'保存失败')
assert(s.provider=='qq' and s.sourceButton.value=='QQ音乐 ⇄','failed source write must keep current source')
click(s.sourceButton);controller.settings.player.musicSource=0;controller.state.provider='netease'
controller.writes[#controller.writes].cb({settings=controller.settings});s:UpdateState()
assert(s.provider=='netease' and s.sourceButton.value=='网易云 ⇄')
if UI.Theme then assert(UI.Theme(s.root).accent[1]==1,'NetEase source must use pink theme') end

-- Settings expose the HUD entry toggle and clear descriptions.
controller.schema.player.showTopLeftButton={type='boolean',default=true}
controller.settings.player.showTopLeftButton=true
s:ShowSettings('player')
local foundEntry=false
for _,r in ipairs(s.settingRows) do
 if r.widget.children[1].value=='显示左上角音乐按钮' then
  foundEntry=true;assert(r.widget.children[2].value=='隐藏按钮后仍可用快捷键打开')
 end
end
assert(foundEntry,'HUD entry setting must be visible in the player group')
controller.schema.player.language={type='number',min=-1,max=1,default=-1,supported=false,reason='界面语言尚未实现'}
s:ShowSettings('player')
local foundUnsupported=false
for _,r in ipairs(s.settingRows) do
 if r.widget.children[1].value=='界面语言' then
  foundUnsupported=true;assert(r.widget.children[2].value=='界面语言尚未实现' and not r.widget.children[3].enabled)
 end
end
assert(foundUnsupported,'unsupported settings must show their reason and be disabled')

-- Backend connection state is separate from native audio state.
controller.backendConnected=false;controller.state.playerConnected=true;s:UpdateState()
assert(s.connectionButton.value=='后台 · 离线')
s:ShowConnection();assert(s.title.value=='本机播放器连接' and s.subtitle.value:find('尚未连接'))
controller.Reconnect=function(_,cb) controller.reconnectCallback=cb end
local reconnect
for _,w in ipairs(s.content.children) do if w.value=='重新连接' then reconnect=w end end
assert(reconnect);click(reconnect);assert(controller.reconnectCallback)
controller.reconnectCallback(nil,'连接失败');assert(s.message.value=='连接失败' and s.view=='setup')
local beforeOnline=#controller.requests
controller.backendConnected=true;controller.state.provider='qq';s:UpdateState();assert(s.connectionButton.value=='后台 · 在线')
assert(#controller.requests==beforeOnline+1 and req().path:find('/api/playlists?',1,true),'online transition with source change must refresh playlists only once')
controller.OpenModFolder=function(_,cb) controller.folderCallback=cb end
s:ShowConnection();local folder
for _,w in ipairs(s.content.children) do if w.value=='打开模组目录' then folder=w end end
assert(folder);click(folder);assert(controller.folderCallback)
controller.folderCallback(nil,'打开失败');assert(s.message.value=='打开失败')
reconnect=nil
for _,w in ipairs(s.content.children) do if w.value=='重新连接' then reconnect=w end end
local beforeReconnect=#controller.requests;click(reconnect);controller.reconnectCallback({ok=true})
assert(s.view=='setup' and #controller.requests==beforeReconnect+1 and req().path:find('/api/playlists?',1,true),'successful reconnect keeps connection page and refreshes playlists once')

controller.bridge={IsConfigured=function() return false end}
local savedRequest=s.Request
s.Request=function() error('unconfigured home must not request recommendations') end
s:ShowHome('recommend')
assert(s.view=='setup' and s.title.value=='本机播放器连接','first-run home must explain companion setup')
s.Request=savedRequest
controller.bridge=nil
local initialCount=#controller.requests
local setupScreen=MusicScreen(controller,nil,'connection')
assert(setupScreen.view=='setup' and #controller.requests==initialCount,'connection entry must not load home or playlists')
local workshopPath=false
for _,w in ipairs(setupScreen.content.children) do if type(w.value)=='string' and w.value:find('steamapps/workshop/content/322330/3836261433',1,true) then workshopPath=true end end
assert(workshopPath,'connection instructions must show the Steam Workshop path')
setupScreen:Stop()
controller.modroot='D:/game/mods/local_netease_music/'
local localSetup=MusicScreen(controller,nil,'connection');local localPath=false
for _,w in ipairs(localSetup.content.children) do if type(w.value)=='string' and w.value:find('启动播放器.cmd',1,true) then localPath=true end end
assert(localPath,'local test installation must name its companion launcher')
localSetup:Stop();controller.modroot=''
local settingsScreen=MusicScreen(controller,nil,'settings')
assert(settingsScreen.view=='settings' and settingsScreen.settingsGroup=='player' and #controller.requests==initialCount,'settings entry must open player settings without catalog requests')
settingsScreen:Stop()
s:SelectPlaylist({id=2,name='closing'})
local closing=req()
s.closed=true;s:Stop()
closing.cb({tracks={{id=1,name='closed'}},total=1})
assert(s.total==0,'closed screen callback must be ignored')
print('PASS: Lua 5.1 vanilla scroll interpolation; fixed row/art pools; 4000-track wheel no HTTP/rebuild; timer prefetch; grid in-flight response; source race; search cap; settings continuous scroll/preserve; vanilla button dispatch; top-level mode cycle; queue empty/page/play/revision race; close')
""")


# Exercise the current game's actual focus propagation in addition to its
# TrueScrollArea and button dispatch. Native hit-testing remains stubbed.
for method in ["Widget:ClearFocus", "Widget:SetFocusFromChild", "Widget:SetFocus"]:
    lua.execute(vanilla_method("widget", method))
lua.execute(r"""
function FunctionOrValue(value) if type(value)=='function' then return value() else return value end end
Widget.OnGainFocus=function() end
Widget.OnLoseFocus=function() end
ImageButton.OnGainFocus=function() end
ImageButton.OnLoseFocus=function() end
for _,cls in ipairs({ImageButton,MusicScreen,TrueScrollArea}) do
 cls.SetFocus=Widget.SetFocus;cls.SetFocusFromChild=Widget.SetFocusFromChild;cls.ClearFocus=Widget.ClearFocus
end
controller.schema.player.musicSource={type='number',min=0,max=1,default=0}
local focusScreen=MusicScreen(controller,nil,'settings')
focusScreen.is_screen=true
TheFrontEnd.GetActiveScreen=function() return focusScreen end
focusScreen:ShowSettings('lyrics')
local old=focusScreen.settingsScroll
old:Scroll(500);for i=1,80 do old:OnUpdate(.016) end
assert(old.current_scroll_pos>0,'precondition: lyrics were scrolled')
local tab
for _,w in ipairs(focusScreen.content.children) do if w.value=='音乐与环境' then tab=w end end
assert(tab,'settings tab button must exist')
tab:SetFocus()
assert(tab.focus and focusScreen.focus, 'focus must propagate: '..tostring(tab.focus)..' '..tostring(focusScreen.focus))
assert(focusScreen:OnControl(CONTROL_ACCEPT,true))
assert(focusScreen:OnControl(CONTROL_ACCEPT,false))
local area=focusScreen.settingsScroll
assert(focusScreen.settingsGroup=='player' and area~=old, tostring(focusScreen.settingsGroup)..' focus '..tostring(tab.focus)..' down '..tostring(tab.down))
assert(area.current_scroll_pos==0 and area.target_scroll_pos==0,'tab click must open new group at top')
local topRows,hiddenRows={},0
for _,r in ipairs(focusScreen.settingRows) do
 local label=r.widget.children[1].value
 if label=='音乐来源' or label=='显示左上角音乐按钮' then topRows[label]=r.widget.shown and r.y>=-174 and r.y<=164 end
 if not r.widget.shown then hiddenRows=hiddenRows+1 end
end
assert(topRows['音乐来源'] and topRows['显示左上角音乐按钮'],'top cards must be visible at scroll zero')
assert(hiddenRows>0 and area.context_root.clip.y==-200,'lower rows must start clipped at scroll zero')
area:SetFocus()
for i=1,20 do area:OnUpdate(.016) end
assert(area.current_scroll_pos==0 and area.target_scroll_pos==0,'vanilla focus propagation must not auto-scroll')
focusScreen:Stop()
print('PASS: real Widget focus propagation and tab dispatch leave new settings group at top')
""")

# Exercise screen reopen and pooled cover cells with the real Controller cache
# methods, while keeping HTTP, native texture loading and hit-testing stubbed.
lua.execute("package.preload.dangomusic_bridge=function() return {} end; package.preload.dangomusic_assets=function() return {} end; package.preload.dangomusic_environment=function() return {} end")
lua.globals().CatalogController=lua.execute((root/"scripts/dangomusic_controller.lua").read_text(encoding="utf8"))
lua.execute(r"""
function Clamp(v,a,b) return math.max(a,math.min(b,v)) end
local c={modroot='',schema={lyrics={}},settings={lyrics={}},state={provider='netease',account={id='1'},player={}},
 catalog={},listeners={},requests={},leases=0,released=0,art={}}
c.GetCatalog=CatalogController.GetCatalog;c.GetCatalogIdentity=CatalogController.GetCatalogIdentity
c.ObserveCatalogAccount=CatalogController.ObserveCatalogAccount;c.InvalidateCatalog=CatalogController.InvalidateCatalog
c.Subscribe=CatalogController.Subscribe;c.Notify=CatalogController.Notify
function c:Request(path,method,body,cb) self.requests[#self.requests+1]={path=path,cb=cb} end
function c:Command() end
function c:RefreshSettings() end
function c:GetPosition() return 0 end
function c:GetLyrics() return {} end
function c:GetArtwork() end
function c:GetPlaylistArtwork() end
function c:PeekArtwork(kind,id) return self.art[kind..':'..tostring(id)] end
function c:RequestArtwork() end
function c:AcquireArtwork(asset)
 self.leases=self.leases+1
 return {atlas=asset.atlas,image=asset.image,Release=function(lease) if not lease.released then lease.released=true;c.released=c.released+1 end end}
end
c:ObserveCatalogAccount('netease',c.state.account)
local first=MusicScreen(c)
assert(#c.requests==2,'first open must issue one home and one playlist request')
local items={}
for i=1,30 do
 items[i]={id=tostring(i),name='album '..i}
 c.art['playlistId:'..i]={atlas='a'..i..'.xml',image='a'..i..'.tex'}
end
local home,lists
for _,r in ipairs(c.requests) do if r.path:find('/api/discover',1,true) then home=r else lists=r end end
home.cb({playlists=items});lists.cb({playlists={{id='mine',name='mine'}}})
assert(first.view=='home' and first.homeData==items)
local grid=first.scrollList;local pooled=grid:GetListWidgets()
assert(pooled[1].art.widget.shown and pooled[1].art.asset,'cached cover must bind immediately')
local before=#c.requests
first.closed=true;first:Stop()
assert(c.leases==c.released,'closing screen must release pooled cover leases')
local second=MusicScreen(c)
assert(#c.requests==before and second.homeData==items,'reopening within TTL must render cached home without another request')
second.refreshButton.onclick();assert(#c.requests==before+2,'refresh button must force both visible home and playlists')
second.refreshButton.onclick();assert(#c.requests==before+2,'force refresh must still coalesce in-flight requests')
c.requests[before+1].cb(nil,'offline');c.requests[before+2].cb(nil,'offline')
assert(second.homeData==items,'failed refresh must keep cached home visible')
grid=second.scrollList;pooled=grid:GetListWidgets()
local firstAsset=pooled[1].art.asset
assert(firstAsset and pooled[1].art.widget.shown)
grid:ScrollToDataIndex(13)
assert(pooled[1].art.asset and pooled[1].art.widget.shown,'cached recycled cover must show during scroll')
grid:ScrollToDataIndex(1)
assert(pooled[1].art.asset==firstAsset and pooled[1].art.widget.shown,'scrolling back must immediately restore cached cover')
grid:SetItemsData({items[1]})
for _,w in ipairs(grid:GetListWidgets()) do
 if not w.item then assert(not w.art.lease and not w.art.asset,'empty pooled cells must release old covers') end
end
second.closed=true;second:Stop();assert(c.leases==c.released,'all recycled cover leases must be released')
c:InvalidateCatalog('netease');c:ObserveCatalogAccount('netease',{id='2'});c.state.account={id='2'}
local count=#c.requests
local waiting=MusicScreen(c)
assert(#c.requests==count+2 and waiting.homeData==nil,'new account must not see old home')
waiting.closed=true;waiting:Stop()
local reopened=MusicScreen(c)
assert(#c.requests==count+2,'reopening while requests are pending must not duplicate them')
local requests={c.requests[count+1],c.requests[count+2]}
for _,r in ipairs(requests) do r.cb({playlists={{id='new',name='new account'}}}) end
assert(reopened.homeData and reopened.homeData[1].id=='new','pending result must reach reopened screen')
reopened.closed=true;reopened:Stop()
local private=MusicScreen(c)
private:SelectPlaylist({id='old-private',name='old private list'})
local oldPage=c.requests[#c.requests];local oldSession=private.trackSession
c:ObserveCatalogAccount('netease',{id='3'});c.state.account={id='3'};c:Notify()
assert(private.view=='home' and not private.selected and private.trackSession>oldSession,'account change must clear private playlist view')
local afterChange=private.content
oldPage.cb({tracks={{id=1,name='old account track'}},total=1})
assert(private.content==afterChange and private.view=='home','old account page callback must not repopulate private list')
private.closed=true;private:Stop()
c:ObserveCatalogAccount('netease',{nickname='missing id'})
local requestCount=#c.requests
assert(c:GetCatalog('netease','playlists')==nil and #c.requests==requestCount,'unknown account must not reuse anonymous data')
print('PASS: real catalog cache survives screen reopen; pooled cover leases and cached scroll return')

-- Persistent bottom player owns its own lease, including when a grid image
-- cannot be loaded. Closing/rebinding must not leave native texture references.
c.state.player.track={id='playing',name='playing'}
local cover={atlas='playing.xml',image='playing.tex'}
function c:RequestArtwork(kind,id) return kind=='trackId' and cover or nil end
local player=MusicScreen(c,nil,'settings')
player:UpdateArtwork()
assert(player.playerCover.texture=='playing.tex' and player.playerCoverLease)
local live=c.leases-c.released
for i=1,40 do player:UpdateArtwork() end
assert(c.leases-c.released==live,'same player cover must not reacquire')
c.state.player.track={id='next',name='next'};cover={atlas='next.xml',image='next.tex'}
player:UpdateArtwork();assert(player.playerCover.texture=='next.tex' and c.leases-c.released==live)
player:ShowNow();assert(player.nowTrack=='next' and #player.artTargets>0)
c.state.player.track=nil;player:UpdateProgress()
assert(player.nowTrack==nil and #player.artTargets==0,'clearing current track must release the Now-page cover')
c.state.player.track=nil;player:UpdateArtwork()
assert(player.playerCover.texture=='card.tex' and not player.playerCoverLease)
player.closed=true;player:Stop();assert(c.leases==c.released)

local login=MusicScreen(c,nil,'connection')
for attempt=1,12 do
 login:StartLogin();local start=c.requests[#c.requests]
 assert(start.path=='/api/login/start')
 start.cb({key='qr'..attempt})
 local artwork
 for i=#c.requests,1,-1 do if c.requests[i].path:find('/api/login/artwork?',1,true) then artwork=c.requests[i];break end end
 artwork.cb({asset={atlas='qr'..attempt..'.xml',image='qr.tex'}})
 assert(login.loginLease and c.leases-c.released==1)
 login:ShowConnectionHelp();assert(not login.loginLease and c.leases==c.released,'leaving login must release QR texture')
end
login.closed=true;login:Stop()

-- Updates are a bounded explicit request; a stale result cannot mutate a
-- replacement settings page. External links always target the author sources.
local updates=MusicScreen(controller,nil,'settings')
updates:ShowUpdates();local pending=controller.requests[#controller.requests]
assert(pending.path=='/api/updates' and pending.method=='GET')
local calls=#controller.requests
updates.checkUpdateButton.onclick();assert(#controller.requests==calls,'pending reads must coalesce clicks')
pending.cb({ok=true,status='unpublished',currentVersion='0.6.0-beta.3'})
assert(updates.updateTitle.value=='暂未发布可用版本')
updates.checkUpdateButton.onclick();pending=controller.requests[#controller.requests]
assert(pending.path=='/api/updates/check' and pending.method=='POST' and type(pending.body)=='table')
pending.cb({ok=true,status='available',currentVersion='0.6.0-beta.3',latest={version='0.6.0-beta.4',notes='cover fixes',url='https://untrusted.invalid'}})
assert(updates.updateTitle.value=='发现新版本')
local visited={};VisitURL=function(url) visited[#visited+1]=url end
for _,w in ipairs(updates.content.children) do if w.value=='GitHub 版本下载' or w.value=='Steam 工坊页面' then w.onclick() end end
assert(visited[1]=='https://github.com/Zechariah0121/dst-music/releases')
assert(visited[2]=='https://steamcommunity.com/sharedfiles/filedetails/?id=3836261433')
updates:ReadUpdates(true);pending=controller.requests[#controller.requests]
updates:ShowSettings('lyrics');local content=updates.content
pending.cb({ok=true,status='error',error={message='offline'}})
assert(updates.content==content and updates.view=='settings','late update result must not rebuild another page')
updates.closed=true;updates:Stop()
print('PASS: player cover lease lifetime; update coalescing, fixed links and stale page responses')
""")
