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
    menu_source = source.read('scripts/widgets/menu.lua').decode('utf-8-sig')
lua.execute(r'''
GLOBAL=_G; MODROOT='mod/'; KEY_F8=119; CHATFONT='chat'; MOVE_UP=1; MOVE_DOWN=2
Asset=function() return {} end
GetModConfigData=function() return 'KEY_F8' end
kleiloadlua=function() return function() return {token='test'} end end
TheNet={IsDedicated=function() return false end}
JapaneseOnPS4=function() return false end
hooks={}; AddClassPostConstruct=function(name,fn) hooks[name]=fn end
function Node()
 local n={children={},shown=true,enabled=true,image={SetSize=function() end,SetTint=function() end,SetScale=function() end},text={SetColour=function() end}}
 n.inst={IsValid=function() return not n.killed end}
 function n:AddChild(child) self.children[#self.children+1]=child; child.parent=self; return child end
 for _,name in ipairs({'SetNormalScale','SetFocusScale','SetFont','SetTextSize','SetTextColour','SetTooltip','SetOnGainFocus'}) do n[name]=function() end end
 function n:SetPosition(x,y,z) if type(x)=='table' then self.x,self.y,self.z=x.x,x.y,x.z else self.x,self.y,self.z=x,y,z end end
 function n:GetPosition() return {x=self.x or 0,y=self.y or 0,z=self.z or 0} end
 function n:SetScale(v) self.scale=v end
 function n:Kill() self.killed=true end
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
package.preload['widgets/button']=function() return Node end
package.preload['widgets/text']=function() return Node end
package.preload['widgets/widget']=function()
 return Class(function(self) for k,v in pairs(Node()) do self[k]=v end end)
end
Vector3=function(x,y,z) return {x=x,y=y,z=z} end
package.preload['widgets/redux/templates']=function()
 local function button(fn,text,size) local n=Node();n.onclick=fn;n.text=text;n.nativeStyle=true;n.size=size;return n end
 return {StandardButton=button,MenuButton=function(text,fn) return button(fn,text) end}
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
  local s={name='MusicScreen',view=view,controller=controller}
  function s:Close() self.closed=true;TheFrontEnd.active=TheFrontEnd.previous;onclose() end
  return s
 end
end
TheInput={handlers={}}
function TheInput:ControllerAttached() return false end
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
lua.globals().NativeMenu = lua.execute(menu_source)
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
assert(not hooks['screens/redux/optionsscreen'],'native options grid must remain untouched')
local tasks={}
local pause={name='PauseScreen',bg={body={SetRegionSize=function() end}},inst={DoTaskInTime=function(_,_,fn) tasks[#tasks+1]=fn end}}
function pause.bg:GetSize() return 190,self.height end
function pause.bg:SetSize(_,height) self.height=height end
function pause:BuildMenu()
 if self.menu then self.menu:Kill() end
 self.menu=NativeMenu({},-50,false,'carny_xlong',nil,30)
 for i=1,9 do self.menu:AddItem('Existing '..i,function() end) end
 self.options_button_index=4;self.pause_button_index=2;self.scrapbook_button_index=7
 return 'preserved'
end
pause:BuildMenu();TheFrontEnd.active=pause
hooks['screens/redux/pausescreen'](pause)
local entry=pause.menu._dangomusic_button
assert(#pause.menu.items==10 and pause.menu.items[10]==entry and entry.text=='音乐播放器')
assert(entry.focusDirs[MOVE_UP]==pause.menu.items[9] and pause.menu.items[9].focusDirs[MOVE_DOWN]==entry)
entry.onclick()
assert(c.reconnects==1 and TheFrontEnd.active.view=='connection' and pause.last_focus==entry)
TheFrontEnd.active:Close();c.backendConnected=true;entry.onclick()
assert(c.reconnects==1 and TheFrontEnd.active.view=='settings','online entry must not invalidate caches by reconnecting')
TheFrontEnd.active:Close()
-- Another mod appends an entry after our constructor hook. The next-frame
-- layout keeps it in the list and leaves the native callback indexes intact.
pause.menu:AddItem('Other mod',function() end)
for _,fn in ipairs(tasks) do fn() end;tasks={}
assert(#pause.menu.items==11 and pause.menu.items[11].text=='Other mod')
assert(pause.options_button_index==4 and pause.pause_button_index==2 and pause.scrapbook_button_index==7)
assert(pause.menu.items[1].y-pause.menu.items[11].y<=450 and pause.bg.height<=500)
assert(pause.menu.items[10].focusDirs[MOVE_DOWN]==pause.menu.items[11])
local old=pause.menu
assert(pause:BuildMenu()=='preserved' and old.killed)
assert(#pause.menu.items==10 and pause.menu._dangomusic_button~=entry,'rebuilt menu needs exactly one new entry')
for _,fn in ipairs(tasks) do fn() end
local saved=ThePlayer;ThePlayer=nil
local outOfWorld={BuildMenu=function() end}
hooks['screens/redux/pausescreen'](outOfWorld)
assert(outOfWorld.menu==nil)
ThePlayer=saved
pause.menu._dangomusic_button.onclick()
c.settings.player.showTopLeftButton=true;c:Notify()
assert(button.shown and button.enabled)
local panel=TheFrontEnd.active
controls.inst.onremove()
assert(panel.closed and c.closed and controls.dangomusic==nil and controls.OpenDangoMusic==nil)
for _,h in ipairs(TheInput.handlers) do assert(h.removed) end

-- 主菜单没有 ThePlayer/HUD；入口仍可打开完整播放器并成对释放控制器。
ThePlayer=nil
local mainTasks={}
local main={menu=NativeMenu({},38,false),inst={ListenForEvent=function(self,name,fn) self[name]=fn end,
    DoStaticTaskInTime=function(_,_,fn) mainTasks[#mainTasks+1]=fn end}}
main.menu:AddItem('原有入口',function() end)
local foreign=main.menu:AddChild(Node());foreign:SetPosition(0,38,0)
TheFrontEnd.active=main
hooks['screens/redux/multiplayermainscreen'](main)
local mainButton=main.menu._dangomusic_button
assert(mainButton and mainButton.nativeStyle and #main.menu.items==2)
assert(mainButton:GetPosition().y==76,'避让未登记到 items 的菜单控件')
foreign:SetPosition(0,76,0)
for _,fn in ipairs(mainTasks) do fn() end
assert(mainButton:GetPosition().y==114,'其他构造钩子晚添加入口后仍保留间距')
hooks['screens/redux/multiplayermainscreen'](main)
assert(#main.menu.items==2,'同一菜单不可重复挂入口')
mainButton.onclick()
local first=TheFrontEnd.active
assert(first.name=='MusicScreen' and main.last_focus_widget==mainButton)
first:Close();assert(first.controller.closed and TheFrontEnd.active==main)
mainButton.onclick();local second=TheFrontEnd.active
assert(second~=first and not second.controller.closed)
main.inst.onremove()
assert(second.closed and second.controller.closed)
TheFrontEnd.active=main;mainButton.onclick();assert(TheFrontEnd.active==main,'销毁后不再创建请求')
''')
print('PASS: HUD visibility, native ESC menu and focus, late mod entries, rebuild, offline recovery, HUD cleanup')
