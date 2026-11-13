local Widget = require "widgets/widget"
local Text = require "widgets/text"
local U = require "widgets/music_hudutil"

-- Mount directly on Controls (the same coordinate root as FollowText).
local SongCard = Class(Widget, function(self, controller, owner)
    Widget._ctor(self, "MusicSongCard")
    self.controller, self.owner = controller, owner
    self:SetHAnchor(ANCHOR_LEFT)
    self:SetVAnchor(ANCHOR_TOP)
    self:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self:SetMaxPropUpscale(MAX_HUD_SCALE)
    self:SetClickable(false)
    self.root = self:AddChild(Widget("card"))
    U.Rect(self.root, controller, "card", 330, 98, {.045, .05, .085, .94})
    U.Rect(self.root, controller, "pill", 4, 60, {1, .24, .46, .9}):SetPosition(-158, 0)
    self.cover = U.Rect(self.root, controller, "card", 64, 64)
    U.Position(self.cover, -111, 1)
    self.title = self.root:AddChild(Text(CHATFONT, 21, ""))
    U.Position(self.title, 31, 18)
    self.artist = self.root:AddChild(Text(CHATFONT, 16, "", {.67, .69, .78, 1}))
    U.Position(self.artist, 31, -6)
    self.clock = self.root:AddChild(Text(CHATFONT, 13, "", {.67, .69, .78, 1}))
    U.Position(self.clock, 31, -32)
    U.Rect(self.root, controller, "pill", 184, 3, {.22, .23, .29, 1}):SetPosition(31, -22)
    self.progress = U.Rect(self.root, controller, "pill", 1, 3, {1, .24, .46, 1})
    self.unsubscribe = controller:Subscribe(function() self.dirty = true end)
    self.dirty = true
    self:StartUpdating()
    self:OnUpdate(0)
end)

function SongCard:OnUpdate(dt)
    local settings = self.controller.settings.card or {}
    local player = U.Player(self.controller)
    if settings.enabled == false or not player.track or not U.Alive(self.owner) or (not player.playing and not settings.showPaused) then
        U.ReleaseArtwork(self.cover,self.controller); self.dirty=true
        U.Show(self, false); return
    end
    U.Show(self, true)
    U.Scale(self, U.Clamp(settings.scale or 1, .4, 3))
    local w, h = TheSim:GetScreenSize()
    U.Position(self, 170 + U.Clamp(settings.posX or .01, 0, 1) * math.max(0, w - 340),
        -(55 + U.Clamp(settings.posY or .05, 0, 1) * math.max(0, h - 110)))
    if self.dirty then
        self.dirty = false
        U.Truncated(self.title, U.Title(player.track), 191, 60)
        U.Truncated(self.artist, U.Artist(player.track), 191, 60)
        U.Artwork(self.cover, self.controller, player.track)
        U.Size(self.cover, 64, 64)
    end
    local position, duration = self.controller:GetPosition(), tonumber(player.duration) or 0
    local width = math.max(1, 184 * U.Clamp(duration > 0 and position / duration or 0, 0, 1))
    U.Size(self.progress, width, 3)
    U.Position(self.progress, -61 + width / 2, -22)
    local second, durationSecond = math.max(0, math.floor(position)), math.max(0, math.floor(duration))
    if self.clockSecond ~= second or self.clockDuration ~= durationSecond or self.clockPlaying ~= player.playing then
        self.clockSecond, self.clockDuration, self.clockPlaying = second, durationSecond, player.playing
        U.String(self.clock, (player.playing and "" or "已暂停  ") .. U.Time(second) .. " / " .. U.Time(durationSecond))
    end
end

function SongCard:Kill()
    if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
    U.ReleaseArtwork(self.cover,self.controller)
    SongCard._base.Kill(self)
end
return SongCard
