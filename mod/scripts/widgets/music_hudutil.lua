-- Client-only HUD helpers. All rectangles are UI assets, never gameplay entities.
local Image = require "widgets/image"
local M = {}
-- These widgets own their render properties. Compare scalar values before
-- crossing into native UI setters (Text truncation also repeatedly measures).
function M.Show(widget, visible)
    if widget.shown ~= visible then
        if visible then widget:Show() else widget:Hide() end
    end
end
function M.Position(widget, x, y)
    if widget.musicX ~= x or widget.musicY ~= y then
        widget:SetPosition(x, y)
        widget.musicX, widget.musicY = x, y
    end
end
function M.Scale(widget, scale)
    if widget.musicScale ~= scale then
        widget:SetScale(scale)
        widget.musicScale = scale
    end
end
function M.Tint(widget, r, g, b, a)
    if widget.musicR ~= r or widget.musicG ~= g or widget.musicB ~= b or widget.musicA ~= a then
        widget:SetTint(r, g, b, a)
        widget.musicR, widget.musicG, widget.musicB, widget.musicA = r, g, b, a
    end
end
function M.Paint(widget, colour, alpha)
    local r, g, b = colour[1], colour[2], colour[3]
    if widget.musicR ~= r or widget.musicG ~= g or widget.musicB ~= b or widget.musicA ~= alpha then
        widget:SetColour(r, g, b, alpha)
        widget.musicR, widget.musicG, widget.musicB, widget.musicA = r, g, b, alpha
    end
end
function M.String(widget, value)
    if widget.musicString ~= value then
        widget:SetString(value)
        widget.musicString = value
    end
end
function M.Truncated(widget, value, width, count)
    if widget.musicString ~= value or widget.musicWidth ~= width or widget.musicCount ~= count then
        widget:SetTruncatedString(value, width, count, true)
        widget.musicString, widget.musicWidth, widget.musicCount = value, width, count
    end
end
function M.Size(widget, width, height)
    if widget.musicWidth ~= width or widget.musicHeight ~= height then
        widget:ScaleToSize(width, height)
        widget.musicWidth, widget.musicHeight = width, height
    end
end
function M.Texture(widget, atlas, image)
    if widget.musicAtlas ~= atlas or widget.musicImage ~= image then
        widget:SetTexture(atlas, image)
        widget.musicAtlas, widget.musicImage = atlas, image
        -- Image:ScaleToSize depends on the current texture's native dimensions.
        widget.musicWidth, widget.musicHeight = nil, nil
    end
end
function M.CachedColour(widget, key, value, default)
    local r, g, b
    if type(value) == "table" then
        r, g, b = value[1] or value.r, value[2] or value.g, value[3] or value.b
    end
    local cache = widget[key]
    if not cache or cache.value ~= value or cache.r ~= r or cache.g ~= g or cache.b ~= b then
        cache = {value=value, r=r, g=g, b=b, colour=M.Colour(value, default)}
        widget[key] = cache
    end
    return cache.colour
end
function M.Clock() return GetStaticTime() end
function M.Clamp(v, lo, hi) return math.max(lo, math.min(hi, tonumber(v) or lo)) end
function M.Alive(owner)
    return owner ~= nil and owner:IsValid()
end
function M.Player(controller) return (controller.state or {}).player or {} end
function M.Artist(track)
    if not track then return "" end
    if type(track.artist) == "string" then return track.artist end
    -- Helper Track is normalized to artists:string; raw-provider fixtures may
    -- still supply an array of names or {name=...} objects.
    if type(track.artists) == "string" then return track.artists end
    if type(track.artists) ~= "table" then return "" end
    local result = {}
    for _, artist in ipairs(track.artists) do
        if type(artist) == "string" then result[#result + 1] = artist
        elseif type(artist) == "table" and type(artist.name) == "string" then result[#result + 1] = artist.name end
    end
    return table.concat(result, " / ")
end
function M.Key(track) return track and tostring(track.id or track.key or track.name or track.title) or "" end
function M.Title(track) return track and (track.name or track.title or "未知歌曲") or "" end
function M.Rect(parent, controller, texture, w, h, colour)
    local path = controller.modroot .. "images/music/ui.xml"
    local present = resolvefilepath_soft(path)
    local atlas = present and resolvefilepath(path) or "images/global.xml"
    local image = parent:AddChild(Image(atlas, present and texture .. ".tex" or "square.tex"))
    image:ScaleToSize(w, h)
    M.Tint(image, unpack(colour or {1, 1, 1, 1}))
    image:SetClickable(false)
    return image
end
function M.ReleaseArtwork(image, controller)
    if image.musicArtworkLease then
        -- Detach the native image before releasing the last resource reference.
        if image.inst:IsValid() then
            local path=controller.modroot.."images/music/ui.xml"
            if resolvefilepath_soft(path) then M.Texture(image,resolvefilepath(path),"card.tex")
            else M.Texture(image,"images/global.xml","square.tex") end
        end
        image.musicArtworkLease:Release()
        image.musicArtworkLease=nil
    end
    image.musicArtworkTrack=nil
end
function M.Artwork(image, controller, track)
    local id=track and (track.id or track.key)
    local key=id and tostring(id) or nil
    if image.musicArtworkTrack~=key then M.ReleaseArtwork(image,controller) end
    if image.musicArtworkLease then return true end
    local asset=id and controller.RequestArtwork and controller:RequestArtwork("trackId",id)
    if asset and asset.atlas and asset.image and controller.AcquireArtwork then
        local path=controller.modroot..asset.atlas
        if resolvefilepath_soft(path) then
            local lease=controller:AcquireArtwork(asset)
            if lease then
                M.Texture(image,resolvefilepath(path),asset.image)
                image.musicArtworkLease=lease; image.musicArtworkTrack=key
                M.Tint(image,1,1,1,1)
                return true
            end
        end
    end
    local path=controller.modroot.."images/music/ui.xml"
    if resolvefilepath_soft(path) then M.Texture(image,resolvefilepath(path),"card.tex")
    else M.Texture(image,"images/global.xml","square.tex") end
    M.Tint(image,.23,.19,.29,.82)
    image.musicArtworkTrack=key
    return false
end
function M.Colour(value, default)
    if type(value) == "table" then
        return {value[1] or value.r or default[1], value[2] or value.g or default[2], value[3] or value.b or default[3], 1}
    elseif type(value) == "number" then
        return {math.floor(value / 65536) % 256 / 255, math.floor(value / 256) % 256 / 255, value % 256 / 255, 1}
    elseif type(value) == "string" then
        local n = tonumber(value:gsub("#", ""), 16)
        if n then return M.Colour(n, default) end
    end
    return default
end
function M.Time(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
return M
