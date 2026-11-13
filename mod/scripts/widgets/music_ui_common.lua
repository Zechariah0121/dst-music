local Widget = require("widgets/widget")
local Image = require("widgets/image")
local ImageButton = require("widgets/imagebutton")
local Text = require("widgets/text")
local UI = {}
UI.atlas = "images/music/ui.xml"

local INK = {.98,.98,1,.96}
local MUTED = {.96,.96,1,.67}
local DIM = {.95,.95,1,.40}
local LINE = {1,1,1,.12}
local BUTTON = {1,1,1,.055}
local BUTTON_FOCUS = {1,1,1,.13}
local RAIL = {1,1,1,.21}
local TOGGLE_OFF = {.60,.62,.66,.47}
local TOGGLE_OFF_FOCUS = {.68,.70,.74,.64}

local PALETTES = {
    netease = {
        accent = {1,.216,.373,1},
        accentFocus = {1,.36,.49,1},
        accentButton = {.561,.133,.290,1},
        accentButtonFocus = {.667,.200,.357,1},
        shell = {.225,.119,.193,.96},
        shell_rim = {1,.67,.77,.38},
        sidebar = {.37,.26,.37,.49},
        player = {.33,.24,.34,.87},
        ambient = {1,.25,.48,.38},
        sheen = {1,.39,.55,.29},
        selected = {.61,.24,.35,.65},
        selectedFocus = {.79,.32,.44,.76},
        placeholder = {.29,.20,.30,.94},
        coverAccent = {.49,.25,.36,1},
    },
    qq = {
        accent = {.192,.761,.486,1},
        accentFocus = {.32,.86,.58,1},
        accentButton = {.082,.345,.247,1},
        accentButtonFocus = {.133,.408,.278,1},
        shell = {.098,.205,.185,.96},
        shell_rim = {.61,1,.81,.38},
        sidebar = {.20,.36,.32,.49},
        player = {.15,.32,.29,.87},
        ambient = {.24,.85,.58,.38},
        sheen = {.29,1,.69,.29},
        selected = {.19,.51,.37,.65},
        selectedFocus = {.27,.66,.47,.76},
        placeholder = {.15,.29,.24,.94},
        coverAccent = {.22,.41,.32,1},
    },
}
for _, palette in pairs(PALETTES) do
    palette.ink, palette.muted, palette.dim = INK, MUTED, DIM
    palette.accentInk = INK
    palette.line, palette.rail = LINE, RAIL
    palette.button, palette.buttonFocus = BUTTON, BUTTON_FOCUS
    palette.card, palette.cardFocus = BUTTON, BUTTON_FOCUS
    palette.toggleOff, palette.toggleOffFocus = TOGGLE_OFF, TOGGLE_OFF_FOCUS
end
UI.ink, UI.muted, UI.pink = INK, MUTED, PALETTES.netease.accent

function UI.Theme(widget)
    while widget do
        if widget.musicTheme then return widget.musicTheme end
        widget = widget.parent
    end
    return PALETTES.netease
end

function UI.Accent(widget)
    return UI.Theme(widget).accent
end

local function ResolveColour(colour, palette)
    if colour == UI.pink then return palette.accent end
    if type(colour) == "string" then return palette[colour] end
    return colour
end

function UI.BindTheme(widget, apply)
    widget.musicApplyTheme = apply
    apply(widget, UI.Theme(widget))
end

local function RefreshTheme(widget, inherited)
    local palette = widget.musicTheme or inherited
    if widget.musicApplyTheme then widget.musicApplyTheme(widget, palette) end
    for _, child in pairs(widget.children) do
        RefreshTheme(child, palette)
    end
end

function UI.RefreshTheme(widget)
    RefreshTheme(widget, UI.Theme(widget))
end

function UI.SetTheme(root, name)
    local palette = PALETTES[name] or PALETTES.netease
    if root.musicTheme == palette then return end
    root.musicTheme = palette
    UI.RefreshTheme(root)
end

local MATERIAL = {
    shell="shell", shell_rim="shell_rim", sidebar="sidebar", player="player",
    ambient="ambient", selected="selected", sheen="sheen", glass_card="card",
    glass_button="button", glass_pill="button",
}

function UI.Panel(parent,x,y,w,h,tint,texture)
    texture = texture=="card" and "glass_card" or texture=="pill" and "glass_pill" or texture or "panel"
    local im = parent:AddChild(Image(UI.atlas,texture..".tex"))
    im:SetClickable(false) -- decorative surfaces must not win the frontend mouse hit test
    im:SetPosition(x,y); im:ScaleToSize(w,h)
    local material = MATERIAL[texture]
    if material or type(tint) == "string" or tint == UI.pink then
        local alpha = 1
        if material and type(tint) == "table" and tint ~= UI.pink then
            -- Fixed-colour materials previously accepted an alpha override only.
            alpha = tint[4] or 1
            tint = material
        end
        UI.BindTheme(im,function(widget,palette)
            local c = ResolveColour(tint or material,palette)
            widget:SetTint(c[1],c[2],c[3],c[4]*alpha)
        end)
    else
        im:SetTint(unpack(tint or {.08,.10,.16,.94}))
    end
    if texture == "shell" then
        local sw,sh = im:GetSize()
        UI.Panel(im,0,0,sw,sh,nil,"shell_rim")
    elseif texture == "sheen" then
        im.musicGlassBounds = {x=x,y=y,w=w,h=h}
    end
    im:MoveToBack()
    return im
end
function UI.Label(parent,text,x,y,w,size,colour,align)
    local t=parent:AddChild(Text(DEFAULTFONT,size or 20,tostring(text or "")))
    t:SetClickable(false)
    t:SetPosition(x+(align == ANCHOR_MIDDLE and 0 or w/2),y); t:SetHAlign(align or ANCHOR_LEFT)
    -- Vanilla truncation measures the automatic region; an explicitly sized
    -- region reports its assigned width and may never shrink in the loop.
    local setstring=t.SetString
    function t:SetString(str)
        str=tostring(str or "")
        if self.musicString==str then return end
        self.musicString=str; self.musicTruncated=nil
        return setstring(self,str)
    end
    function t:SetTruncatedString(str,width,maxchars,ellipses)
        str=tostring(str or ""); width=width or w; maxchars=maxchars or 160
        local old=self.musicTruncated
        if old and old[1]==str and old[2]==width and old[3]==maxchars and old[4]==ellipses then return old[5] end
        self.musicString=nil
        self:ResetRegionSize()
        local fits=Text.SetTruncatedString(self,str,width,maxchars,ellipses)
        self:SetRegionSize(width,32)
        self.musicTruncated={str,width,maxchars,ellipses,fits}
        return fits
    end
    if type(colour) == "string" or colour == UI.pink then
        UI.BindTheme(t,function(widget,palette) widget:SetColour(unpack(ResolveColour(colour,palette))) end)
    else
        t:SetColour(unpack(colour or UI.ink))
    end
    t:SetTruncatedString(tostring(text or ""),w,160,true)
    return t
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function CanAnimate(widget)
    if not (widget:IsVisible() and widget:IsEnabled()) then return false end
    local parent = widget
    while parent do
        if parent.shown == false then return false end
        local clip = parent.musicScrollBounds
        if clip and widget.musicButtonHeight then
            local origin = parent:GetWorldPosition()
            local p = widget:GetWorldPosition()
            local halfHeight = widget.musicButtonHeight * math.abs(widget:GetScale().y) / 2
            local scale = parent:GetScale().y
            if p.y + halfHeight <= origin.y + clip.bottom * scale
                or p.y - halfHeight >= origin.y + clip.top * scale then return false end
        end
        if parent.is_screen then return TheFrontEnd:GetActiveScreen() == parent end
        parent = parent.parent
    end
    return true
end

local function StopMotion(image)
    if image.musicMotion then
        image.musicMotion = nil
        image:StopUpdating()
    end
end

local function UpdateMotion(image, dt)
    local motion = image.musicMotion
    if not motion then return end -- FrontEnd iterates a copy of its update set.
    if not image.inst:IsValid() then StopMotion(image); return end
    local active = CanAnimate(motion.owner)
    local t = active and math.min(1,motion.elapsed + dt / motion.duration) or 1
    motion.elapsed = t
    motion.apply(1 - (1-t)^3,active)
    if t == 1 then StopMotion(image) end
end

local function StartMotion(image, owner, duration, apply)
    if not CanAnimate(owner) then
        StopMotion(image)
        apply(1,false)
        return
    end
    image.musicMotion = {owner=owner,duration=duration,elapsed=0,apply=apply}
    image.OnUpdate = UpdateMotion
    image:StartUpdating()
end

local function SetButtonTint(button, previous, focused)
    local image = button.image
    StopMotion(image)
    if not button:IsEnabled() or button:IsSelected() then return end
    local colour = focused and button.musicFocusColour or button.musicNormalColour
    if previous and colour and (previous[1]~=colour[1] or previous[2]~=colour[2]
        or previous[3]~=colour[3] or previous[4]~=colour[4]) then
        image:SetTint(unpack(previous))
        StartMotion(image,button,focused and .12 or .16,function(t,active)
            if not active then image:SetTint(unpack(button.musicNormalColour)); return end
            image:SetTint(
                previous[1]+(colour[1]-previous[1])*t,
                previous[2]+(colour[2]-previous[2])*t,
                previous[3]+(colour[3]-previous[3])*t,
                previous[4]+(colour[4]-previous[4])*t)
        end)
    elseif colour then
        image:SetTint(unpack(colour))
    end
end

local function ApplyButtonColours(button,palette)
    local previousFocus = button.musicFocusColour
    button.musicNormalColour = ResolveColour(button.musicNormal,palette)
    button.musicFocusColour = ResolveColour(button.musicFocus,palette)
    ImageButton.SetImageNormalColour(button,unpack(button.musicNormalColour))
    ImageButton.SetImageFocusColour(button,unpack(button.musicFocusColour))
    if previousFocus and button.imageselectedcolour == previousFocus then
        button:SetImageSelectedColour(button.musicFocusColour)
    end
    SetButtonTint(button,nil,button.focus)
end

local function ApplyButtonTheme(button,palette)
    ApplyButtonColours(button,palette)
    local ink = palette.ink
    button:SetTextColour(unpack(ink))
    button:SetTextFocusColour(unpack(ink))
    button:SetTextDisabledColour(unpack(palette.muted))
end

local function SetMusicColours(button,normal,focused)
    if normal == button.musicNormal and focused == button.musicFocus then return end
    button.musicNormal, button.musicFocus = normal, focused
    ApplyButtonColours(button,UI.Theme(button))
end

local function SetNormalColour(button,r,g,b,a)
    SetMusicColours(button,type(r)=="table" and r or {r,g,b,a},button.musicFocus)
end

local function SetFocusColour(button,r,g,b,a)
    SetMusicColours(button,button.musicNormal,type(r)=="table" and r or {r,g,b,a})
end

local function GainButtonFocus(button)
    local previous = button.image.tint
    ImageButton.OnGainFocus(button)
    SetButtonTint(button,previous,true)
end

local function LoseButtonFocus(button)
    local previous = button.image.tint
    ImageButton.OnLoseFocus(button)
    SetButtonTint(button,previous,false)
end

local function HideButton(button,wasVisible)
    if wasVisible then button:ClearFocus() end
    SetButtonTint(button,nil,false)
    ImageButton.OnHide(button,wasVisible)
end

-- Move a low-opacity, soft specular layer inside the stationary shell.
-- The move listener only supplies new targets; the update ends at rest.
function UI.AnimateGlass(owner,image)
    local bounds = image.musicGlassBounds
    if not bounds or image.musicMoveHandler then return end
    image.musicGlassX, image.musicGlassY = bounds.x,bounds.y
    local targetX,targetY = bounds.x,bounds.y
    local lastX,lastY
    local onMove = function(x,y)
        if not CanAnimate(owner) or not image:IsVisible() then return end
        if x == lastX and y == lastY and (image.musicGlassMoving
            or targetX == image.musicGlassX and targetY == image.musicGlassY) then return end
        lastX,lastY = x,y
        local centre = owner:GetWorldPosition()
        local scale = owner:GetScale()
        local px = (x-centre.x)/math.max(.001,scale.x)-bounds.x
        local py = (y-centre.y)/math.max(.001,scale.y)-bounds.y
        targetX = bounds.x + Clamp(px/bounds.w,-.5,.5)*42
        targetY = bounds.y + Clamp(py/bounds.h,-.5,.5)*24
        if not image.musicGlassMoving and (math.abs(targetX-image.musicGlassX) > .05 or math.abs(targetY-image.musicGlassY) > .05) then
            image.musicGlassMoving = true
            image:StartUpdating()
        end
    end
    image.OnUpdate = function(self,dt)
        if not self.musicGlassMoving then return end
        if not self.inst:IsValid() or not CanAnimate(owner) or not self:IsVisible() then
            self.musicGlassMoving = false
            lastX,lastY = nil,nil
            self:StopUpdating()
            return
        end
        local amount = 1 - math.exp(-dt / .11)
        self.musicGlassX = self.musicGlassX + (targetX-self.musicGlassX)*amount
        self.musicGlassY = self.musicGlassY + (targetY-self.musicGlassY)*amount
        if math.abs(targetX-self.musicGlassX) <= .05 and math.abs(targetY-self.musicGlassY) <= .05 then
            self.musicGlassX,self.musicGlassY = targetX,targetY
            self.musicGlassMoving = false
            self:StopUpdating()
        end
        self:SetPosition(self.musicGlassX,self.musicGlassY)
    end
    image.musicMoveHandler = TheInput:AddMoveHandler(onMove)
    local kill = image.Kill
    image.Kill = function(self)
        self.musicMoveHandler:Remove()
        self.musicMoveHandler = nil
        self.musicGlassMoving = false
        kill(self)
    end
end

local function DisableButton(button)
    StopMotion(button.image)
    ImageButton.OnDisable(button)
end

local function SelectButton(button)
    StopMotion(button.image)
    if not button.imageselectedcolour then button:SetImageSelectedColour(button.musicFocusColour) end
    if button.textselectedcolour == button.musicInitialSelectedInk then
        button:SetTextSelectedColour(unpack(UI.Theme(button).ink))
    end
    ImageButton.OnSelect(button)
end

local function ControlButton(button,control,down)
    if not CanAnimate(button) then
        if button.down then button:ClearFocus() end
        return false
    end
    return ImageButton.OnControl(button,control,down)
end

function UI.Button(parent,text,x,y,w,h,fn,accent)
    local texture=accent and "button.tex" or "glass_button.tex"
    local b=parent:AddChild(ImageButton(UI.atlas,texture,texture,texture))
    b:SetPosition(x,y); b:ForceImageSize(w,h or 32); b.scale_on_focus=false; b.move_on_click=false
    b.musicButtonHeight = h or 32
    b.musicInitialSelectedInk = b.textselectedcolour
    b.musicNormal = accent and "accentButton" or "button"
    b.musicFocus = accent and "accentButtonFocus" or "buttonFocus"
    b.SetMusicColours = SetMusicColours
    b.SetImageNormalColour, b.SetImageFocusColour = SetNormalColour, SetFocusColour
    b.OnGainFocus, b.OnLoseFocus = GainButtonFocus, LoseButtonFocus
    b.OnHide, b.OnDisable, b.OnSelect, b.OnControl = HideButton, DisableButton, SelectButton, ControlButton
    b:SetImageDisabledColour(.32,.34,.39,.30)
    -- CHATFONT uses the plain CJK fallback. DEFAULTFONT adds a baked outline.
    b:SetFont(CHATFONT); b:SetText(text); b:SetTextSize(18); b:SetDisabledFont(CHATFONT); b:SetOnClick(fn)
    UI.BindTheme(b,ApplyButtonTheme)
    if b.text then b.text:SetTruncatedString(text,w-14,100,true) end
    return b
end
-- Mouse coordinates and Widget:GetWorldPosition use the same screen space.
-- GetScale includes ScreenRoot's proportional scaling (current vanilla Widget).
function UI.Slider(parent,x,y,w,value,min,max,integer,oncommit)
    local s=parent:AddChild(Widget("music_slider")); s:SetPosition(x,y)
    s.min,s.max=min,max; s.width=w
    local rail=UI.Button(s,"",0,0,w,24,function() end)
    rail:SetImageNormalColour(0,0,0,.01); rail:SetImageFocusColour(.3,.3,.4,.15)
    UI.Panel(s,0,0,w,3,"rail","square")
    s.fill=UI.Panel(s,0,0,1,3,"accent","square"); s.fill:MoveToFront()
    s.dot=UI.Panel(s,0,0,10,10,"ink","circle"); s.dot:MoveToFront()
    function s:SetValue(v)
        v=math.max(min,math.min(max,tonumber(v) or min))
        if self.value==v then return false end
        self.value=v
        local f=(self.value-min)/math.max(.00001,max-min)
        self.fill:ScaleToSize(math.max(.5,w*f),3); self.fill:SetPosition(-w/2+w*f/2,0); self.dot:SetPosition(-w/2+w*f,0)
        return true
    end
    function s:ReadMouse()
        local px=TheInput:GetScreenPosition().x; local origin=self:GetWorldPosition().x; local scale=self:GetScale().x
        local f=math.max(0,math.min(1,(px-origin)/math.max(.001,scale)/w+.5))
        local v=min+f*(max-min); if integer then v=math.floor(v+.5) else v=math.floor(v*100+.5)/100 end
        if self:SetValue(v) and self.onpreview then self.onpreview(v) end
    end
    function s:Commit()
        if self.value~=self.committedValue then
            self.committedValue=self.value
            oncommit(self.value)
        end
    end
    function s:CancelDrag()
        if not self.dragging then return end
        self.dragging=false
        self:StopUpdating()
        if self:SetValue(self.committedValue) and self.onpreview then self.onpreview(self.value) end
    end
    local old=rail.OnControl
    rail.OnControl=function(button,control,down)
        if not button.focus or not CanAnimate(button) then return false end
        if control==CONTROL_ACCEPT and button.focus then
            if down then if not s.dragging then s.committedValue=s.value end; s.dragging=true; s:ReadMouse(); s:StartUpdating()
            elseif s.dragging then s:ReadMouse(); s.dragging=false; s:StopUpdating(); s:Commit() end
            return true
        end
        if not down and (control==CONTROL_MOVE_LEFT or control==CONTROL_MOVE_RIGHT) then
            s.committedValue=s.value
            s:SetValue(s.value+(control==CONTROL_MOVE_RIGHT and 1 or -1)*(integer and 1 or (max-min)/20)); s:Commit(); return true
        end
        return old(button,control,down)
    end
    s.OnUpdate=function(self)
        if self.dragging then
            if not self.inst:IsValid() then self:StopUpdating(); return end
            if not CanAnimate(rail) then self:CancelDrag(); return end
            self:ReadMouse()
            if not TheInput:IsMouseDown(MOUSEBUTTON_LEFT) then self.dragging=false; self:StopUpdating(); self:Commit() end
        end
    end
    s.OnHide=s.CancelDrag
    s.OnDisable=s.CancelDrag
    rail.OnDisable=function(button)
        s:CancelDrag()
        DisableButton(button)
    end
    s:SetValue(value); s.committedValue=s.value; s.rail=rail
    return s
end
-- Names are built from the current game's KEY_* constants, not stored codes.
function UI.KeyName(value,followConfig)
    if value==0 then return followConfig and "跟随 Mod 配置" or "未绑定" end
    local names={}
    local function add(key,label) local code=rawget(_G,"KEY_"..key); if code~=nil then names[code]=label end end
    for i=65,90 do local letter=string.char(i); add(letter,letter) end
    for i=0,9 do add(tostring(i),tostring(i)); add("KP_"..i,"小键盘 "..i) end
    for i=1,12 do add("F"..i,"F"..i) end
    local named={SPACE="空格",ENTER="回车",TAB="Tab",BACKSPACE="退格",DELETE="Delete",INSERT="Insert",HOME="Home",END="End",PAGEUP="Page Up",PAGEDOWN="Page Down",UP="↑",DOWN="↓",LEFT="←",RIGHT="→",SHIFT="Shift",CTRL="Ctrl",ALT="Alt",LSHIFT="左 Shift",RSHIFT="右 Shift",LCTRL="左 Ctrl",RCTRL="右 Ctrl",LALT="左 Alt",RALT="右 Alt",LSUPER="左 Win",RSUPER="右 Win",ESCAPE="Esc",CAPSLOCK="Caps Lock",PAUSE="Pause",PRINT="Print Screen",SCROLLOCK="Scroll Lock",MINUS="-",EQUALS="=",PERIOD=".",SLASH="/",SEMICOLON=";",LEFTBRACKET="[",RIGHTBRACKET="]",BACKSLASH="反斜杠",TILDE="~",KP_PERIOD="小键盘 .",KP_DIVIDE="小键盘 /",KP_MULTIPLY="小键盘 *",KP_MINUS="小键盘 -",KP_PLUS="小键盘 +",KP_ENTER="小键盘回车",KP_EQUALS="小键盘 ="}
    for key,label in pairs(named) do add(key,label) end
    return names[value] or "自定义键"
end
function UI.Toggle(parent,value,x,y,fn)
    local b=UI.Button(parent,"",x,y,31,18,fn,true)
    b:SetMusicColours(value and "accent" or "toggleOff",value and "accentFocus" or "toggleOffFocus")
    local dotX=value and 7 or -7
    local dot=UI.Panel(b,dotX,0,13,13,{1,1,1,1},"circle"); dot:MoveToFront()
    function b:SetValue(v)
        if self.musicValue==v then return end
        self.musicValue=v
        self:SetMusicColours(v and "accent" or "toggleOff",v and "accentFocus" or "toggleOffFocus")
        local from,to=dotX,v and 7 or -7
        StartMotion(dot,self,.18,function(t)
            dotX=from+(to-from)*t
            dot:SetPosition(dotX,0)
        end)
    end
    b.musicValue=value
    return b
end
function UI.Icon(parent,name,x,y,size)
    local im=parent:AddChild(Image(UI.atlas,"icon_"..name..".tex"))
    im:SetPosition(x,y); im:ScaleToSize(size or 18,size or 18); im:SetClickable(false)
    return im
end
function UI.IconButton(parent,name,x,y,size,fn,tooltip)
    local b=UI.Button(parent,"",x,y,size+14,size+10,fn)
    b.icon=UI.Icon(b,name,0,0,size)
    b:SetTooltip(tooltip or "")
    return b
end
-- Keep vanilla interpolation, row recycling and scrollbar dragging. Wake
-- their updater on input or a changed data range and release it at rest.
function UI.ScrollStyle(list,bottom,top)
    list.up_button:Hide(); list.down_button:Hide()
    UI.BindTheme(list,function(widget,palette)
        widget.scroll_bar_line:SetTint(unpack(palette.line))
        local c = palette.accent
        widget.position_marker:SetImageNormalColour(c[1],c[2],c[3],.48)
        widget.position_marker:SetImageFocusColour(c[1],c[2],c[3],.88)
    end)
    local isGrid = list.SetItemsData ~= nil
    if isGrid then
        list.musicScrollBounds = {bottom=-list.scissor_height/2,top=list.scissor_height/2}
    elseif bottom and top then
        list.musicScrollBounds = {bottom=bottom,top=top}
    end
    local minimum = isGrid and 1 or 0
    local function ClampTarget(widget)
        widget.target_scroll_pos = Clamp(widget.target_scroll_pos,minimum,widget.end_pos or widget.scroll_pos_end)
    end
    local oldScroll, oldUpdate = list.Scroll, list.OnUpdate
    list.Scroll = function(widget,step)
        local handled = oldScroll(widget,step)
        ClampTarget(widget)
        if widget.current_scroll_pos ~= widget.target_scroll_pos then widget:StartUpdating() end
        return handled
    end
    list.OnUpdate = function(widget,dt)
        if not widget.inst:IsValid() or not CanAnimate(widget) then widget:StopUpdating(); return end
        oldUpdate(widget,dt)
        if not isGrid and math.abs(widget.current_scroll_pos-widget.target_scroll_pos) < .04
            and widget.current_scroll_pos ~= widget.target_scroll_pos then
            widget.current_scroll_pos = widget.target_scroll_pos
            widget:RefreshView()
        end
        if widget.current_scroll_pos == widget.target_scroll_pos and widget.control_scroll_repeat_time == nil then
            widget:StopUpdating()
        end
    end
    if isGrid then
        local oldSetItemsData = list.SetItemsData
        list.SetItemsData = function(widget,items)
            oldSetItemsData(widget,items)
            ClampTarget(widget)
            if widget.current_scroll_pos ~= widget.target_scroll_pos then widget:StartUpdating() end
        end
    end
    if list.current_scroll_pos == list.target_scroll_pos then list:StopUpdating() end
end
return UI
