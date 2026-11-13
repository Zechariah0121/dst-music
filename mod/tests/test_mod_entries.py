"""Entry visibility, ESC recovery, and HUD cleanup using real modmain hooks."""
import argparse
from pathlib import Path
from zipfile import ZipFile
from lupa.lua51 import LuaRuntime

parser = argparse.ArgumentParser()
parser.add_argument('--scripts-zip', required=True)
args = parser.parse_args()
lua = LuaRuntime(unpack_returned_tuples=True)
with ZipFile(args.scripts_zip) as source:
    lua.execute(source.read('scripts/class.lua').decode('utf-8-sig'))
lua.execute(r'''
GLOBAL=_G; MODROOT='mod/'; KEY_F8=119; CHATFONT='chat'; MOVE_UP=1; MOVE_DOWN=2
Asset=function() return {} end
GetModConfigData=function() return 'KEY_F8' end
kleiloadlua=function() return function() return {token='test'} end end
TheNet={IsDedicated=function() return false end}
hooks={}; AddClassPostConstruct=function(name,fn) hooks[name]=fn end
function Node()
 local n={children={},shown=true,enabled=true,image={SetSize=function() end,SetTint=function() end}}
 function n:AddChild(child) self.children[#self.children+1]=child; child.parent=self; return child end
 for _,name in ipairs({'SetNormalScale','SetFocusScale','SetFont','SetTextSize','SetTextColour','SetTooltip'}) do n[name]=function() end end
 function n:SetPosition(x,y) self.x,self.y=x,y end
 function n:SetFocusChangeDir(dir,widget) self.focusDirs=self.focusDirs or {};self.focusDirs[dir]=widget end
 function n:SetText(text) self.text=text end
 function n:SetOnClick(fn) self.onclick=fn end
 function n:ClearFocus() self.focus=false end
 function n:Show() self.shown=true end
 function n:Hide() self.shown=false end
 function n:Enable() self.enabled=true end
 function n:Disable() self.enabled=false end
 function n:IsVisible() return self.shown end
 return n
end
package.preload['widgets/imagebutton']=function() return Node end
package.preload['widgets/redux/templates']=function()
 return {StandardButton=function(fn,text,size) local n=Node();n.onclick=fn;n.text=text;n.nativeStyle=true;n.size=size;return n end}
end
for _,name in ipairs({'widgets/music_lyrics','widgets/music_songcard','widgets/music_island'}) do package.preload[name]=function() return Node end end
package.preload['widgets/music_ui_common']=function()
 return {Panel=function(parent) return parent:AddChild(Node()) end,Label=function(parent) return parent:AddChild(Node()) end,
 Button=function(parent,text,x,y,w,h,fn) local b=parent:AddChild(Node());b.text=text;b.onclick=fn;return b end}
end
package.preload['dangomusic_controller']=function()
 return function(inst,connection,root,loader)
  local c={settings={player={}},state={player={}},listeners={},loader=loader,reconnects=0}
  function c:Subscribe(fn) self.listeners[fn]=true;return function() self.listeners[fn]=nil end end
  function c:Notify() for fn in pairs(self.listeners) do fn() end end
  function c:Reconnect() self.reconnects=self.reconnects+1 end
  function c:Close() self.closed=true end
  return c
 end
end
package.preload['screens/dangomusicscreen']=function()
 return function(controller,onclose,view)
  local s={name='MusicScreen',view=view}
  function s:Close() self.closed=true;TheFrontEnd.active=TheFrontEnd.previous;onclose() end
  return s
 end
end
TheInput={handlers={}}
function TheInput:AddKeyUpHandler(key,fn)
 local h={key=key,fn=fn,Remove=function(self) self.removed=true end};self.handlers[#self.handlers+1]=h;return h
end
TheFrontEnd={}
function TheFrontEnd:GetActiveScreen() return self.active end
function TheFrontEnd:IsControlsDisabled() return false end
function TheFrontEnd:PushScreen(screen) self.previous=self.active;self.active=screen end
function TheFrontEnd:GetOpenScreenOfType(name) return name=='PauseScreen' and self.pause or nil end
ThePlayer={HUD={HasInputFocus=function() return false end}}
TheFrontEnd.active=ThePlayer.HUD
''')
lua.execute((Path(__file__).resolve().parents[1] / 'modmain.lua').read_text(encoding='utf-8-sig'))
lua.execute(r'''
local controls=Node();controls.owner=ThePlayer;controls.topleft_root=Node()
controls.inst={ListenForEvent=function(self,name,fn) self[name]=fn end}
ThePlayer.HUD.controls=controls
hooks['widgets/controls'](controls)
local c=controls.dangomusic;local button=controls.topleft_root.children[1]
assert(button.shown and button.enabled and c.loader().token=='test')
c.settings.player.showTopLeftButton=false;c:Notify()
assert(not button.shown and not button.enabled and not button.focus)
TheInput.handlers[1].fn()
assert(TheFrontEnd.active.name=='MusicScreen','hidden button must not disable shortcut')
TheFrontEnd.active:Close()
local nativeSettings=Node();local lastRow=Node()
local menu={name='OptionsScreen',root=Node(),subscreener={sub_screens={settings=nativeSettings}},left_spinners={{parent=lastRow}}};TheFrontEnd.active=menu
hooks['screens/redux/optionsscreen'](menu)
assert(#menu.root.children==0,'main-menu options must not get an in-world recovery entry')
TheFrontEnd.pause={name='PauseScreen'}
hooks['screens/redux/optionsscreen'](menu)
local connect,settings
for _,w in ipairs(nativeSettings.children) do
 if w.text=='一键连接播放器' then connect=w elseif w.text=='音乐设置 / 打开播放器' then settings=w end
end
assert(connect and settings)
assert(#menu.root.children==0 and connect.parent==nativeSettings and settings.parent==nativeSettings)
assert(connect.nativeStyle and settings.nativeStyle and connect.x==-35 and connect.y==-174 and settings.y==-210)
assert(connect.focusDirs[MOVE_DOWN]==settings and settings.focusDirs[MOVE_UP]==connect and lastRow.focusDirs[MOVE_DOWN]==connect)
connect.onclick()
assert(c.reconnects==1 and TheFrontEnd.active.view=='connection')
TheFrontEnd.active:Close();settings.onclick()
assert(TheFrontEnd.active.view=='settings')
c.settings.player.showTopLeftButton=true;c:Notify()
assert(button.shown and button.enabled)
local panel=TheFrontEnd.active
controls.inst.onremove()
assert(panel.closed and c.closed and controls.dangomusic==nil and controls.OpenDangoMusic==nil)
for _,h in ipairs(TheInput.handlers) do assert(h.removed) end
''')
print('PASS: hide/show HUD entry, shortcut preservation, ESC recovery scope, HUD cleanup')
