local Widget = require "widgets/widget"
local Text = require "widgets/text"
local U = require "widgets/music_hudutil"

local Island = Class(Widget, function(self, controller, owner)
    Widget._ctor(self, "MusicIsland")
    self.controller, self.owner = controller, owner
    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_TOP)
    self:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self:SetMaxPropUpscale(MAX_HUD_SCALE)
    self:SetClickable(false)
    self.root = self:AddChild(Widget("island"))
    self.bg = U.Rect(self.root, controller, "pill", 350, 64, {.035, .04, .07, .95})
    self.cover = U.Rect(self.root, controller, "card", 42, 42)
    U.Position(self.cover, -142, 0)
    self.label = self.root:AddChild(Text(CHATFONT, 19, ""))
    U.Position(self.label, 19, 9)
    self.status = self.root:AddChild(Text(CHATFONT, 14, "", {.75, .69, .81, 1}))
    U.Position(self.status, 19, -13)
    self.unsubscribe = controller:Subscribe(function() self.dirty = true end)
    self.lastkey = ""
    self.dirty = true
    self:StartUpdating()
    self:OnUpdate(0)
end)
function Island:OnUpdate(dt)
    local settings = self.controller.settings.island or {}
    local player = U.Player(self.controller)
    local key = U.Key(player.track)
    local now = U.Clock()
    if key ~= self.lastkey then
        self.lastkey = key
        self.notifyUntil = now + U.Clamp(settings.notifyTime or 4, 1, 30)
        self.dirty = true
    end
    local notify = settings.songNotify ~= false and now < (self.notifyUntil or 0)
    if settings.enabled == false or not player.track or not U.Alive(self.owner)
        or (settings.showMusic == false and not notify) then
        U.ReleaseArtwork(self.cover,self.controller); self.dirty=true
        U.Show(self, false); return
    end
    U.Show(self, true)
    U.Scale(self, U.Clamp(settings.scale or 1, .4, 3))
    U.Position(self, 0, -49)
    U.Tint(self.bg, .035, .04, .07, settings.glass == false and 1 or .76)
    if self.dirty then
        self.dirty = false
        self.statusDirty = true
        U.Truncated(self.label, U.Title(player.track), 268, 70)
        U.Artwork(self.cover, self.controller, player.track)
        U.Size(self.cover, 42, 42)
    end
    if self.statusDirty or self.statusNotify ~= notify or self.statusPlaying ~= player.playing then
        self.statusDirty = false
        self.statusNotify, self.statusPlaying = notify, player.playing
        U.Truncated(self.status, (notify and "正在播放 · " or (player.playing and "播放中 · " or "已暂停 · ")) .. U.Artist(player.track), 268, 80)
    end
    local appear = notify and math.min(1, ((self.notifyUntil or now) - now) / .3) or 1
    U.Scale(self.root, .96 + .04 * appear)
    U.Position(self.root, 0, 8 * (1 - appear))
end
function Island:Kill()
    if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
    U.ReleaseArtwork(self.cover,self.controller)
    Island._base.Kill(self)
end
return Island
