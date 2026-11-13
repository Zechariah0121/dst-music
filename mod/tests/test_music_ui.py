"""Exercise music appearance lifecycle against the installed DST Lua widgets."""
import argparse
from pathlib import Path
from zipfile import ZipFile

from lupa.lua51 import LuaRuntime


parser = argparse.ArgumentParser()
parser.add_argument("--scripts-zip", required=True)
args = parser.parse_args()
lua = LuaRuntime()
with ZipFile(args.scripts_zip) as source:
    lua.execute(source.read("scripts/class.lua").decode("utf-8-sig"))
    for name in ("widget", "button", "image", "imagebutton", "truescrollarea"):
        code = source.read(f"scripts/widgets/{name}.lua").decode("utf-8-sig")
        lua.globals().package.preload[f"widgets/{name}"] = lua.eval("function(code) return assert(loadstring(code)) end")(code)

lua.execute(r"""
local function noop() end
ValidateLineNumber = noop
DEFAULTFONT = "opensans"
CHATFONT = "bellefair"
NEWFONT = DEFAULTFONT
ANCHOR_MIDDLE = 2
CONTROL_ACCEPT = 1
CONTROL_MOVE_LEFT = 2
CONTROL_MOVE_RIGHT = 3
MOUSEBUTTON_LEFT = 1
STRINGS = {UI={HELP={SELECT="select"}}}
ClickMouseoverSoundReduction = function() return 1 end
FunctionOrValue = function(value) if type(value) == "function" then return value() end return value end
resolvefilepath = function(path) return path end
function Vector3(x,y,z)
    return {x=x,y=y,z=z,Get=function(self) return self.x,self.y,self.z end}
end

local function WorldPosition(inst)
    local parent = inst.parent
    if not parent then return inst.x,inst.y,inst.z end
    local x,y,z = WorldPosition(parent)
    local scale = parent.widget:GetScale()
    return x+inst.x*scale.x,y+inst.y*scale.y,z+inst.z*scale.z
end

metrics = {textures=0}
function CreateEntity()
    local inst = {x=0,y=0,z=0,sx=1,sy=1,sz=1,valid=true}
    inst.components = {uianim={UpdateWhilePaused=noop}}
    inst.AddTag,inst.AddComponent = noop,noop
    inst.IsValid = function() return inst.valid end
    inst.Remove = function() inst.valid = false end
    inst.entity = {
        SetName=noop, AddUITransform=noop, CallPrefabConstructionComplete=noop,
        Show=noop, Hide=noop, AddImageWidget=noop, MoveToBack=noop, MoveToFront=noop,
        SetParent=function(_,entity) inst.parent=entity and entity.inst end,
        SetClickable=function(_,clickable) inst.clickable=clickable end,
        inst=inst,
    }
    inst.UITransform = {
        SetPosition=function(_,x,y,z) inst.x,inst.y,inst.z=x,y,z end,
        GetLocalPosition=function() return inst.x,inst.y,inst.z end,
        GetWorldPosition=function() return WorldPosition(inst) end,
        SetScale=function(_,x,y,z) inst.sx,inst.sy,inst.sz=x,y,z end,
        GetScale=function() return inst.sx,inst.sy,inst.sz end,
        SetScissor=noop, UpdateTransform=noop,
    }
    inst.ImageWidget = {
        SetTexture=function() metrics.textures=metrics.textures+1 end,
        GetSize=function() return 100,100 end,
        SetTint=function() assert(inst.valid) end,
    }
    return inst
end

updating, moveHandlers = {}, {}
TheFrontEnd = {
    StartUpdatingWidget=function(_,widget) updating[widget]=true end,
    StopUpdatingWidget=function(_,widget) updating[widget]=nil end,
    GetActiveScreen=function() return activeScreen end,
    GetFadeLevel=function() return 0 end,
    GetSound=function() return {PlaySound=noop} end,
}
mouseX, mouseY, mouseDown = 0,0,false
TheInput = {
    ResolveVirtualControls=function(_,control) return control end,
    GetScreenPosition=function() return Vector3(mouseX,mouseY,0) end,
    IsMouseDown=function() return mouseDown end,
    AddMoveHandler=function(_,fn)
        moveHandlers[fn]=true
        return {Remove=function() moveHandlers[fn]=nil end}
    end,
}
Lerp = function(a,b,t) return a+(b-a)*t end
math.clamp = function(v,a,b) return math.max(a,math.min(b,v)) end

Widget = require("widgets/widget")
local Text = Class(Widget,function(self) Widget._ctor(self,"text") end)
Text.SetVAlign,Text.SetHAlign,Text.SetSize = noop,noop,noop
Text.SetFont = function(self,font) self.font=font end
Text.SetRegionSize,Text.ResetRegionSize = noop,noop
Text.SetString = function(self,str) self.str=str end
Text.SetTruncatedString = Text.SetString
Text.SetColour = function(self,r,g,b,a)
    self.colour=type(r)=="number" and {r,g,b,a} or r
end
package.preload["widgets/text"] = function() return Text end

function Tick(dt)
    local copy={}
    for widget in pairs(updating) do copy[#copy+1]=widget end
    for _,widget in ipairs(copy) do if widget.enabled then widget:OnUpdate(dt) end end
end

function Move(x,y)
    for fn in pairs(moveHandlers) do fn(x,y) end
end
""")
ui_path = Path(__file__).resolve().parents[1] / "scripts/widgets/music_ui_common.lua"
lua.globals().UI = lua.execute(ui_path.read_text(encoding="utf8"))
lua.execute(r"""
local root=Widget("screen")
root.is_screen=true
activeScreen=root
local shell=UI.Panel(root,0,0,1190,660,nil,"shell")
local sheen=UI.Panel(root,0,0,1190,660,nil,"sheen")
local old=shell.tint
UI.AnimateGlass(root,sheen)
assert(next(moveHandlers) and not next(updating))
local clicked=0
local row=root:AddChild(Widget("row"))
local button=UI.Button(row,"play",0,0,60,26,function() clicked=clicked+1 end)
button:SetMusicColours("selected","selectedFocus")
local label=UI.Label(root,"title",0,0,100,18,"accent")
local slider=UI.Slider(root,0,0,100,.25,0,1,false,function() error("hidden drag committed") end)
local toggle=UI.Toggle(root,false,0,0,function() end)
local action=UI.Button(root,"重新连接",0,0,180,38,function() end,true)
local function Luminance(r,g,b)
    local function Linear(c)
        return c <= .04045 and c/12.92 or ((c+.055)/1.055)^2.4
    end
    return .2126*Linear(r)+.7152*Linear(g)+.0722*Linear(b)
end
local function Contrast(text,background)
    local opacity=text[4]
    local r,g,b=unpack(background)
    local textLight=Luminance(Lerp(r,text[1],opacity),Lerp(g,text[2],opacity),Lerp(b,text[3],opacity))
    return (textLight+.05)/(Luminance(r,g,b)+.05)
end
for _,theme in ipairs({"netease","qq"}) do
    UI.SetTheme(root,theme)
    assert(action.text.font==CHATFONT and action.fontdisabled==CHATFONT)
    assert(Contrast(action.text.colour,action.image.tint)>7)
    action:SetFocus()
    Tick(.25)
    assert(Contrast(action.text.colour,action.image.tint)>5)
    action:Select()
    assert(Contrast(action.text.colour,action.image.tint)>5)
    action:Unselect()
    action:Disable()
    assert(action.text.font==CHATFONT and action.text.colour[4]==UI.Theme(root).muted[4])
    action:Enable()
    action:ClearFocus()
    Tick(.25)
end
action:Select()
UI.SetTheme(root,"netease")
assert(action.image.tint[1]>action.image.tint[2])
UI.SetTheme(root,"qq")
assert(action.image.tint[2]>action.image.tint[1])
action:Unselect()
UI.SetTheme(root,"qq")
assert(old[1]>shell.tint[1] and shell.tint[2]>shell.tint[1])
assert(label.colour[2]>label.colour[1])
assert(slider.fill.tint[2]>slider.fill.tint[1])
assert(button.imagenormalcolour[2]>button.imagenormalcolour[1])

button:SetFocus()
local textureCount=metrics.textures
assert(updating[button.image] and button.image.tint[4]==.65)
Tick(.025)
assert(button.image.tint[4]>.65 and button.image.tint[4]<.76)
assert(metrics.textures==textureCount)
button:OnControl(CONTROL_ACCEPT,true)
button:OnControl(CONTROL_ACCEPT,false)
assert(clicked==1)
row:Hide()
Tick(.025)
assert(not updating[button.image] and button.image.tint[4]==.65)
assert(not button:OnControl(CONTROL_ACCEPT,true))
row:Show()
button:ClearFocus()
button:SetFocus()
button:Disable()
assert(not updating[button.image] and button.image.tint[4]==.30)
button:Enable()
Tick(.25)
assert(not updating[button.image] and button.image.tint[4]==.76)
button:SetImageNormalColour({.25,.30,.35,.12})
button:ClearFocus()
Tick(.25)
assert(button.image.tint[4]==.12)

slider.rail:SetFocus()
mouseX,mouseDown=25,true
assert(slider.rail:OnControl(CONTROL_ACCEPT,true))
assert(slider.dragging and slider.value==.75)
slider.rail:Disable()
assert(not slider.dragging and not updating[slider] and slider.value==.25)

toggle:SetValue(true)
local dot
for widget in pairs(updating) do
    if widget.parent==toggle then dot=widget end
end
assert(dot and dot:GetPosition().x==-7)
Tick(.05)
assert(dot:GetPosition().x>-7 and dot:GetPosition().x<7)
Tick(.25)
assert(dot:GetPosition().x==7 and not updating[dot])

local area = root:AddChild(require("widgets/truescrollarea")(
    {widget=Widget("scroll_body"),offset={x=0,y=0},size={width=100,height=400}},
    {x=-50,y=-50,width=100,height=100}))
UI.ScrollStyle(area,-50,50)
assert(not updating[area])
local clipped=UI.Button(area.context_root,"",0,90,40,24,function() error("clipped click") end)
clipped:SetFocus()
assert(not updating[clipped.image] and not clipped:OnControl(CONTROL_ACCEPT,true))
area:Scroll(60)
assert(updating[area])
Tick(.016)
assert(area.current_scroll_pos>0 and area.current_scroll_pos<60)
for i=1,40 do Tick(.016) end
assert(area.current_scroll_pos==60 and not updating[area])
area:Scroll(-9999)
assert(area.target_scroll_pos==0)

Move(400,120)
assert(updating[sheen])
Tick(.05)
assert(sheen:GetPosition().x>0 and sheen:GetPosition().x<21)
for i=1,80 do Tick(.02) end
assert(not updating[sheen])
Move(-400,-120)
assert(updating[sheen])
activeScreen=nil
Tick(.02)
assert(not updating[sheen])
activeScreen=root
Move(-400,-120)
assert(updating[sheen])
root:Kill()
Tick(.02)
assert(not next(updating) and not next(moveHandlers))
print("PASS: real DST Widget/ImageButton/TrueScrollArea theme, focus, clipping, animation and teardown")
""")
