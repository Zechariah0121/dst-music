local Widget = require "widgets/widget"
local Text = require "widgets/text"
local Image = require "widgets/image"
local U = require "widgets/music_hudutil"
local Logic = require "widgets/music_lyriclogic"

local SHADOW = {.025, .018, .03, 1}
local TEXT = {.97, .88, .84, 1}
local TRANSLATION = {.86, .65, .8, 1}
local GLOW_COLOURS = {{1, .38, .62, 1}, {.32, .66, 1, 1}, {1, .74, .30, 1}}

local function Paint(text, colour, alpha)
    U.Paint(text, colour, alpha)
end
local function MaskLayer(image, mask, layer, advance, baseline, dx, dy)
    -- Core is sampled at twice the logical size, halos have their own larger
    -- bounds. Each layer shares the same baseline, not the same texture quad.
    local m = mask.layers and mask.layers[layer] or mask
    U.Size(image, m.width, m.height)
    U.Position(image, m.offsetX - advance / 2 + (dx or 0), m.offsetY + baseline + (dy or 0))
end
local function NewGlyph(parent)
    local root = parent:AddChild(Widget("glyph"))
    root.shadow = root:AddChild(Text(UIFONT, 30, ""))
    root.core = root:AddChild(Text(UIFONT, 30, ""))
    U.Position(root.shadow, 1, -1)
    return root
end

-- Direct Controls child; unanchored screen pixel coordinates, as original FollowText.
-- World position is retained independently of HUD position. Text is a projected
-- billboard: DST offers no Minecraft depth-buffer text rendering through Widgets.
local Lyrics = Class(Widget, function(self, controller, owner)
    Widget._ctor(self, "MusicLyrics")
    self.controller, self.owner = controller, owner
    self:SetClickable(false)
    -- Projection returns physical screen pixels; applying proportional UI scale
    -- again would enlarge both world-metric glyph sizes and their advances.
    self:SetScaleMode(SCALEMODE_NONE)
    self.root = self:AddChild(Widget("projected_lyrics"))
    -- Every glow is a blur of this glyph's actual font mask. A separate layer
    -- keeps all near/far masks behind all sharp cores; no circular light sprites.
    self.glowRoot = self.root:AddChild(Widget("lyric_glow"))
    self.glyphs = {}
    self.measure = self:AddChild(Text(UIFONT, 30, ""))
    U.Show(self.measure, false)
    self.translation = self.root:AddChild(Text(UIFONT, 21, ""))
    self.flash = self:AddChild(Text(UIFONT, 70, ""))
    U.Show(self.flash, false)
    -- Classic Now playing is independent of Song Card and lyric availability.
    self.classic = self:AddChild(Widget("classic_now_playing"))
    self.classic.cover = U.Rect(self.classic, controller, "card", 42, 42)
    self.classic.title = self.classic:AddChild(Text(CHATFONT, 20, ""))
    U.Position(self.classic.title, 135, 11)
    self.classic.artist = self.classic:AddChild(Text(CHATFONT, 15, "", {.72, .73, .78, 1}))
    U.Position(self.classic.artist, 135, -12)
    U.Show(self.classic, false)
    self.unsubscribe = controller:Subscribe(function() self.dirty = true end)
    self.dirty = true
    self:StartUpdating()
end)

function Lyrics:ReleaseGlyphResources()
    -- ImageWidgets must stop referencing the atlas before its asset lease is
    -- released. Retain the lightweight Text roots, never another song's sprites.
    for _, g in ipairs(self.glyphs) do
        if g.sprite then g.sprite:Kill(); g.sprite = nil end
        if g.spriteShadow then g.spriteShadow:Kill(); g.spriteShadow = nil end
        if g.glowGroup then g.glowGroup:Kill(); g.glowGroup = nil end
        g.glowNear, g.glowFar, g.mask = nil, nil, nil
        U.Show(g.core, true); U.Show(g.shadow, true)
    end
    self.spriteAtlas = nil
    if self.glyphLease then self.glyphLease:Release(); self.glyphLease = nil end
    self.glyphData, self.glyphSource = nil, nil
    self.advances, self.advancesFont, self.advancesGlyphData, self.advancesData = nil, nil, nil, nil
end

function Lyrics:SyncGlyphData(data)
    if self.glyphSource ~= data then
        self:ReleaseGlyphResources()
        self.glyphSource = data
    end
    if data and not self.glyphLease then
        local lease = self.controller.TakeLyricGlyphLease and self.controller:TakeLyricGlyphLease(data)
        -- Metadata alone is insufficient: another/replaced HUD may own the only
        -- live lease. Leave Text active unless ownership actually transfers.
        if lease then self.glyphLease, self.glyphData = lease, data end
    end
    return self.glyphData
end

function Lyrics:BuildLine(line, index, data, settings, glyphData)
    local moved = self.line ~= line or self.index ~= index
    local timingChanged = moved or self.data ~= data
    self.line, self.index, self.data = line, index, data
    self.builtGlyphData = glyphData
    local spriteFont = glyphData and glyphData.fonts and glyphData.fonts[settings.smoothFont and "smooth" or "mono"]
    self.spriteAtlas = spriteFont and glyphData.asset and glyphData.asset.atlas
        and self.controller.modroot .. glyphData.asset.atlas or nil
    local masks = self.spriteAtlas and spriteFont.glyphs or {}
    local baselineOffset = spriteFont and ((spriteFont.lineHeight or 30) / 2 - (spriteFont.baseline or 24)) or 0
    local font = settings.smoothFont and DEFAULTFONT or CODEFONT
    self.measure:SetFont(font)
    if self.advancesFont ~= font or self.advancesGlyphData ~= glyphData or self.advancesData ~= data then
        self.advances, self.advancesFont, self.advancesGlyphData, self.advancesData = {}, font, glyphData, data
    end
    local advances = self.advances
    local function Measure(char)
        if advances[char] then return advances[char] end
        if masks[char] and tonumber(masks[char].advance) then return masks[char].advance end
        self.measure:ResetRegionSize()
        U.String(self.measure, char)
        local width = self.measure:GetRegionSize()
        -- Some fonts report no bounds for an isolated space. Measure it between
        -- two visible glyphs so English keeps natural inter-word spacing.
        if char == " " and (not width or width <= 0) then
            U.String(self.measure, "M M"); local spaced = self.measure:GetRegionSize()
            U.String(self.measure, "MM"); local joined = self.measure:GetRegionSize()
            width = math.max(1, (spaced or 0) - (joined or 0))
        end
        advances[char] = math.max(1, width or 1)
        return advances[char]
    end
    local width
    local nextLine = data.lines and data.lines[index + 1]
    self.layout, self.precise, self.rows, width = Logic.Glyphs(line, data.timing, settings.splitLines ~= false, Measure,
        nextLine and nextLine.start)
    self.lineFit = math.min(1, 600 / math.max(1, width))
    -- Glyph pool grows to the maximum encountered current line (96), reused on seek.
    for i, info in ipairs(self.layout) do
        local g = self.glyphs[i]
        if not g then g = NewGlyph(self.root); self.glyphs[i] = g end
        g.shadow:SetFont(font); U.String(g.shadow, info.text)
        g.core:SetFont(font); U.String(g.core, info.text)
        local mask = masks[info.text]
        g.mask = mask and not mask.blank and mask.core and mask.near and mask.far and mask or nil
        if g.mask then
            if not g.spriteShadow then
                g.spriteShadow = g:AddChild(Image(self.spriteAtlas, mask.core))
                g.spriteShadow:SetClickable(false)
            end
            if not g.sprite then g.sprite = g:AddChild(Image(self.spriteAtlas, mask.core)); g.sprite:SetClickable(false) end
            U.Texture(g.spriteShadow, self.spriteAtlas, mask.core)
            U.Texture(g.sprite, self.spriteAtlas, mask.core)
            g.advance, g.baselineOffset = info.advance, baselineOffset
            MaskLayer(g.sprite, mask, "core", info.advance, baselineOffset)
            MaskLayer(g.spriteShadow, mask, "core", info.advance, baselineOffset, 1.8, -1.8)
            U.Show(g.spriteShadow, true)
            U.Show(g.sprite, true); U.Show(g.core, false); U.Show(g.shadow, false)
            if g.glowNear then self:ConfigureGlow(g) end
        else
            if g.sprite then U.Show(g.sprite, false) end
            if g.spriteShadow then U.Show(g.spriteShadow, false) end
            U.Show(g.core, true); U.Show(g.shadow, true)
            if g.glowGroup then U.Show(g.glowGroup, false) end
        end
        U.Show(g, true)
    end
    for i = #self.layout + 1, #self.glyphs do
        U.Show(self.glyphs[i], false)
        if self.glyphs[i].glowGroup then U.Show(self.glyphs[i].glowGroup, false) end
    end
    -- A late atlas/font switch changes only rendering. Keep the existing anchor
    -- and entrance phase, rather than treating it as a seek or a new lyric line.
    if timingChanged then self.justBuilt = true end
    self.translation:SetFont(font)
    U.String(self.translation, line.translation or "")
    self.translationChars = Logic.Characters(line.translation or "")
    self.translationCount = nil
    self.translation:SetRegionSize(760, 70)
    U.Position(self.translation, 0, -48 - self.rows * 36)
    if moved or not self.anchor then self:PlaceWorld(settings, index) end
end

function Lyrics:ConfigureGlow(g)
    local mask = g.mask
    U.Texture(g.glowNear, self.spriteAtlas, mask.near)
    U.Texture(g.glowFar, self.spriteAtlas, mask.far)
    MaskLayer(g.glowNear, mask, "near", g.advance, g.baselineOffset)
    MaskLayer(g.glowFar, mask, "far", g.advance, g.baselineOffset)
end

function Lyrics:PlaceWorld(settings, index)
    if not U.Alive(self.owner) or not TheCamera then self.anchor = nil; return end
    local x, y, z = self.owner.Transform:GetWorldPosition()
    local down, right = TheCamera:GetDownVec(), TheCamera:GetRightVec()
    local spread = U.Clamp(settings.spread or 30, 0, 60) * math.pi / 180
    local angle = math.sin((index or 1) * 2.399963) * spread
    local distance = U.Clamp(settings.distance or 10, 3, 40)
    local dx = -down.x * math.cos(angle) + right.x * math.sin(angle)
    local dz = -down.z * math.cos(angle) + right.z * math.sin(angle)
    self.anchor = {x = x + dx * distance, y = y + 2.8, z = z + dz * distance}
    self.baseline = {x = right.x, z = right.z}
    self.placedDistance, self.placedSpread = settings.distance, settings.spread
end

function Lyrics:Project(settings, dt)
    local w, h = TheSim:GetScreenSize()
    local x, y, worldscale, rotation = w / 2, h * .23, 1, 0
    if settings.worldMode ~= false then
        if not self.anchor then self:PlaceWorld(settings, self.index) end
        if not self.anchor then return false end
        local a = self.anchor
        local px, py, pz = self.owner.Transform:GetWorldPosition()
        local dx, dz = a.x - px, a.z - pz
        local dist = math.sqrt(dx * dx + dz * dz)
        local minimum = U.Clamp(settings.distance or 10, 3, 40) * .65
        if settings.keepAway ~= false and dist < minimum then
            if dist < .01 then dx, dz, dist = 1, 0, 1 end
            local amount = (minimum - dist) * math.min(1, (dt or .03) * 8)
            a.x, a.z = a.x + dx / dist * amount, a.z + dz / dist * amount
        end
        if settings.aboveGround then a.y = math.max(a.y, py + 2.8) end
        x, y = TheSim:GetScreenPos(a.x, a.y, a.z)
        local right = settings.facePlayer ~= false and TheCamera:GetRightVec() or self.baseline
        local x2, y2 = TheSim:GetScreenPos(a.x + right.x, a.y, a.z + right.z)
        local vx, vy = x2 - x, y2 - y
        -- A nominal 30px glyph is one world unit high. The projected pixel/world
        -- ratio already includes camera zoom and window size (no second UI scale).
        worldscale = U.Clamp(math.sqrt(vx * vx + vy * vy) / 30, .16, 1.92)
        if settings.facePlayer == false then rotation = math.atan2(vy, vx) * 180 / math.pi end
        if settings.stayOnScreen then
            -- Optional screen-safe spring changes displayed projection, not anchor.
            local tx, ty = U.Clamp(x, 190, math.max(190, w - 190)), U.Clamp(y, 170, math.max(170, h - 120))
            local gain = 1 - math.exp(-12 * (dt or .03))
            self.safeX = (self.safeX or x) + (tx - (self.safeX or x)) * gain
            self.safeY = (self.safeY or y) + (ty - (self.safeY or y)) * gain
            x, y = self.safeX, self.safeY
        else self.safeX, self.safeY = nil, nil end
        if x < -800 or x > w + 800 or y < -300 or y > h + 300 then return false end
    end
    U.Position(self.root, x, y)
    self.screenX, self.screenY = x, y
    U.Scale(self.root, U.Clamp(settings.scale or 1, .5, 3) * worldscale * (self.lineFit or 1))
    if self.rootRotation ~= rotation then
        self.root:SetRotation(rotation)
        self.rootRotation = rotation
    end
    return true
end

function Lyrics:OnUpdate(dt)
    local settings = self.controller.settings.lyrics or {}
    local player = U.Player(self.controller)
    if not player.track or not U.Alive(self.owner) then self:SyncGlyphData(nil); U.ReleaseArtwork(self.classic.cover,self.controller); self.classicKey=nil; self.classicCoverVisible=false; U.Show(self, false); return end
    local data = self.controller:GetLyrics() or {}
    -- Sync before any disabled/no-active-line early return. Instrumental gaps in
    -- a valid lyric file retain the current song lease; absent lyrics clear it.
    local glyphSource = data.lines and #data.lines > 0 and self.controller.GetLyricGlyphs
        and self.controller:GetLyricGlyphs() or nil
    local glyphData = self:SyncGlyphData(glyphSource)
    U.Show(self, true)
    self:UpdateClassic(settings, player)
    if settings.enabled == false then U.Show(self.root, false); U.Show(self.flash, false); return end
    local position = self.controller:GetPosition()
    local jumped = self.lastPosition and (position < self.lastPosition - .075
        or position - self.lastPosition > math.max(.5, (dt or .03) * 4))
    self.lastPosition = position
    local index = Logic.FindLine(data.lines or {}, position)
    if not index then U.Show(self.root, false); U.Show(self.flash, false); self.index = nil; return end
    local line = data.lines[index]
    if self.line ~= line or self.index ~= index or self.data ~= data or self.layoutFont ~= settings.smoothFont or self.layoutSplit ~= settings.splitLines or self.builtGlyphData ~= glyphData then
        self.dirty = false
        self.layoutFont, self.layoutSplit = settings.smoothFont, settings.splitLines
        self:BuildLine(line, index, data, settings, glyphData)
    end
    if self.justBuilt then
        self.suppressBefore = position > (line.start or 0) + .2 and position or nil
        self.justBuilt = false
    end
    if jumped then self.suppressBefore = position end
    if self.placedDistance ~= settings.distance or self.placedSpread ~= settings.spread then self:PlaceWorld(settings, index) end
    if not self:Project(settings, dt) then U.Show(self.root, false); U.Show(self.flash, false); return end
    U.Show(self.root, true)
    local now = U.Clock()
    local colour = U.CachedColour(self, "textColour", settings.textColor, TEXT)
    local glowColour = GLOW_COLOURS[math.floor(U.Clamp(settings.glowColor or 0, 0, 3))] or colour
    local night = TheWorld and TheWorld.state and (TheWorld.state.isnight or TheWorld.state.isdusk or TheWorld:HasTag("cave"))
    local strength = U.Clamp(settings.glowStrength or .3, 0, 3)
    local radius = U.Clamp(settings.glowRadius or .5, 0, 1)
    local glow = settings.glow ~= false and strength > 0 and (not settings.glowNightOnly or night)
    if glow then U.Show(self.glowRoot, true) else U.Show(self.glowRoot, false) end
    -- Separate crisp lettering from the wide glow pass, as in the reference.
    -- Bounded exponential gain remains smooth across the full strength range.
    -- Radius mixes actual blur widths; it never stretches the letter shapes.
    if self.glowStrength ~= strength or self.glowRadius ~= radius then
        self.glowStrength, self.glowRadius = strength, radius
        local glowAmount = strength * 4
        self.nearAlpha = (1 - math.exp(-glowAmount * 1.3)) * (1 - radius * .12)
        self.farAlpha = (1 - math.exp(-glowAmount * 1.6)) * (.25 + radius * .75)
    end
    local nearAlpha, farAlpha = self.nearAlpha, self.farAlpha
    local coreColour = colour
    if glow then
        -- Brighter face, same source hue; the halo follows text colour by default.
        if self.brightSource ~= colour then
            self.brightSource = colour
            self.brightColour = {colour[1] + (1-colour[1])*.55, colour[2] + (1-colour[2])*.55, colour[3] + (1-colour[3])*.55}
        end
        coreColour = self.brightColour
    end
    local tick = math.floor(now * U.Clamp(settings.wiggleFps or 8, 4, 24))
    local amount = U.Clamp(settings.wiggleAmount or .8, 0, 2)
    local activeWord, activeStart
    for i, info in ipairs(self.layout) do
        local g = self.glyphs[i]
        local visible, alpha, scale, lift = Logic.Appearance(info, position, settings.wordPop ~= false, self.suppressBefore)
        U.Show(g, visible)
        if visible then
            local wiggle = settings.wiggle ~= false and amount or 0
            if g.wiggleTick ~= tick or g.wiggleAmount ~= wiggle then
                g.wiggleTick, g.wiggleAmount = tick, wiggle
                g.ox = math.sin(tick * 12.9898 + i * 78.233) * wiggle * 2
                g.oy = math.sin(tick * 39.346 + i * 11.135) * wiggle * 2
            end
            local ox, oy = g.ox, g.oy
            U.Position(g, info.x + ox, info.y + oy + lift)
            U.Scale(g, scale)
            if g.mask then
                U.Tint(g.sprite, coreColour[1], coreColour[2], coreColour[3], alpha)
                U.Tint(g.spriteShadow, .025, .018, .03, alpha * .86)
            else
                Paint(g.core, colour, alpha)
                Paint(g.shadow, SHADOW, alpha * .86)
            end
            if glow and g.mask then
                if not g.glowGroup then
                    g.glowGroup = self.glowRoot:AddChild(Widget("glyph_glow"))
                    g.glowNear = g.glowGroup:AddChild(Image(self.spriteAtlas, g.mask.near))
                    g.glowFar = g.glowGroup:AddChild(Image(self.spriteAtlas, g.mask.far))
                    g.glowNear:SetClickable(false); g.glowFar:SetClickable(false)
                    -- Current widgets/image.lua exposes this; heatover.lua uses the
                    -- same BLENDMODE.Additive UI path. Core stays normal alpha.
                    g.glowNear:SetBlendMode(BLENDMODE.Additive)
                    g.glowFar:SetBlendMode(BLENDMODE.Additive)
                    self:ConfigureGlow(g)
                end
                U.Show(g.glowGroup, true)
                U.Position(g.glowGroup, info.x + ox, info.y + oy + lift)
                U.Scale(g.glowGroup, scale)
                U.Tint(g.glowNear, glowColour[1], glowColour[2], glowColour[3], alpha * nearAlpha)
                U.Tint(g.glowFar, glowColour[1], glowColour[2], glowColour[3], alpha * farAlpha)
            elseif g.glowGroup then U.Show(g.glowGroup, false) end
        else
            if g.glowGroup then U.Show(g.glowGroup, false) end
        end
        if visible and position >= info.popStart and position - info.popStart < .32
            and not (self.suppressBefore and info.popStart <= self.suppressBefore) then
            activeWord, activeStart = info.revealWord, info.popStart
        end
    end
    if settings.translation and line.translation and line.translation ~= "" then
        U.Show(self.translation, true)
        local translationColour = U.CachedColour(self, "translationColour", settings.translationColor, TRANSLATION)
        -- Translation has no source timestamps: decorative 28 glyphs/sec typewriter.
        local count = settings.translationAnimation == false and #self.translationChars
            or math.min(#self.translationChars, math.floor(math.max(0, position - (line.start or 0)) * 28))
        if self.translationCount ~= count then
            self.translationCount = count
            U.String(self.translation, table.concat(self.translationChars, "", 1, count))
        end
        Paint(self.translation, translationColour, 1)
        local ty = settings.translationWiggle ~= false and math.sin(tick * 17.7) * amount or 0
        U.Position(self.translation, 0, -48 - self.rows * 36 + ty)
    else U.Show(self.translation, false) end
    if settings.textFlash and settings.wordPop ~= false and activeWord then
        local elapsed = position - activeStart
        if elapsed < .32 then
            U.Show(self.flash, true)
            U.String(self.flash, activeWord.text or "")
            U.Scale(self.flash, U.Clamp(settings.flashSize or 1, .5, 2) * (1 + .2 * math.exp(-elapsed * 22)))
            Paint(self.flash, colour, 1 - elapsed / .32)
            local w, h = TheSim:GetScreenSize()
            U.Position(self.flash, w / 2, h * .55)
        else U.Show(self.flash, false) end
    else U.Show(self.flash, false) end
end

function Lyrics:UpdateClassic(settings, player)
    if not settings.nowPlaying then U.ReleaseArtwork(self.classic.cover,self.controller); self.classicCoverVisible=false; U.Show(self.classic, false); return end
    U.Show(self.classic, true)
    local _, h = TheSim:GetScreenSize()
    -- Keep the simpler classic label below a separately enabled Song Card.
    local card = self.controller.settings.card or {}
    local cardVisible = card.enabled ~= false and (player.playing or card.showPaused)
    U.Position(self.classic, 48, h - (cardVisible and 205 or 76))
    local key = U.Key(player.track)
    if self.classicKey ~= key or self.dirty then
        U.Truncated(self.classic.title, U.Title(player.track), 215, 60)
        U.Truncated(self.classic.artist, U.Artist(player.track), 215, 60)
    end
    if settings.showCover == false then U.ReleaseArtwork(self.classic.cover,self.controller); U.Show(self.classic.cover, false)
    else
        U.Show(self.classic.cover, true)
        if self.classicKey ~= key or self.dirty or not self.classicCoverVisible then
            U.Artwork(self.classic.cover, self.controller, player.track)
            U.Size(self.classic.cover, 42, 42)
        end
    end
    self.classicCoverVisible = settings.showCover ~= false
    self.classicKey = key
    self.dirty = false
end

function Lyrics:Kill()
    if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
    self:ReleaseGlyphResources()
    U.ReleaseArtwork(self.classic.cover,self.controller)
    self.anchor = nil
    Lyrics._base.Kill(self)
end
return Lyrics
