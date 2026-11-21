local G = GLOBAL
if G.TheNet:IsDedicated() then return end

local MusicScreen = G.require("screens/dangomusicscreen")
local Controller = G.require("dangomusic_controller")
local MusicLyrics = G.require("widgets/music_lyrics")
local MusicSongCard = G.require("widgets/music_songcard")
local MusicIsland = G.require("widgets/music_island")
local ImageButton = G.require("widgets/imagebutton")
local UI = G.require("widgets/music_ui_common")
UI.atlas = MODROOT.."images/music/ui.xml"
Assets = {
    Asset("ATLAS", "images/music/ui.xml"),
    Asset("IMAGE", "images/music/ui.tex"),
}
local keyname = GetModConfigData("toggle_key")
if keyname == nil then keyname = "KEY_F8" end
local key = keyname and G[keyname] or nil

-- modimport 不返回加载值；直接读取本机生成的连接表，避免记录其中的凭据。
local function LoadConnection()
    local ok, chunk = G.pcall(G.kleiloadlua, MODROOT .. "scripts/dangomusic_connection.lua")
    if not ok or G.type(chunk) ~= "function" then return nil end
    local loaded, value = G.pcall(chunk)
    return loaded and G.type(value) == "table" and value or nil
end

-- 主菜单同样提供完整播放器，暂停、登录和关闭面板不再依赖进入世界。
AddClassPostConstruct("screens/redux/multiplayermainscreen", function(screen)
    if not screen.menu or screen.menu._dangomusic_button then return end
    local TEMPLATES = G.require("widgets/redux/templates")
    local panel, controller, button
    local dead = false
    local function OpenMusic()
        if dead or G.TheFrontEnd:IsControlsDisabled() then return end
        if panel then
            if G.TheFrontEnd:GetActiveScreen() == panel then panel:Close() end
            return
        end
        if G.TheFrontEnd:GetActiveScreen() ~= screen then return end
        controller = Controller(screen.inst, LoadConnection(), MODROOT, LoadConnection)
        panel = MusicScreen(controller, function()
            panel = nil
            if controller then controller:Close(); controller = nil end
        end)
        screen.last_focus_widget = button
        G.TheFrontEnd:PushScreen(panel)
    end
    button = TEMPLATES.MenuButton("音乐播放器", OpenMusic, "打开播放器、暂停音乐或连接后台，无需进入世界。", screen.tooltip)
    screen.menu:AddCustomItem(button)
    screen.menu._dangomusic_button = button
    local menu = screen.menu
    local function PlaceMainEntry()
        if dead or screen.menu ~= menu or not menu.inst:IsValid() then return end
        local position = button:GetPosition()
        local top = 0
        -- 有些菜单模组只添加子控件、不登记 items；同时避让这类已有入口。
        for _, child in G.pairs(menu.children or {}) do
            if child ~= button and child.GetPosition and child:IsVisible() then
                local point = child:GetPosition()
                if G.math.abs(point.x-position.x) < 100 then top = G.math.max(top, point.y) end
            end
        end
        button:SetPosition(position.x, top+G.math.max(38, menu.offset or 38), position.z)
    end
    PlaceMainEntry()
    -- 等其他构造钩子完成后再核对一次，不在每帧重排原有菜单。
    screen.inst:DoStaticTaskInTime(0, PlaceMainEntry)
    screen.inst:ListenForEvent("onremove", function()
        dead = true
        if panel then panel:Close(); panel = nil end
        if controller then controller:Close(); controller = nil end
    end)
end)

AddClassPostConstruct("widgets/controls", function(controls)
    local panel
    local handlers = {}
    local dead = false
    local controller = Controller(controls.inst, LoadConnection(), MODROOT, LoadConnection)
    controls.dangomusic = controller
    local lyrics = controls:AddChild(MusicLyrics(controller, controls.owner))
    local card = controls:AddChild(MusicSongCard(controller, controls.owner))
    local island = controls:AddChild(MusicIsland(controller, controls.owner))
    local function CanControl()
        local player = G.ThePlayer
        return not dead and player and controls.owner==player and player.HUD
            and G.TheFrontEnd:GetActiveScreen()==player.HUD
            and not player.HUD:HasInputFocus() and not G.TheFrontEnd:IsControlsDisabled()
            and controls:IsVisible()
    end
    local function OpenMusic(view, fromMenu)
        if dead then return end
        local player = G.ThePlayer
        if not player or controls.owner ~= player or not player.HUD then return end
        local active = G.TheFrontEnd:GetActiveScreen()
        if panel then
            if active == panel and not view then panel:Close() end
            return panel
        end
        local menuAllowed=fromMenu and active and (active.name=="OptionsScreen" or active.name=="PauseScreen")
        if not menuAllowed and (active ~= player.HUD or player.HUD:HasInputFocus()
            or G.TheFrontEnd:IsControlsDisabled()
            or not controls:IsVisible()) then return end
        panel = MusicScreen(controller, function() panel = nil end, view)
        G.TheFrontEnd:PushScreen(panel)
        return panel
    end
    local function Toggle() OpenMusic() end
    controls.OpenDangoMusic=function(_,view) return OpenMusic(view,true) end
    local button = controls.topleft_root:AddChild(ImageButton(MODROOT.."images/music/ui.xml", "pill.tex", "pill.tex", "pill.tex", "pill.tex", "pill.tex"))
    button:SetNormalScale(1,1)
    button:SetFocusScale(1.04,1.04)
    button.image:SetSize(86,32)
    button.image:SetTint(.10,.11,.17,.94)
    button:SetText("音乐")
    button:SetFont(G.CHATFONT)
    button:SetTextSize(18)
    button:SetTextColour(.96,.70,.79,1)
    button:SetOnClick(Toggle)
    button:SetPosition(220, -35)
    button:SetTooltip("本机音乐播放器" .. (keyname and (" · " .. G.string.gsub(keyname, "KEY_", "")) or ""))
    local bindingSignature
    local entryVisible=true
    local function BindKeys()
        local prefs = controller.settings.player or {}
        local visible=prefs.showTopLeftButton~=false
        if visible~=entryVisible then
            entryVisible=visible
            if visible then button:Enable(); button:Show()
            else button:ClearFocus(); button:Disable(); button:Hide() end
        end
        local keys = {prefs.openKey and prefs.openKey>0 and prefs.openKey or key or 0,
            prefs.keyPause or 0,prefs.keyPrev or 0,prefs.keyNext or 0,
            prefs.keyVolUp or 0,prefs.keyVolDown or 0,prefs.keyLyrics or 0}
        local signature = G.table.concat(keys, ",")
        if signature==bindingSignature then return end
        bindingSignature = signature
        for _, handle in G.ipairs(handlers) do handle:Remove() end
        handlers = {}
        local actions = {Toggle,
            function() controller:Command({action="toggle"}) end,
            function() controller:Command({action="previous"}) end,
            function() controller:Command({action="next"}) end,
            function() controller:Command({action="volume",value=G.math.min(1,(controller.state.player.volume or .7)+.05)}) end,
            function() controller:Command({action="volume",value=G.math.max(0,(controller.state.player.volume or .7)-.05)}) end,
            function() controller:SetSettings({lyrics={enabled=not (controller.settings.lyrics and controller.settings.lyrics.enabled~=false)}}) end}
        local used={}
        for i, code in G.ipairs(keys) do
            if code>0 and not used[code] then
                local action, isToggle = actions[i], i==1
                used[code] = true
                G.table.insert(handlers, G.TheInput:AddKeyUpHandler(code,function()
                    if isToggle then action() elseif CanControl() then action() end
                end))
            end
        end
    end
    BindKeys()
    local unsubscribe = controller:Subscribe(BindKeys)
    controls.inst:ListenForEvent("onremove", function()
        dead = true
        unsubscribe()
        for _, handler in G.ipairs(handlers) do handler:Remove() end
        handlers={}
        if panel then panel:Close(); panel = nil end
        controller:Close()
        controls.dangomusic=nil
        controls.OpenDangoMusic=nil
    end)
end)

-- A single native ESC entry keeps the game's settings grid unobstructed.
-- BuildMenu can run again after construction, so extend each new menu once.
AddClassPostConstruct("screens/redux/pausescreen", function(screen)
    local player=G.ThePlayer
    local controls=player and player.HUD and player.HUD.controls
    local controller=controls and controls.dangomusic
    if not controller then return end

    local function LayoutMenu(menu)
        if screen.menu~=menu or not menu.inst:IsValid() then return end
        -- Leave room for the title and help text even when other mods append
        -- entries. Keep the native spacing while the list fits ten rows.
        local step=G.math.min(-menu.offset,450/G.math.max(1,#menu.items-1))
        menu.offset=-step
        for i,item in G.ipairs(menu.items) do item:SetPosition(0,-step*(i-1),0) end
        local pos=menu:GetPosition()
        menu:SetPosition(pos.x,step*(#menu.items-1)/2,pos.z)
        local height=G.math.min(500,step*#menu.items+30)
        local width=screen.bg:GetSize()
        screen.bg:SetSize(width,height)
        screen.bg.body:SetRegionSize(width,height)
        if screen.feedback_hint then screen.feedback_hint:SetPosition(0,-height/2-80,0) end
        if screen.feedback_shadow then screen.feedback_shadow:SetPosition(2,-height/2-82,0) end
    end

    local function AttachToMenu()
        local menu=screen.menu
        if not menu or menu._dangomusic_button then return end
        local button
        button=menu:AddItem("音乐播放器",function()
            if not controls.OpenDangoMusic then return end
            screen.last_focus=button
            local online=controller.backendConnected==true
            if controls:OpenDangoMusic(online and "settings" or "connection") and not online then controller:Reconnect() end
        end)
        menu._dangomusic_button=button
        button:SetScale(.7)
        button:SetTooltip("打开音乐设置与播放器；后台离线时进入一键连接页面。")
        LayoutMenu(menu)
        -- Other constructor hooks may append their own items after ours.
        screen.inst:DoTaskInTime(0,function() LayoutMenu(menu) end)
    end
    local previous=screen.BuildMenu
    screen.BuildMenu=function(self,...)
        local function Finish(...)
            AttachToMenu()
            return ...
        end
        return Finish(previous(self,...))
    end
    AttachToMenu()
end)
