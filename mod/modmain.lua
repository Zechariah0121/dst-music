local G = GLOBAL
if G.TheNet:IsDedicated() then return end

local MusicScreen = G.require("screens/dangomusicscreen")
local Controller = G.require("dangomusic_controller")
local MusicLyrics = G.require("widgets/music_lyrics")
local MusicSongCard = G.require("widgets/music_songcard")
local MusicIsland = G.require("widgets/music_island")
local ImageButton = G.require("widgets/imagebutton")
local TEMPLATES = G.require("widgets/redux/templates")
local UI = G.require("widgets/music_ui_common")
UI.atlas = MODROOT.."images/music/ui.xml"
Assets = {
    Asset("ATLAS", "images/music/ui.xml"),
    Asset("IMAGE", "images/music/ui.tex"),
}
local keyname = GetModConfigData("toggle_key")
if keyname == nil then keyname = "KEY_F8" end
local key = keyname and G[keyname] or nil

-- mods.lua modimport discards return values. Load this local generated table
-- explicitly instead. Do not log its contents or put credentials in modinfo.
local function LoadConnection()
    local ok, chunk = G.pcall(G.kleiloadlua, MODROOT .. "scripts/dangomusic_connection.lua")
    if not ok or G.type(chunk) ~= "function" then return nil end
    local loaded, value = G.pcall(chunk)
    return loaded and G.type(value) == "table" and value or nil
end

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

-- Keep a recovery route when the HUD entry is hidden or its key conflicts
-- with another mod. This only extends the in-world ESC options instance.
AddClassPostConstruct("screens/redux/optionsscreen", function(screen)
    local player=G.ThePlayer
    local controls=player and player.HUD and player.HUD.controls
    local controller=controls and controls.dangomusic
    local settingsroot=screen.subscreener and screen.subscreener.sub_screens.settings
    if not controller or not settingsroot or
        not G.TheFrontEnd:GetOpenScreenOfType("PauseScreen") then return end
    -- Native settings have nine rows in the left column and a divider at
    -- y=-225. Keep these actions inside that tab, below the existing rows.
    local connect=settingsroot:AddChild(TEMPLATES.StandardButton(function()
        if controls.OpenDangoMusic and controls:OpenDangoMusic("connection") then controller:Reconnect() end
    end,"一键连接播放器",{300,32}))
    connect:SetPosition(-35,-174)
    connect:SetTextSize(18)
    connect:SetTooltip("重新读取一键启动器生成的连接，已进入世界也无需重启。首次请先双击工坊目录的一键启动播放器。")
    local settings=settingsroot:AddChild(TEMPLATES.StandardButton(function()
        if controls.OpenDangoMusic then controls:OpenDangoMusic("settings") end
    end,"音乐设置 / 打开播放器",{300,32}))
    settings:SetPosition(-35,-210)
    settings:SetTextSize(18)
    settings:SetTooltip("调整音乐界面与歌词；即使隐藏左上角按钮也能从这里打开。")
    local last=screen.left_spinners and screen.left_spinners[#screen.left_spinners]
    if last and last.parent then
        last.parent:SetFocusChangeDir(G.MOVE_DOWN,connect)
        connect:SetFocusChangeDir(G.MOVE_UP,last.parent)
    end
    connect:SetFocusChangeDir(G.MOVE_DOWN,settings)
    settings:SetFocusChangeDir(G.MOVE_UP,connect)
end)
