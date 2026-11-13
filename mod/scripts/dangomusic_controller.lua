local Bridge = require("dangomusic_bridge")
local GameAssets = require("dangomusic_assets")
local Environment = require("dangomusic_environment")
local EMPTY_LYRICS = {lines={}, timing="none"}
local function Now() return GetStaticTime() end

-- One owner per HUD: keep the player state and lyric clock alive when the
-- full screen is closed, and release all pending callbacks with the HUD.
local Controller = Class(function(self, inst, connection, modroot, connectionLoader)
    self.inst, self.modroot = inst, modroot
    self.connectionLoader = connectionLoader
    self.bridge = Bridge(inst, connection)
    self.assets = GameAssets(modroot)
    self.assetLeases = {}
    self.listeners, self.artworkRequests, self.artworkFailures = {}, {}, {}
    self.artworkPendingCount = 0
    self.artworkDescriptors,self.artworkOrder,self.assetFailures,self.artworkFailureOrder={},{},{},{}
    self.state = {player={position=0,duration=0,volume=.7,playing=false},playerConnected=false}
    self.settings, self.schema = {}, {}
    self.lyrics = EMPTY_LYRICS
    self.receivedAt = Now()
    self.playlists = {}
    self.catalog = {}
    self:RefreshSettings()
    self:Poll()
    self.polltask = inst:DoPeriodicTask(.7, function() self:Poll() end)
    self:SampleEnvironment()
    self.environmenttask = inst:DoPeriodicTask(1.5, function() self:SampleEnvironment() end)
end)

function Controller:Subscribe(fn)
    self.listeners[fn] = true
    return function() self.listeners[fn] = nil end
end

function Controller:Notify()
    if self.closed then return end
    for fn in pairs(self.listeners) do
        local ok = pcall(fn, self.state)
        if not ok then print("[Music] A UI listener failed; see the music panel state.") end
    end
end

function Controller:Request(path, method, body, callback)
    if self.closed then return end
    self.bridge:Request(path, method, body, function(data, err)
        if not self.closed and callback then callback(data, err) end
    end)
end

function Controller:Reconnect(callback)
    if self.closed then return end
    if self.reconnecting then
        if callback then callback(nil,"正在连接播放器，请稍候") end
        return
    end
    local ok, connection = pcall(function()
        return self.connectionLoader and self.connectionLoader()
    end)
    local nextBridge = Bridge(self.inst, ok and connection or nil)
    if not nextBridge:IsConfigured() then
        nextBridge:Close()
        local err="请先双击模组目录中的「一键启动播放器.cmd」，完成后再点重新连接"
        self.lastError=err
        self:Notify()
        if callback then callback(nil,err) end
        return
    end
    self.reconnecting=true
    self.statusVersion=(self.statusVersion or 0)+1
    self.settingsVersion=(self.settingsVersion or 0)+1
    self.sourceVersion=(self.sourceVersion or 0)+1
    self.bridge:Close()
    self.bridge=nextBridge
    self.statusPending,self.settingsPending,self.environmentPending=false,false,false
    self.artworkRequests,self.artworkFailures={},{}
    self.artworkPendingCount=0
    self.playlists={}
    self:InvalidateCatalog()
    self.state.account=nil
    self.state.playerConnected=false
    self.backendConnected=nil
    self.settingsRevision,self.settingsRetryAt=nil,nil
    self.trackID=nil
    self:LoadLyrics(nil)
    self:RefreshSettings()
    self:Notify()
    self:Poll(function(data,err)
        self.reconnecting=false
        if callback then callback(data,err) end
    end)
end

function Controller:OpenModFolder(callback)
    self:Request("/api/open-mod-folder","POST",{},callback)
end

function Controller:Command(body, callback)
    self:Request("/api/control", "POST", body, function(data, err)
        self.lastError = err
        if callback then callback(data, err) end
        self:Poll()
    end)
end

function Controller:GetPosition()
    local p = self.state.player or {}
    local position = tonumber(p.position) or 0
    if self.state.playerConnected and p.playing and not p.error then
        position = position + math.max(0, Now()-self.receivedAt)
    end
    local duration = tonumber(p.duration) or (p.track and p.track.duration) or 0
    return math.max(0, duration > 0 and math.min(duration,position) or position)
end

function Controller:GetState() return self.state end
function Controller:GetSettings() return self.settings end
function Controller:GetLyrics() return self.lyrics end
function Controller:GetLyricGlyphs() return self.lyricGlyphs end
function Controller:TakeLyricGlyphLease(data)
    if self.closed or data ~= self.lyricGlyphs then return nil end
    local lease = self.lyricGlyphLease
    self.lyricGlyphLease = nil
    return lease
end

function Controller:ClearLyricGlyphs()
    -- Before handoff the controller owns the resource; afterwards the lyric
    -- widget destroys its sprites and releases it when the track changes.
    if self.lyricGlyphLease then self.lyricGlyphLease:Release(); self.lyricGlyphLease = nil end
    self.lyricGlyphs = nil
end

function Controller:RefreshSettings()
    if self.settingsPending or self.closed then return end
    self.settingsPending = true
    local version=self.settingsVersion or 0
    self:Request("/api/settings", "GET", nil, function(data, err)
        self.settingsPending = false
        if version~=(self.settingsVersion or 0) then self:RefreshSettings(); return end
        if data and type(data.settings)=="table" then
            self.settings, self.schema = data.settings, data.schema or self.schema
            self.settingsRevision = data.settingsRevision
            self.settingsRetryAt = nil
            self:Notify()
        else self.settingsRetryAt = Now()+10 end
    end)
end

function Controller:SetSettings(patch, callback)
    self:Request("/api/settings", "POST", patch, function(data, err)
        if data and type(data.settings)=="table" then
            self.settingsVersion=(self.settingsVersion or 0)+1
            local oldSource=((self.settings or {}).player or {}).musicSource
            local newSource=(data.settings.player or {}).musicSource
            self.settings = data.settings
            if newSource~=nil and oldSource~=newSource then
                self.statusVersion=(self.statusVersion or 0)+1
                self.sourceVersion=(self.sourceVersion or 0)+1
                self.state.provider=newSource==1 and "qq" or "netease"
                local source=self.catalog[self.state.provider]
                if source then
                    source.generation=source.generation+1; source.ready=false
                    for _,entry in pairs(source.entries) do entry.pending=false end
                end
                self.state.account=nil
                self.playlists={}
            end
            self.settingsRevision = data.settingsRevision
            self:Notify()
        end
        if callback then callback(data, err) end
    end)
end

-- One small cache per source, verified account and category. The controller
-- owns requests so closing a screen does not throw away a pending result.
function Controller:InvalidateCatalog(provider)
    self.statusVersion=(self.statusVersion or 0)+1
    if provider then
        local source=self.catalog[provider]
        if source then source.generation=source.generation+1; source.ready=false; source.entries={} end
    else
        for _,source in pairs(self.catalog) do source.generation=source.generation+1; source.ready=false; source.entries={} end
    end
end

function Controller:ObserveCatalogAccount(provider,account)
    if provider~="netease" and provider~="qq" then return end
    local id=account and (account.id or account.userId)
    -- Never treat an account with no stable ID as anonymous.
    local identity
    if account==nil then identity="anonymous"
    elseif id~=nil then identity="user:"..tostring(id) end
    local source=self.catalog[provider]
    if not source then source={generation=0,entries={}}; self.catalog[provider]=source end
    if identity~=source.identity then
        source.generation=source.generation+1; source.entries={}; source.identity=identity
    end
    source.ready=identity~=nil
end

function Controller:GetCatalogIdentity(provider)
    local source=self.catalog[provider]
    return provider..":"..(source and tostring(source.generation) or "unknown")..":"..(source and source.ready and "ready" or "waiting")
end

function Controller:GetCatalog(provider,kind,force)
    local paths={recommend="/api/discover?section=recommend",charts="/api/discover?section=charts",playlists="/api/playlists"}
    local path=paths[kind]
    local source=self.catalog[provider]
    if not path or not source or not source.ready then return nil,false,nil end
    local entry=source.entries[kind]
    if not entry then entry={}; source.entries[kind]=entry end
    if not entry.pending and (force or (not entry.retryAt or Now()>=entry.retryAt) and (not entry.data or Now()-(entry.at or 0)>=300)) then
        entry.pending=true
        local generation=source.generation
        self:Request(path..(path:find("?",1,true) and "&" or "?").."provider="..provider,"GET",nil,function(data,err)
            if self.closed or source.generation~=generation or source.entries[kind]~=entry or not source.ready then return end
            entry.pending=false
            if data and type(data.playlists)=="table" then
                entry.data=data.playlists; entry.at=Now()
                entry.error,entry.retryAt=nil,nil
            else entry.error=err or "曲库加载失败"; entry.retryAt=Now()+15 end
            self:Notify()
        end)
    end
    return entry.data,entry.pending,entry.error
end

function Controller:RefreshPlaylists(callback)
    local provider=self.state.provider or (((self.settings.player or {}).musicSource==1) and "qq" or "netease")
    local version=self.sourceVersion or 0
    self:Request("/api/playlists?provider="..provider, "GET", nil, function(data, err)
        if version~=(self.sourceVersion or 0) then return end
        if data and type(data.playlists)=="table" then self.playlists = data.playlists end
        if callback then callback(data, err) end
        self:Notify()
    end)
end

function Controller:LoadLyrics(trackID)
    local version = (self.lyricsVersion or 0)+1
    self.lyricsVersion = version
    self.lyrics = EMPTY_LYRICS
    self:ClearLyricGlyphs()
    self.glyphsRetryAt, self.glyphsPending = nil, false
    self.glyphFailures = 0
    self.lyricsRetryAt = nil
    self.lyricsPending = trackID ~= nil
    if not trackID then return end
    self:Request("/api/lyrics?trackId="..Bridge.Escape(trackID), "GET", nil, function(data, err)
        if version ~= self.lyricsVersion then return end
        self.lyricsPending = false
        if data and type(data.lines)=="table" then
            self.lyrics = data
            self.lyricsFailures, self.lyricsRetryAt = 0, nil
            if #data.lines > 0 then self:LoadLyricGlyphs(trackID, version) end
        else
            self.lyrics = {lines={},timing="none",trackId=trackID,error=err}
            self.lyricsFailures = math.min((self.lyricsFailures or 0)+1, 4)
            self.lyricsRetryAt = Now()+math.min(10 * 2^(self.lyricsFailures-1), 60)
        end
        self:Notify()
    end)
end

function Controller:LoadLyricGlyphs(trackID, version)
    if self.closed or self.glyphsPending or not trackID then return end
    self.glyphsPending, self.glyphsRetryAt = true, nil
    version = version or self.lyricsVersion
    self:Request("/api/lyric-glyphs?trackId="..Bridge.Escape(trackID), "GET", nil, function(data)
        if version ~= self.lyricsVersion or tostring(trackID) ~= self.trackID then return end
        self.glyphsPending = false
        local lease = data and tostring(data.trackId)==self.trackID and type(data.fonts)=="table" and self.assets:Acquire(data.asset)
        if lease then
            self:ClearLyricGlyphs()
            self.lyricGlyphLease = lease
            self.lyricGlyphs = data
            self.glyphFailures, self.glyphsRetryAt = 0, nil
            self:Notify()
        else
            self.glyphFailures = math.min((self.glyphFailures or 0)+1, 4)
            self.glyphsRetryAt = Now()+math.min(10 * 2^(self.glyphFailures-1), 60)
        end
        -- Effects may degrade to regular text; never replace a playback error.
    end)
end

function Controller:LoadAsset(descriptor)
    if self.closed or type(descriptor) ~= "table" or type(descriptor.atlas) ~= "string" then return nil end
    if self.assetLeases[descriptor.atlas] then return self.assetLeases[descriptor.atlas] end
    local lease = self.assets:Acquire(descriptor)
    if lease then self.assetLeases[descriptor.atlas] = lease end
    return lease
end

function Controller:ArtworkDescriptor(kind,id,allowLoad)
    if not id then return nil end
    local key=kind..":"..tostring(id)
    if self.artworkDescriptors[key] then return self.artworkDescriptors[key] end
    if not allowLoad or self.closed or self.artworkRequests[key] or (self.artworkFailures[key] and Now()<self.artworkFailures[key]) then return nil end
    if self.artworkPendingCount>=2 then return nil end
    self.artworkRequests[key]=true; self.artworkPendingCount=self.artworkPendingCount+1
    self:Request("/api/artwork?"..kind.."="..Bridge.Escape(id),"GET",nil,function(data)
        self.artworkRequests[key]=nil; self.artworkPendingCount=math.max(0,self.artworkPendingCount-1)
        if data and type(data.asset)=="table" and type(data.asset.atlas)=="string"
            and data.asset.atlas:match("^images/music_cache/[a-zA-Z0-9_%-]+%.xml$")
            and type(data.asset.image)=="string" and data.asset.image:match("^[a-zA-Z0-9_%-]+%.tex$") then
            self.artworkDescriptors[key]=data.asset
            self.artworkOrder[#self.artworkOrder+1]=key
            if #self.artworkOrder>256 then
                local old=table.remove(self.artworkOrder,1); local removed=self.artworkDescriptors[old]
                if removed then self.assetFailures[removed.atlas]=nil end
                self.artworkDescriptors[old]=nil
            end
            self:Notify()
        else
            if not self.artworkFailures[key] then self.artworkFailureOrder[#self.artworkFailureOrder+1]=key end
            self.artworkFailures[key]=Now()+30
            if #self.artworkFailureOrder>256 then self.artworkFailures[table.remove(self.artworkFailureOrder,1)]=nil end
        end
    end)
    return nil
end

-- Every screen/HUD image owns an independent lease and releases it after
-- switching to a built-in texture, so one consumer cannot unload another's image.
function Controller:AcquireArtwork(descriptor)
    local atlas=descriptor and descriptor.atlas
    if not atlas or self.assetFailures[atlas] and Now()<self.assetFailures[atlas] then return nil end
    local lease=self.assets:Acquire(descriptor)
    if not lease then self.assetFailures[atlas]=Now()+30 end
    return lease
end
function Controller:PeekArtwork(kind,id) return self:ArtworkDescriptor(kind,id,false) end
function Controller:RequestArtwork(kind,id) return self:ArtworkDescriptor(kind,id,true) end

function Controller:SampleEnvironment()
    if self.closed or self.environmentPending then return end
    local snapshot = Environment.Sample(ThePlayer, TheWorld)
    if not snapshot then return end
    self.environmentPending = true
    self:Request("/api/environment", "POST", snapshot, function()
        self.environmentPending = false
        -- Telemetry failure must not replace music/lyric/UI errors.
    end)
end

function Controller:Poll(callback)
    if self.closed or self.statusPending then return end
    self.statusPending = true
    local version=self.statusVersion or 0
    self:Request("/api/status", "GET", nil, function(data, err)
        self.statusPending = false
        if version~=(self.statusVersion or 0) then self:Poll(callback); return end
        if not data or type(data.player)~="table" then
            err=err or "本机播放器响应格式错误，请重新连接"
            self.backendConnected=false
            self.lastError = err
            self.state.playerConnected = false
            self:Notify()
            if callback then callback(nil,err) end
            return
        end
        self.backendConnected=true
        self.lastError = nil
        if data.provider and data.provider~=self.state.provider then
            self.sourceVersion=(self.sourceVersion or 0)+1
            self.playlists={}
        end
        self:ObserveCatalogAccount(data.provider,data.account)
        self.state, self.receivedAt = data, Now()
        local id = data.player.track and tostring(data.player.track.id) or nil
        if id ~= self.trackID then
            self.trackID = id
            self.lyricsFailures, self.lyricsRetryAt = 0, nil
            self:LoadLyrics(id)
            if id then self:RequestArtwork("trackId",id) end
        elseif id and not self.lyricsPending and self.lyricsRetryAt and Now()>=self.lyricsRetryAt then
            self:LoadLyrics(id)
        end
        if id and not self.glyphsPending and self.glyphsRetryAt and Now()>=self.glyphsRetryAt then self:LoadLyricGlyphs(id) end
        if data.settingsRevision~=self.settingsRevision and (not self.settingsRetryAt or Now()>=self.settingsRetryAt) then self:RefreshSettings() end
        self:Notify()
        if callback then callback(data) end
    end)
end

function Controller:Close()
    if self.closed then return end
    self.closed = true
    if self.polltask then self.polltask:Cancel(); self.polltask = nil end
    if self.environmenttask then self.environmenttask:Cancel(); self.environmenttask = nil end
    self.lyricsVersion = (self.lyricsVersion or 0)+1
    self.lyricsPending, self.environmentPending = false, false
    self:ClearLyricGlyphs()
    self.glyphsPending, self.glyphsRetryAt = false, nil
    self.bridge:Close()
    -- Controls' onremove runs after Widget:KillAllChildren; the screen is closed
    -- before Close too, so no remaining Image references these loaded resources.
    self.assets:Close()
    self.assetLeases = {}
    self.artworkPendingCount = 0
    self.listeners, self.artworkRequests = {}, {}
    self.catalog = {}
    self.artworkDescriptors,self.artworkOrder,self.assetFailures,self.artworkFailureOrder={},{},{},{}
    self.inst = nil
    self.connectionLoader=nil
end

return Controller
