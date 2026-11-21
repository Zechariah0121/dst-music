local Screen = require("widgets/screen")
local Widget = require("widgets/widget")
local Image = require("widgets/image")
local TextEdit = require("widgets/textedit")
local TEMPLATES = require("widgets/redux/templates")
local UI = require("widgets/music_ui_common")
local TrueScrollArea = require("widgets/truescrollarea")
local EMPTY_LINES = {}
local function Clock(v) v=math.max(0,math.floor(tonumber(v) or 0)); return string.format("%d:%02d",math.floor(v/60),v%60) end
local function Escape(v) return tostring(v or ""):gsub("([^%w%-_%.~])",function(c) return string.format("%%%02X",string.byte(c)) end) end
local function SetSelected(button,selected)
    if button.SetMusicColours then
        button:SetMusicColours(selected and "selected" or "button",selected and "selectedFocus" or "buttonFocus")
    else button:SetImageNormalColour(1,1,1,selected and .65 or .015) end
end
local function Artist(track)
    if type(track.artists)=="table" then local a={}; for _,v in ipairs(track.artists) do a[#a+1]=type(v)=="table" and v.name or tostring(v) end; return table.concat(a," / ") end
    return tostring(track.artists or track.artist or "")
end
local LABELS={enabled="启用此组件",worldMode="世界悬浮歌词",nowPlaying="显示正在播放",showCover="显示封面",scale="缩放",distance="歌词距离",glow="歌词辉光",glowNightOnly="仅夜间辉光",glowColor="辉光颜色",glowStrength="辉光强度",glowRadius="辉光半径",smoothFont="平滑字体",wiggle="手绘抖动",wiggleFps="抖动帧率",wiggleAmount="抖动幅度",textFlash="文字闪现",wordPop="逐词弹出",flashSize="闪现大小",facePlayer="朝向玩家",keepAway="靠近时避让",stayOnScreen="保持在屏幕内",aboveGround="保持地面上方",spread="左右展开角度",splitLines="拆分双行歌词",translation="显示翻译",translationAnimation="翻译动画",translationWiggle="翻译抖动",dance="节拍律动",danceAuto="自动分析节拍",danceTap="手动打拍",danceSpin="节拍旋转",danceAmount="律动幅度",danceOffset="节拍偏移（毫秒）",danceBpm="每分钟节拍",textColor="歌词颜色",translationColor="翻译颜色",musicSource="音乐来源",volume="默认音量",language="界面语言",shuffle="随机播放",repeatOne="单曲循环",openKey="播放器快捷键",keyPause="播放 / 暂停快捷键",keyPrev="上一首快捷键",keyNext="下一首快捷键",keyVolUp="增大音量快捷键",keyVolDown="减小音量快捷键",keyLyrics="歌词开关快捷键",normalize="响度归一化",envAudio="环境音频效果",envWater="水下滤波",envCave="洞穴混响",envIndoor="室内混响",envRain="雨天音频柔化",envLunar="月岛空间效果",envOcean="海洋空间效果",envRuins="远古遗迹空间效果",envAtrium="远古中庭空间效果",envForest="桦树林空间效果",envStrength="环境效果强度",checkUpdates="检查版本更新",showPaused="暂停时显示",posX="水平位置",posY="垂直位置",glass="玻璃面板",showMusic="显示音乐动态岛",songNotify="切歌通知",notifyTime="通知停留秒数"}
local ORDERS={lyrics={"worldMode","distance","facePlayer","keepAway","spread","scale","smoothFont","splitLines","stayOnScreen","aboveGround","nowPlaying","showCover","glow","glowNightOnly","glowColor","glowStrength","glowRadius","wiggle","wiggleFps","wiggleAmount","textFlash","wordPop","flashSize","translation","translationAnimation","translationWiggle","textColor","translationColor","dance","danceAuto","danceTap","danceSpin","danceAmount","danceOffset","danceBpm"},player={"musicSource","volume","language","shuffle","repeatOne","normalize","openKey","keyPause","keyPrev","keyNext","keyVolUp","keyVolDown","keyLyrics","envAudio","envWater","envCave","envIndoor","envLunar","envOcean","envRuins","envAtrium","envForest","envRain","envStrength","checkUpdates"},card={"scale","showPaused","posX","posY"},island={"glass","showMusic","songNotify","scale","notifyTime"}}
local GROUPS={lyrics="歌词效果",player="音乐与环境",card="歌曲卡片",island="动态岛"}
LABELS.showTopLeftButton="显示左上角音乐按钮"
LABELS.checkUpdates="自动检查版本更新"
local NOTES={
 enabled="控制本组件的显示",worldMode="歌词显示在游戏世界中",scale="调整显示大小",distance="世界歌词离玩家的距离",facePlayer="让歌词朝向玩家",keepAway="靠近时自动避让",spread="双行歌词左右展开角度",smoothFont="使用平滑文字",splitLines="长歌词拆分成双行",stayOnScreen="尽量保持在屏幕内",aboveGround="歌词保持在地面上方",nowPlaying="显示经典歌曲信息",showCover="在歌曲信息中显示封面",textColor="输入六位十六进制颜色",translationColor="翻译文字颜色",translation="在原文下方显示翻译",translationAnimation="翻译跟随动画显示",translationWiggle="翻译跟随抖动",glow="开启文字光晕",glowNightOnly="仅在夜间显示辉光",glowColor="选择辉光颜色",glowStrength="光晕明亮程度",glowRadius="光晕扩散范围",wiggle="文字轻微手绘抖动",wiggleFps="每秒抖动更新次数",wiggleAmount="抖动幅度",textFlash="切换时显示文字闪现",wordPop="逐字时间可用时跟随演唱",flashSize="文字闪现大小",musicSource="切换浏览与登录的平台",volume="后台播放器默认音量",normalize="调整不同歌曲的响度",shuffle="随机选择队列歌曲",repeatOne="重复播放当前歌曲",showTopLeftButton="隐藏按钮后仍可用快捷键打开",openKey="Delete 恢复跟随 Mod 配置",keyPause="绑定播放或暂停",keyPrev="绑定上一首",keyNext="绑定下一首",keyVolUp="绑定增大音量",keyVolDown="绑定减小音量",keyLyrics="绑定歌词开关",envAudio="启用场景空间音效",envCave="洞穴环境混响",envStrength="调整区域空间效果强度",showPaused="暂停时仍显示卡片",posX="屏幕水平位置比例",posY="屏幕垂直位置比例",glass="半透明面板",showMusic="持续显示当前歌曲",songNotify="切歌时临时显示提示",notifyTime="切歌提示停留秒数"
}
NOTES.checkUpdates="启动后台及每 6 小时检查 GitHub"
local MusicScreen = Class(Screen,function(self,controller,onclose,initialView)
    Screen._ctor(self,"MusicScreen")
    self.controller,self.onclose=controller,onclose
    -- Relative assets resolve via package.assetpath, but an explicit mod path
    -- avoids another enabled mod providing the same relative atlas name.
    UI.atlas=controller.modroot.."images/music/ui.xml"
    self.viewVersion,self.requestVersion=0,0
    self.playlists,self.tracks,self.artTargets={},{},{}
    self.offset,self.total,self.sidebarOffset=0,0,0
    self.settingsGroup,self.settingsPage="lyrics",0
    self.view="home"; self.grid=false
    local source=((controller.settings or {}).player or {}).musicSource
    self.provider=(controller.state or {}).provider or (source==1 and "qq" or "netease")
    self.shade=self:AddChild(Image("images/global.xml","square.tex"))
    self.shade:SetClickable(true) -- retain the modal hit target outside/behind controls
    self.shade:SetVAnchor(ANCHOR_MIDDLE); self.shade:SetHAnchor(ANCHOR_MIDDLE); self.shade:SetScaleMode(SCALEMODE_FILLSCREEN); self.shade:SetTint(0,0,0,.45)
    self.root=self:AddChild(TEMPLATES.ScreenRoot("music_root"))
    if UI.SetTheme then UI.SetTheme(self.root,self.provider) end
    self.shell=UI.Panel(self.root,0,0,1190,660,{1,1,1,1},"shell")
    self.sidebarPanel=UI.Panel(self.root,-483,0,204,640,{1,1,1,1},"sidebar")
    self.ambient=UI.Panel(self.root,98,-278,915,76,{1,1,1,.75},"ambient")
    self.ambient:MoveToFront(); self.sidebarPanel:MoveToFront(); self.shell:MoveToBack()
    
    if UI.AnimateGlass then local sheen=UI.Panel(self.root,0,0,1190,660,nil,"sheen"); self.shell:MoveToBack(); UI.AnimateGlass(self.root,sheen) end
    self:BuildSidebar(); self:BuildPlayer()
    self.connectionButton=UI.Button(self.root,"后台 · 连接中",432,302,190,26,function() self:ShowConnectionHelp() end)
    self.closeButton=UI.IconButton(self.root,"close",568,302,14,function() self:Close() end,"关闭")
    self.message=UI.Label(self.root,"正在连接本机播放器…",-100,-320,860,15,UI.muted)
    self.default_focus=self.closeButton
    self.unsubscribe=controller:Subscribe(function() if not self.closed then self:UpdateState() end end)
    if initialView=="connection" then self:ShowConnection()
    elseif initialView=="settings" or initialView=="playerSettings" then self:ShowSettings("player")
    else self:ShowHome("recommend"); self:LoadPlaylists() end
    self:UpdateState()
    self.tick=self.inst:DoStaticPeriodicTask(.15,function() if not self.closed then self:UpdateProgress(); self:PrefetchTracks(); self:UpdateArtwork() end end)
end)
function MusicScreen:Request(path,method,body,callback)
    self.controller:Request(path,method or "GET",body,function(data,err)
        if self.closed then return end
        if err then self.message:SetString(tostring(err)) end
        if callback then callback(data,err) end
    end)
end
function MusicScreen:SourceRequest(path,method,body,callback)
    local version=self.sourceVersion or 0
    self.controller:Request(path,method or "GET",body,function(data,err)
        if self.closed or version~=(self.sourceVersion or 0) then return end
        if err then self.message:SetString(tostring(err)) end
        if callback then callback(data,err) end
    end)
end
function MusicScreen:CancelLogin()
    if self.loginImage and self.loginImage.inst:IsValid() then
        self.loginImage:SetTexture(UI.atlas,"square.tex"); self.loginImage:Hide()
    end
    self.loginImage=nil
    if self.loginLease then self.loginLease:Release(); self.loginLease=nil end
    if self.loginTask then self.loginTask:Cancel(); self.loginTask=nil end
    local key,provider=self.loginKey,self.loginProvider
    self.loginKey,self.loginProvider=nil,nil
    self.loginPending,self.loginErrors=false,0
    if key then self.controller:Request("/api/login/cancel","POST",{key=key,provider=provider}) end
end
function MusicScreen:ChangeProvider(provider)
    if provider~= "qq" and provider~= "netease" or provider==self.provider then return end
    self.provider=provider; if UI.SetTheme then UI.SetTheme(self.root,provider) end
    self.sourceVersion=(self.sourceVersion or 0)+1
    self.playlistRequest=(self.playlistRequest or 0)+1
    self.trackSession=(self.trackSession or 0)+1
    self:CancelLogin()
    self.playlists={}; self.sidebarOffset=0; self:RenderSidebar()
    self:LoadPlaylists()
    if self.view=="queue" then self:ShowQueue()
    elseif self.view=="home" or self.view=="tracks" or self.view=="account" or self.view=="login" then self:ShowHome("recommend") end
end
function MusicScreen:Command(body)
    self.controller:Command(body,function(data,err) if not self.closed then self.message:SetString(err or "") end end)
end
function MusicScreen:Edit(parent,x,y,w,prompt,fn)
    UI.Panel(parent,x,y,w+16,32,{.22,.23,.31,.55},"pill")
    local e=parent:AddChild(TextEdit(DEFAULTFONT,18,""))
    e:SetPosition(x,y); e:SetRegionSize(w,30); e:SetHAlign(ANCHOR_LEFT); e:SetTextLengthLimit(150)
    e:SetIdleTextColour(unpack(UI.ink)); e:SetEditTextColour(unpack(UI.ink)); e:SetEditCursorColour(unpack(UI.pink)); e:SetTextPrompt(prompt,UI.muted)
    if UI.BindTheme then UI.BindTheme(e,function(w,palette) w:SetEditCursorColour(unpack(palette.accent)) end) end
    e:SetForceEdit(true); e.OnTextEntered=fn
    self.edits=self.edits or {}; self.edits[#self.edits+1]=e
    return e
end
function MusicScreen:BuildSidebar()
    self.search=self:Edit(self.root,-483,283,157,"搜索歌曲…",function(q) self:Search(q) end)
    UI.Label(self.root,"云间音乐",-570,248,170,13,UI.muted)
    self.nav={}
    local function nav(key,icon,label,y,fn)
        local b=UI.Button(self.root,"", -483,y,184,29,fn)
        UI.Icon(b,icon,-76,0,13); UI.Label(b,label,-60,0,142,16)
        self.nav[key]=b
        return b
    end
    nav("home","home","首页",222,function() self:ShowHome("recommend") end)
    UI.Label(self.root,"发现音乐",-570,194,170,12,UI.muted)
    nav("charts","charts","排行榜",169,function() self:ShowHome("charts") end)
    nav("now","music","正在播放",140,function() self:ShowNow() end)
    local together=nav("together","music","一起听 · 暂不支持",111,function() end)
    together:Disable(); together:SetTooltip("当前版本没有跨玩家同步播放服务")
    self.playlistLabel=UI.Label(self.root,"我的歌单",-570,81,170,12,UI.muted)
    self.sideRows={}
    for i=1,10 do
        local n=i
        local b=UI.Button(self.root,"",-483,53-(i-1)*27,184,26,function()
            local item=self.playlists[self.sidebarOffset+n]; if item then self:SelectPlaylist(item) end
        end)
        UI.Icon(b,"list",-76,0,11)
        b.name=UI.Label(b,"",-62,0,147,15)
        self.sideRows[i]=b
    end
    UI.Button(self.root,"<",-552,-232,30,22,function() self.sidebarOffset=math.max(0,self.sidebarOffset-10); self:RenderSidebar() end)
    self.refreshButton=UI.Button(self.root,"刷新",-483,-232,70,22,function() self:LoadPlaylists(true); if self.view=="home" then self:RefreshHome(true) end end)
    UI.Button(self.root,">",-414,-232,30,22,function() if self.sidebarOffset+10<#self.playlists then self.sidebarOffset=self.sidebarOffset+10; self:RenderSidebar() end end)
    nav("settings","settings","设置",-273,function() self:ShowSettings() end)
    self.account=UI.Button(self.root,"扫码登录",-526,-310,95,26,function() self:ShowAccount() end)
    self.sourceButton=UI.Button(self.root,"网易云 ⇄",-435,-310,83,26,function()
        self:SaveSetting("player","musicSource",self.provider=="qq" and 0 or 1)
    end)
    self.sourceButton:SetTooltip("切换音乐来源；正在播放的歌曲继续播放")
end
function MusicScreen:RenderSidebar()
    for i,b in ipairs(self.sideRows) do
        local p=self.playlists[self.sidebarOffset+i]
        if p then
            b:Show(); b.name:SetTruncatedString(tostring(p.name),147,nil,true)
            b:SetTooltip(tostring(p.name).." · "..tostring(p.trackCount or 0).." 首")
            SetSelected(b,self.view=="tracks" and self.selected and tostring(self.selected.id)==tostring(p.id))
        else b:Hide() end
    end
end
function MusicScreen:LoadPlaylists(force)
    if self.controller.GetCatalog then
        local data,pending,err=self.controller:GetCatalog(self.provider,"playlists",force)
        if data and self.playlists~=data then self.playlists=data; self.sidebarOffset=0; self:RenderSidebar() end
        self.playlistLabel:SetString(pending and (data and "我的歌单 · 刷新中" or "我的歌单 · 加载中") or err and (data and "我的歌单 · 刷新失败" or self.controller.backendConnected==false and "后台离线" or "歌单加载失败") or "我的歌单")
        return
    end
    self.playlistRequest=(self.playlistRequest or 0)+1; local v=self.playlistRequest
    self.playlistLabel:SetString("我的歌单 · 加载中")
    self:SourceRequest("/api/playlists?provider="..self.provider,"GET",nil,function(data)
        if v~=self.playlistRequest then return end
        if data and data.playlists then
            self.playlists=data.playlists; self.sidebarOffset=0; self:RenderSidebar(); self.playlistLabel:SetString("我的歌单")
        else self.playlistLabel:SetString(self.controller.backendConnected==false and "后台离线" or "歌单加载失败") end
    end)
end
function MusicScreen:NewContent(view,title,subtitle)
    self:CancelLogin()
    if self.updateTask then self.updateTask:Cancel(); self.updateTask=nil end
    self.updatePending=false
    for _,e in ipairs(self.edits or {}) do if e~=self.search and e.inst:IsValid() then e:SetEditing(false) end end
    self.edits=self.search and {self.search} or {}; self.filterEdit=nil; self.settingControls=nil; self.trackVisuals={}; self.scrollList=nil; self.settingsScroll=nil
    self:ReleaseArtworkTargets()
    self.viewVersion=self.viewVersion+1; self.requestVersion=self.requestVersion+1; self.view=view; self.artTargets={}
    if self.content then TheFrontEnd:LockFocus(false); self.content:Kill() end
    for key,b in pairs(self.nav or {}) do
        local selected=key==view and (view~="home" or self.section~="charts") or key=="charts" and view=="home" and self.section=="charts"
        SetSelected(b,selected)
    end
    self:RenderSidebar()
    self.content=self.root:AddChild(Widget("music_"..view))
    -- New scroll subtrees contain buffered rows. Keep the persistent player
    -- above them so offscreen hit targets cannot take its mouse focus.
    self.playerRoot:MoveToFront()
    self.title=UI.Label(self.content,title,-353,278,820,29)
    self.subtitle=UI.Label(self.content,subtitle or "",-353,248,860,16,UI.muted)
    return self.content,self.viewVersion
end
function MusicScreen:Artwork(parent,id,x,y,size,playlist)
    local base=UI.Panel(parent,x,y,size,size,{.21,.23,.32,1},"card")
    UI.Icon(parent,"music",x,y,math.min(size*.35,36))
    local image=parent:AddChild(Image(UI.atlas,"square.tex")); image:SetPosition(x,y); image:ScaleToSize(size,size); image:SetClickable(false); image:Hide()
    local target={widget=image,id=id,playlist=playlist,size=size,version=self.viewVersion}
    self.artTargets[#self.artTargets+1]=target
    return target
end
function MusicScreen:ReleaseArtworkTarget(target)
    if target.lease then
        if target.widget.inst:IsValid() then target.widget:SetTexture(UI.atlas,"square.tex"); target.widget:Hide() end
        target.lease:Release(); target.lease=nil
    end
    target.asset=nil
end
function MusicScreen:ReleaseArtworkTargets()
    for _,target in ipairs(self.artTargets or {}) do self:ReleaseArtworkTarget(target) end
end
function MusicScreen:BindArtwork(target,id,allowLoad)
    if tostring(target.id or "")~=tostring(id or "") then
        self:ReleaseArtworkTarget(target); target.id=id; target.widget:Hide()
    end
    if not id or target.asset then return end
    local kind=target.playlist and "playlistId" or "trackId"
    local asset=self.controller.PeekArtwork and self.controller:PeekArtwork(kind,id)
    if not asset and allowLoad then
        if self.controller.RequestArtwork then asset=self.controller:RequestArtwork(kind,id)
        else asset=target.playlist and self.controller:GetPlaylistArtwork(id) or self.controller:GetArtwork(id) end
    end
    local key=asset and asset.atlas and asset.image and asset.atlas.."/"..asset.image
    if key and target.asset~=key then
        local lease=self.controller.AcquireArtwork and self.controller:AcquireArtwork(asset)
        if self.controller.AcquireArtwork and not lease then return end
        self:ReleaseArtworkTarget(target); target.lease=lease
        target.widget:SetTexture(self.controller.modroot..asset.atlas,asset.image); target.widget:ScaleToSize(target.size,target.size); target.widget:Show(); target.asset=key
    end
end
function MusicScreen:UpdateArtwork()
    local t=((self.controller.state or {}).player or {}).track
    local id=t and tostring(t.id) or nil
    if self.playerCoverTrack~=id then
        self.playerCoverTrack=id; self.playerCoverAsset=nil
        self:ReleasePlayerCover()
    end
    local cover=t and self.controller.RequestArtwork and self.controller:RequestArtwork("trackId",t.id)
    local key=cover and cover.atlas and cover.image and cover.atlas.."/"..cover.image
    if key and key~=self.playerCoverAsset then
        local lease=self.controller.AcquireArtwork and self.controller:AcquireArtwork(cover)
        if lease or not self.controller.AcquireArtwork then
            self:ReleasePlayerCover(); self.playerCoverLease=lease
            self.playerCoverAsset=key
            self.playerCover:SetTexture(self.controller.modroot..cover.atlas,cover.image)
            self.playerCover:ScaleToSize(48,48); self.playerCover:SetTint(1,1,1,1)
        end
    end
    local still=not self.scrollList or math.abs(self.scrollList.current_scroll_pos-self.scrollList.target_scroll_pos)<=.12
    for _,a in ipairs(self.artTargets) do self:BindArtwork(a,a.id,still) end
end
function MusicScreen:ReleasePlayerCover()
    if self.playerCover and self.playerCover.inst:IsValid() then
        self.playerCover:SetTexture(UI.atlas,"card.tex"); self.playerCover:SetTint(.4,.28,.39,1)
    end
    if self.playerCoverLease then self.playerCoverLease:Release(); self.playerCoverLease=nil end
    self.playerCoverAsset=nil
end
function MusicScreen:Pager(parent,total,offset,limit,fn,y)
    UI.Button(parent,"‹ 上一页",-270,y or -212,112,30,function() if offset>0 then fn(math.max(0,offset-limit)) end end)
    UI.Label(parent,tostring(math.floor(offset/limit)+1).." / "..math.max(1,math.ceil(total/limit)),-20,y or -212,230,16,UI.muted,ANCHOR_MIDDLE)
    UI.Button(parent,"下一页 ›",460,y or -212,112,30,function() if offset+limit<total then fn(offset+limit) end end)
end
function MusicScreen:ShowHome(section)
    if self.controller.bridge and not self.controller.bridge:IsConfigured() then
        self:ShowConnectionHelp()
        return
    end
    self.section=section or "recommend"
    local p,v=self:NewContent("home",self.section=="charts" and "音乐排行榜" or "欢迎来到云间音乐！","曲库加载中…")
    self.homeData=nil
    if self.controller.GetCatalog then self:RefreshHome()
    else
        self:SourceRequest("/api/discover?section="..self.section.."&provider="..self.provider,"GET",nil,function(data)
            if v~=self.viewVersion then return end
            if not data or type(data.playlists)~="table" then self.subtitle:SetString(self.controller.backendConnected==false and "本机后台离线 · 点击右上角连接状态" or "曲库加载失败 · 请稍后重试"); return end
            self:RenderHomeData(p,data.playlists)
        end)
    end
end
function MusicScreen:RefreshHome(force)
    if self.view~="home" or not self.controller.GetCatalog then return end
    local data,pending,err=self.controller:GetCatalog(self.provider,self.section,force)
    if data then
        if self.homeData~=data then self:RenderHomeData(self.content,data) end
        self.subtitle:SetString((self.section=="charts" and "排行榜 · " or "推荐歌单 · ")..#data..(pending and " · 刷新中" or err and " · 刷新失败" or ""))
    else self.subtitle:SetString(err and (self.controller.backendConnected==false and "本机后台离线 · 点击右上角连接状态" or "曲库加载失败 · 请稍后重试") or "曲库加载中…") end
end
function MusicScreen:RenderHomeData(p,items)
    self.homeData=items
    if self.scrollList then self.scrollList:SetItemsData(items); self:UpdateArtwork(); return end
        self.subtitle:SetString("推荐歌单 · "..#items)
        self.scrollList=p:AddChild(TEMPLATES.ScrollingGrid(items,{
            widget_width=147,widget_height=174,num_visible_rows=2,num_columns=6,
            peek_percent=.72,scroll_per_click=.65,scrollbar_offset=0,
            item_ctor_fn=function()
                local w=Widget("music_album")
                w.button=UI.Button(w,"",0,8,136,136,function() if w.item then self:SelectPlaylist(w.item) end end)
                w.art=self:Artwork(w, nil,0,8,136,true)
                w.title=UI.Label(w,"",-68,-72,136,15)
                w.focus_forward=w.button
                return w
            end,
            apply_fn=function(_,w,item)
                if not item then if w.shown then w:Hide() end; w.item=nil; self:BindArtwork(w.art,nil,false); return end
                if not w.shown then w:Show() end
                if w.item~=item then
                    w.item=item; self:BindArtwork(w.art,item.id,false)
                    w.title:SetTruncatedString(tostring(item.name),136,nil,true)
                    w.button:SetTooltip(tostring(item.name))
                end
            end
        }))
        self.scrollList:SetPosition(93,0); UI.ScrollStyle(self.scrollList)
        self:UpdateArtwork()
end
function MusicScreen:ShowConnectionHelp()
    local online=self.controller.backendConnected==true
    local p=self:NewContent("setup","本机播放器连接",online and "后台在线 · 可重新连接或打开模组目录" or "后台尚未连接 · 按以下步骤启动")
    local root=(self.controller.modroot or ""):gsub("\\","/"):lower()
    local localInstall=root:match("/local_netease_music/?$")~=nil
    local steps=localInstall and {
        "1   当前使用本地测试安装。",
        "2   返回原配套播放器文件夹。",
        "3   双击“启动播放器.cmd”，等待后台启动。",
        "4   回到游戏，点击下方“重新连接”。",
    } or {
        "1   在 Steam 订阅本模组并等待下载。",
        "2   Steam 库右键饥荒联机版 → 管理 → 浏览本地文件。",
        "3   打开 mods/workshop-3836261433；若没有，请看下方路径。",
        "4   双击“一键启动播放器.cmd”，首次选择目录后回游戏重新连接。",
    }
    for i,text in ipairs(steps) do UI.Label(p,text,-340,175-(i-1)*43,830,19) end
    if not localInstall then
        UI.Label(p,"新版工坊路径：Steam库/steamapps/workshop/content/322330/3836261433",-340,-17,850,15,UI.muted)
    end
    UI.Label(p,"后台需要保持运行；账号信息保存在本机。",-340,-50,830,16,UI.muted)
    UI.Button(p,"重新连接",-200,-125,180,38,function()
        if not self.controller.Reconnect then self.message:SetString("当前版本不支持重新连接"); return end
        self.message:SetString("正在重新连接本机后台…")
        local before=self.playlistRequest or 0
        self.controller:Reconnect(function(data,err)
            if self.closed then return end
            if err or not data then self.message:SetString(tostring(err or "本机后台响应无效，请重试"))
            else self.message:SetString("重新连接成功"); if before==(self.playlistRequest or 0) then self:LoadPlaylists() end end
        end)
    end,true)
    if online and self.controller.OpenModFolder then
        UI.Button(p,"打开模组目录",30,-125,180,38,function()
            self.message:SetString("正在打开模组目录…")
            self.controller:OpenModFolder(function(data,err)
                if self.closed then return end
                self.message:SetString(err and tostring(err) or data and data.focused==true and "已打开模组目录" or "文件夹已打开；被游戏遮挡时按 Alt+Tab")
            end)
        end)
    end
    UI.Button(p,"更新与帮助",260,-125,180,38,function() self:ShowUpdates() end)
end
function MusicScreen:ShowConnection() self:ShowConnectionHelp() end
function MusicScreen:SelectPlaylist(item)
    self.queueView=false; self.selected=item; self.query=nil; self.filter=""; self:LoadTracks(0)
end
function MusicScreen:Search(query)
    if not query or query:match("^%s*$") then return end
    self.queueView=false; self.query=query; self.selected=nil; self.filter=""; self:LoadTracks(0)
end
function MusicScreen:ShowQueue()
    self.queueView=true; self.queueRevision=nil; self.query=nil; self.selected=nil; self.filter=""
    self:LoadTracks(0)
end
function MusicScreen:LoadTracks(offset)
    self.trackSession=(self.trackSession or 0)+1
    self.tracks={}; self.total=0; self.trackCache={}; self.trackPlaceholders={}; self.pendingBatches={}; self.failedBatches={}
    self.batchSize=self.query and 50 or 100
    self.trackSource=self.queueView and "/api/queue" or self.query and ("/api/search?q="..Escape(self.query).."&provider="..self.provider) or ("/api/playlist?id="..Escape(self.selected.id).."&provider="..self.provider)
    self:RenderTracks()
    self:FetchTrackBatch(offset or 0)
end
function MusicScreen:FetchTrackBatch(offset,done)
    local batch=math.floor(offset/self.batchSize)*self.batchSize
    if self.pendingBatches[batch] then return end
    self.pendingBatches[batch]=true
    local v=self.trackSession
    local separator=self.trackSource:find("?",1,true) and "&" or "?"
    self:SourceRequest(self.trackSource..separator.."offset="..batch.."&limit="..self.batchSize,"GET",nil,function(data,err)
        if v~=self.trackSession or (self.view~="tracks" and self.view~="queue") then return end
        self.pendingBatches[batch]=nil
        if not data or type(data.tracks)~="table" then
            self.failedBatches[batch]=true
            self.subtitle:SetString(self.controller.backendConnected==false and "本机后台离线 · 点击右上角连接状态" or self.queueView and "队列加载失败 · 点击刷新重试" or "曲库加载失败 · 重新打开歌单可重试")
            if done then done(false) end
            return
        end
        if self.queueView then
            if self.queueRevision~=nil and self.queueRevision~=data.queueRevision then self:ShowQueue(); return end
            self.queueRevision=data.queueRevision
        end
        self.total=math.max(0,tonumber(data.total) or batch+#data.tracks)
        for i,t in ipairs(data.tracks) do t._musicIndex=batch+i; self.trackCache[batch+i]=t end
        self:RefreshTrackData()
        if done then done(true,data) end
    end)
end
function MusicScreen:RefreshTrackData()
    local items={}; local filter=(self.filter or ""):lower()
    for i=1,self.total do
        local t=self.trackCache[i]
        if filter=="" then
            if not t and not self.trackPlaceholders[i] then self.trackPlaceholders[i]={_musicIndex=i,loading=true} end
            items[#items+1]=t or self.trackPlaceholders[i]
        elseif t and (tostring(t.name).." "..Artist(t)):lower():find(filter,1,true) then items[#items+1]=t end
    end
    self.tracks=items
    if self.scrollList then self.scrollList:SetItemsData(items) end
    if self.queueView and self.total==0 then
        self.subtitle:SetString("播放队列为空 · 从歌单或搜索结果中选择歌曲")
    else
        self.subtitle:SetString((self.queueView and "播放队列 · " or "共 ")..self.total.." 首"..(filter~="" and " · 已缓存歌曲中找到 "..#items.." 首" or ""))
    end
    self:UpdateArtwork()
end
-- Runs on the screen timer, never in a wheel handler or the row binder.
-- One batch in flight; fetch ahead of the visible window and fill filtered cache.
function MusicScreen:PrefetchTracks()
    if self.closed or (self.view~="tracks" and self.view~="queue") or not self.scrollList then return end
    if next(self.pendingBatches) then return end
    local first=math.max(1,(self.scrollList.displayed_start_index or 0)+1)
    local last=math.min(self.total,first+#self.scrollList:GetListWidgets()+self.batchSize)
    if self.filter and self.filter~="" then first=1; last=self.total end
    for i=first,last do
        local b=math.floor((i-1)/self.batchSize)*self.batchSize
        if not self.trackCache[i] and not self.failedBatches[b] then self:FetchTrackBatch(i-1); return end
    end
end
function MusicScreen:PlayTrack(t)
    if not t or t.loading then return end
    if self.queueView then
        if self.queueRevision==nil then return end
        self:Command({action="play",source="queue",trackId=t.id,queueRevision=self.queueRevision})
    elseif self.query then self:Command({action="play",source="search",trackId=t.id})
    elseif self.selected then self:Command({action="play",playlistId=self.selected.id,trackId=t.id}) end
end
function MusicScreen:RenderTracks()
    local p=self:NewContent(self.queueView and "queue" or "tracks",self.queueView and "播放队列" or self.query and ("搜索："..self.query) or self.selected.name,"曲库加载中…")
    if self.selected then
        self:Artwork(p,self.selected.id,-310,268,72,true)
        self.title:SetPosition(145,282); self.title:SetRegionSize(720,32)
        self.subtitle:SetPosition(145,253); self.subtitle:SetRegionSize(720,32)
    end
    if self.queueView then
        UI.Button(p,"刷新队列",-295,207,116,30,function() self:ShowQueue() end,true)
    else
        UI.Button(p,"播放全部",-295,207,116,30,function() self:PlayTrack(self.trackCache[1]) end,true)
    end
    UI.Button(p,self.grid and "列表" or "封面",478,207,76,30,function() self.grid=not self.grid; self:RenderTracks(); self:RefreshTrackData() end)
    UI.Button(p,"定位",393,207,70,30,function() self:LocateTrack() end)
    self.filterEdit=self:Edit(p,152,207,285,self.queueView and "筛选播放队列…" or "筛选歌单中的歌曲…",function(q)
        q=q or ""
        if self.filter==q then return end
        self.filter=q; self:RefreshTrackData(); self.scrollList:ResetScroll()
    end)
    if self.filter~="" then self.filterEdit:SetString(self.filter) end
    local grid=self.grid
    local width,height,columns=grid and 147 or 880,grid and 174 or 39,grid and 6 or 1
    self.scrollList=p:AddChild(TEMPLATES.ScrollingGrid({},{
        widget_width=width,widget_height=height,num_visible_rows=grid and 2 or 10,num_columns=columns,
        peek_percent=grid and .2 or .0,force_peek=true,end_offset=1,scroll_per_click=grid and .6 or 2.2,scrollbar_offset=0,
        item_ctor_fn=function()
            local w=Widget("music_track")
            w.button=UI.Button(w,"",0,0,grid and 136 or 878,grid and 136 or 37,function() self:PlayTrack(w.track) end)
            if grid then
                w.art=self:Artwork(w,nil,0,0,132,false)
                w.title=UI.Label(w,"",-66,-78,132,15); w.artist=UI.Label(w,"",-66,-96,132,13,UI.muted)
            else
                w.number=UI.Label(w,"",-430,0,32,13,UI.muted)
                w.art=self:Artwork(w,nil,-383,0,29,false)
                w.title=UI.Label(w,"",-358,7,660,17); w.artist=UI.Label(w,"",-358,-11,660,13,UI.muted)
                w.time=UI.Label(w,"",365,0,60,14,UI.muted,ANCHOR_RIGHT)
            end
            w.focus_forward=w.button; self.trackVisuals[#self.trackVisuals+1]=w
            return w
        end,
        apply_fn=function(_,w,t)
            if not t then if w.shown then w:Hide() end; w.track=nil; self:BindArtwork(w.art,nil,false); return end
            if not w.shown then w:Show() end
            if w.track~=t then
                w.track=t; self:BindArtwork(w.art,t.id,false)
                w.title:SetTruncatedString(t.loading and "正在加载…" or (t.trial and "[试听] " or "")..tostring(t.name),grid and 132 or 660,nil,true)
                w.artist:SetTruncatedString(t.loading and "" or Artist(t),grid and 132 or 660,nil,true)
                if w.number then w.number:SetString(tostring(t._musicIndex)); w.time:SetString(t.loading and "" or Clock(t.duration)) end
                local current=((self.controller.state or {}).player or {}).track
                w.highlight=current and tostring(current.id)==tostring(t.id) or false
                SetSelected(w.button,w.highlight)
            end
        end
    }))
    self.scrollList:SetPosition(93,-17); UI.ScrollStyle(self.scrollList)
end
function MusicScreen:LocateTrack()
    local current=((self.controller.state or {}).player or {}).track
    if not current then self.message:SetString("还没有正在播放的歌曲"); return end
    self.filter=""; self.filterEdit:SetString("")
    self:RefreshTrackData()
    local function find()
        for i,t in pairs(self.trackCache) do
            if tostring(t.id)==tostring(current.id) then self.scrollList:ScrollToDataIndex(i); self.message:SetString("已定位当前歌曲"); return true end
        end
    end
    if find() then return end
    local version=self.viewVersion
    self.message:SetString("正在缓存并定位当前歌曲…")
    local function scan(offset)
        if self.closed or version~=self.viewVersion then return end
        if offset>=self.total then self.message:SetString("当前歌曲不在此列表中"); return end
        if self.trackCache[offset+1] then scan(offset+self.batchSize); return end
        if next(self.pendingBatches) then
            self.locateTask=self.inst:DoStaticTaskInTime(.2,function() scan(offset) end); return
        end
        self:FetchTrackBatch(offset,function(ok)
            if ok and not find() then self.locateTask=self.inst:DoStaticTaskInTime(.05,function() scan(offset+self.batchSize) end) end
        end)
    end
    scan(0)
end
function MusicScreen:BuildPlayer()
    self.playerRoot=self.root:AddChild(Widget("music_player"))
    local player=self.playerRoot
    UI.Panel(player,98,-278,915,76,{1,1,1,1},"player")
    self.playerCover=player:AddChild(Image(UI.atlas,"card.tex")); self.playerCover:SetClickable(false); self.playerCover:SetPosition(-319,-274); self.playerCover:ScaleToSize(48,48); self.playerCover:SetTint(.4,.28,.39,1)
    self.nowTitle=UI.Label(player,"尚未播放",-281,-260,220,19)
    self.nowArtist=UI.Label(player,"选择歌单，开始播放",-281,-284,220,15,UI.muted)
    UI.IconButton(player,"previous",42,-264,18,function() self:Command({action="previous"}) end,"上一首")
    self.toggle=UI.IconButton(player,"play",100,-264,21,function() self:Command({action="toggle"}) end,"播放 / 暂停")
    UI.IconButton(player,"next",158,-264,18,function() self:Command({action="next"}) end,"下一首")
    self.queueButton=UI.IconButton(player,"list",212,-264,16,function() self:ShowQueue() end,"播放队列")
    self.mode=UI.Button(player,"列表循环",335,-260,100,30,function()
        local state=self.controller.state or {}; local mode=state.mode or "loop"
        self:Command({action="mode",value=mode=="loop" and "shuffle" or mode=="shuffle" and "single" or "loop"})
    end)
    self.seek=UI.Slider(player,122,-296,310,0,0,1,false,function(v) local p=(self.controller.state or {}).player or {}; self:Command({action="seek",value=v*(tonumber(p.duration) or 0)}) end)
    self.elapsed=UI.Label(player,"0:00",-96,-296,55,14,UI.muted,ANCHOR_RIGHT)
    self.duration=UI.Label(player,"0:00",286,-296,55,14,UI.muted)
    self.volume=UI.Slider(player,477,-278,112,.7,0,1,false,function(v) self:Command({action="volume",value=v}) end)
    UI.Icon(player,"volume",402,-278,15)
end
function MusicScreen:UpdateState()
    if self.view=="settings" and self.settingsWaiting and (self.controller.schema or {})[self.settingsGroup] then self.settingsWaiting=false; self:ShowSettings(self.settingsGroup,self.settingsPage) end
    local s=self.controller.state or {}; local p=s.player or {}; local t=p.track
    local beforeProvider=self.playlistRequest or 0
    if s.provider then self:ChangeProvider(s.provider) end
    local connected=self.controller.backendConnected
    local connectionText=connected==true and "后台 · 在线" or connected==false and "后台 · 离线" or "后台 · 连接中"
    if self.connectionText~=connectionText then
        local hadState=self.connectionText~=nil
        self.connectionText=connectionText; self.connectionButton:SetText(connectionText)
        if hadState and self.view=="setup" then
            self:ShowConnectionHelp()
            if connected==true and beforeProvider==(self.playlistRequest or 0) then self:LoadPlaylists() end
        end
    end
    if s.playerConnected and not self.connectionAnnounced then self.connectionAnnounced=true; self.message:SetString("本机播放器已连接 · 关闭面板后继续播放") end
    if self.controller.lastError then self.message:SetString(tostring(self.controller.lastError)) end
    if self.controller.GetCatalogIdentity then
        local identity=self.controller:GetCatalogIdentity(self.provider)
        if self.catalogIdentity~=identity then
            local hadIdentity=self.catalogIdentity~=nil
            self.catalogIdentity=identity; self.playlists={}; self.sidebarOffset=0; self:RenderSidebar()
            if hadIdentity and self.view=="tracks" and self.selected then
                self.trackSession=(self.trackSession or 0)+1
                self.selected,self.trackCache=nil,{}
                self:ShowHome("recommend")
            elseif self.view=="home" then self:ShowHome(self.section) end
        end
        self:LoadPlaylists()
        if self.view=="home" then self:RefreshHome() end
    end
    local sourceName=self.provider=="qq" and "QQ音乐" or "网易云"
    local currentAccount=s.provider==self.provider and s.account or nil
    local identity=self.provider..":"..(currentAccount and tostring(currentAccount.id or currentAccount.userId or currentAccount.nickname or "logged") or "")
    if self.view=="account" and self.accountIdentity~=identity then self:ShowAccount() end
    local account=(self.provider=="qq" and "QQ · " or "云 · ")..(currentAccount and tostring(currentAccount.nickname or "已登录") or "登录")
    self.account:SetTooltip(sourceName.." · "..(currentAccount and tostring(currentAccount.nickname or "已登录") or "扫码登录"))
    local sourceLabel=sourceName.." ⇄"
    if self.sourceLabel~=sourceLabel then self.sourceLabel=sourceLabel; self.sourceButton:SetText(sourceLabel) end
    if self.accountName~=account then
        self.accountName=account; self.account:SetText(account)
        if self.account.text then self.account.text:SetTruncatedString(account,80,nil,true) end
    end
    local icon=p.playing and "icon_pause.tex" or "icon_play.tex"
    if self.playIcon~=icon then self.playIcon=icon; self.toggle.icon:SetTexture(UI.atlas,icon) end
    local mode=s.mode=="shuffle" and "随机播放" or s.mode=="single" and "单曲循环" or "列表循环"
    if self.modeText~=mode then self.modeText=mode; self.mode:SetText(mode) end
    self.nowTitle:SetTruncatedString(t and tostring(t.name) or "尚未播放",220,nil,true); self.nowArtist:SetTruncatedString(t and Artist(t) or "选择歌单，开始播放",220,nil,true)
    if not self.volume.dragging then self.volume:SetValue(tonumber(p.volume) or .7) end
    for _,row in ipairs(self.trackVisuals or {}) do if row.track and row.button.inst:IsValid() then
        local highlight=t and tostring(t.id)==tostring(row.track.id) or false
        if row.highlight~=highlight then row.highlight=highlight; SetSelected(row.button,highlight) end
    end end
    self:RefreshSettingControls()
    if p.error and p.error~="" then self.message:SetString(tostring(p.error)) end
    self:UpdateArtwork(); self:UpdateProgress()
end
function MusicScreen:UpdateProgress()
    local p=(self.controller.state or {}).player or {}; local pos=tonumber(self.controller:GetPosition()) or tonumber(p.position) or 0
    self.elapsed:SetString(Clock(pos)); self.duration:SetString(Clock(p.duration))
    if not self.seek.dragging then self.seek:SetValue((tonumber(p.duration) or 0)>0 and pos/p.duration or 0) end
    if self.view=="now" and self.lyricLabels then
        local lyrics=self.controller:GetLyrics() or {}; local lines=lyrics.lines or EMPTY_LINES; local idx=0
        local lo,hi=1,#lines
        while lo<=hi do
            local mid=math.floor((lo+hi)/2); local l=lines[mid]
            if (tonumber(l.start or l.time) or 0)<=pos then idx=mid; lo=mid+1 else hi=mid-1 end
        end
        if self.nowLyricLines~=lines or self.nowLyricIndex~=idx then
            self.nowLyricLines,self.nowLyricIndex=lines,idx
            for i,label in ipairs(self.lyricLabels) do
                local line=lines[idx+i-3]
                local text=line and tostring(line.text or "") or (i==3 and #lines==0 and "暂无歌词 · 音乐仍在继续" or "")
                label:SetTruncatedString(text,420,nil,true)
            end
        end
        local t=p.track
        local id=t and tostring(t.id) or nil
        if id~=self.nowTrack then self:ShowNow() end
    end
end
function MusicScreen:ShowNow()
    local s=self.controller.state or {}; local t=(s.player or {}).track
    local p=self:NewContent("now","正在播放",t and Artist(t) or "在歌单中选择一首喜欢的歌曲")
    self.nowTrack=t and tostring(t.id) or nil; self.lyricLabels={}
    self.nowLyricLines,self.nowLyricIndex=nil,nil
    if t then self:Artwork(p,t.id,-178,40,290,false) end
    UI.Label(p,t and tostring(t.name) or "音乐，在旅途中",-323,-143,330,24)
    UI.Label(p,t and Artist(t) or "",-323,-175,330,18,UI.muted)
    for i=1,7 do self.lyricLabels[i]=UI.Label(p,"",80,180-(i-1)*51,420,i==3 and 24 or 19,i==3 and UI.pink or UI.muted,ANCHOR_MIDDLE) end
    self:UpdateArtwork(); self:UpdateProgress()
end
-- Keep one write in flight. Repeated drags coalesce into the next patch,
-- so older responses cannot overtake newer settings on the local backend.
function MusicScreen:FlushSettings()
    if self.settingsWrite or not self.queuedSettings then return end
    local patch=self.queuedSettings; self.queuedSettings=nil; self.settingsWrite=patch
    self.controller:SetSettings(patch,function(data,err)
        self.settingsWrite=nil
        if not self.closed then
            self.message:SetString(err or "设置已保存，即时生效")
            self:RefreshSettingControls()
        end
        self:FlushSettings()
    end)
end
function MusicScreen:SaveSetting(group,key,value)
    self.queuedSettings=self.queuedSettings or {}
    local patch=self.queuedSettings
    patch[group]=patch[group] or {}; patch[group][key]=value
    if group=="player" and key=="shuffle" and value then patch.player.repeatOne=false end
    if group=="player" and key=="repeatOne" and value then patch.player.shuffle=false end
    self.message:SetString("正在保存设置…")
    self:RefreshSettingControls(); self:FlushSettings()
end
function MusicScreen:RefreshSettingControls()
    if self.view~="settings" or not self.settingControls then return end
    local group=self.settingsGroup
    local values=(self.controller.settings or {})[group] or {}
    local writing=self.settingsWrite and self.settingsWrite[group]
    local queued=self.queuedSettings and self.queuedSettings[group]
    for key,update in pairs(self.settingControls) do
        local field=self.controller.schema[group][key]
        local value=values[key]; if value==nil then value=field.default end
        if writing and writing[key]~=nil then value=writing[key] end
        if queued and queued[key]~=nil then value=queued[key] end
        update(value)
    end
end
function MusicScreen:SettingsTabs(parent,selected)
    local groups={"lyrics","player","card","island","updates"}
    for i,g in ipairs(groups) do
        UI.Button(parent,GROUPS[g] or "更新与帮助",-282+(i-1)*176,207,164,32,function() self:ShowSettings(g,0) end,g==selected)
    end
end
function MusicScreen:ShowUpdates()
    local p=self:NewContent("updates","更新与帮助","Steam 更新工坊与随包后台 · GitHub 提供备用下载")
    self:SettingsTabs(p,"updates")
    UI.Panel(p,88,93,900,166,{1,1,1,.86},"card")
    self.updateTitle=UI.Label(p,"正在读取版本信息…",-335,145,830,24)
    self.updateVersion=UI.Label(p,"",-335,108,830,18)
    self.updateDetail=UI.Label(p,"",-335,75,830,16,UI.muted)
    self.updateNotes=UI.Label(p,"",-335,43,830,16,UI.muted)
    self.checkUpdateButton=UI.Button(p,"立即检查更新",-220,-26,210,38,function() self:ReadUpdates(true) end,true)
    UI.Button(p,"GitHub 版本下载",20,-26,210,38,function()
        VisitURL("https://github.com/Zechariah0121/dst-music/releases")
    end)
    UI.Button(p,"Steam 工坊页面",260,-26,210,38,function()
        VisitURL("https://steamcommunity.com/sharedfiles/filedetails/?id=3836261433")
    end)
    UI.Panel(p,88,-131,900,130,{1,1,1,.7},"card")
    UI.Label(p,"更新步骤",-335,-89,830,18)
    UI.Label(p,"Mod：等待 Steam 下载更新，再重启游戏。",-335,-121,830,17,UI.muted)
    UI.Label(p,"后台：更新后运行工坊目录的一键启动器，沿用已记住的安装位置。",-335,-151,850,17,UI.muted)
    UI.Label(p,"“音乐与环境”可关闭自动检查。这里只检查版本，不会自动安装。",-335,-179,850,16,UI.muted)
    if self.controller.updateState then self:RenderUpdates(self.controller.updateState) end
    self:ReadUpdates(false)
end
function MusicScreen:RenderUpdates(data,err)
    if self.view~="updates" then return end
    local names={idle="尚未检查更新",checking="正在检查更新…",available="发现新版本",current="当前已是最新可用版本",unpublished="暂未发布可用版本",error="更新检查未完成"}
    self.updateTitle:SetString(err and "无法读取版本信息" or names[data and data.status] or "版本信息不可用")
    local current=data and data.currentVersion or "未知"
    local latest=data and data.latest
    self.updateVersion:SetString("当前后台："..tostring(current)..(latest and "    最新发布："..tostring(latest.version) or ""))
    self.updateDetail:SetTruncatedString(tostring(err or data and data.error and data.error.message or data and data.status=="unpublished" and "GitHub 仓库已经就绪，等待作者上传发行版。" or data and data.status=="checking" and "请稍候，正在读取官方发布列表。" or "发布来源：Zechariah0121/dst-music · 固定工坊 3836261433"),820,nil,true)
    self.updateNotes:SetTruncatedString(data and data.stale and "当前显示上次检查结果，请稍后重试。" or latest and tostring(latest.notes or "") or "测试版会检查后续测试版与正式版。",820,nil,true)
    if latest and latest.notes then self.updateNotes:SetTooltip(tostring(latest.notes)) end
end
function MusicScreen:ReadUpdates(force)
    if self.view~="updates" or self.updatePending then return end
    if self.updateTask then self.updateTask:Cancel(); self.updateTask=nil end
    self.updatePending=true; self.checkUpdateButton:SetText("检查中…")
    local version=self.viewVersion
    self:Request(force and "/api/updates/check" or "/api/updates",force and "POST" or "GET",force and {} or nil,function(data,err)
        if self.view~="updates" or version~=self.viewVersion then return end
        self.updatePending=false; self.checkUpdateButton:SetText("立即检查更新")
        if data then self.controller.updateState=data end
        self:RenderUpdates(data or self.controller.updateState,err)
        if data and data.status=="checking" then
            self.updateTask=self.inst:DoStaticTaskInTime(1,function()
                self.updateTask=nil
                if not self.closed and self.view=="updates" and version==self.viewVersion then self:ReadUpdates(false) end
            end)
        end
    end)
end
function MusicScreen:ShowSettings(group,page)
    if group=="updates" then return self:ShowUpdates() end
    local keep=(not group or group==self.settingsGroup) and self.settingsScroll and self.settingsScroll.current_scroll_pos or 0
    self.settingsGroup=group or self.settingsGroup; self.settingsPage=0
    local p=self:NewContent("settings","设置","修改即时生效并自动保存 · 不支持的功能会明确禁用")
    self:SettingsTabs(p,self.settingsGroup)
    local schema=(self.controller.schema or {})[self.settingsGroup]
    if not schema then
        UI.Label(p,"正在读取设置…",-335,130,790,20,UI.muted)
        self.settingsWaiting=true; self.controller:RefreshSettings()
        return
    end
    local fields={}; local used={}
    for _,key in ipairs(ORDERS[self.settingsGroup] or {}) do if schema[key] then fields[#fields+1]=key; used[key]=true end end
    local extra={}; for key in pairs(schema) do if not used[key] then extra[#extra+1]=key end end; table.sort(extra); for _,k in ipairs(extra) do fields[#fields+1]=k end
    local rows=math.ceil(#fields/2)
    local layouts,cards={},{}
    local bottom={190,190}
    local assigned={}
    local function section(col,title,keys)
        local available={}
        for _,key in ipairs(keys) do if schema[key] then available[#available+1]=key; assigned[key]=true end end
        if #available==0 then return end
        local top=bottom[col+1]; local h=32+#available*52
        cards[#cards+1]={x=-224+col*448,y=top-h/2,height=h,title=title,top=top}
        for i,key in ipairs(available) do layouts[key]={left=-425+col*448,y=top-48-(i-1)*52} end
        bottom[col+1]=top-h-14
    end
    -- Pack semantic cards into the shorter column. Unsupported fields are
    -- collected last so unavailable features do not crowd out usable ones.
    local definitions={
        lyrics={
            {"外观 · 歌词样式",{"enabled","worldMode","scale","smoothFont","splitLines","textColor"}},
            {"位置 · 世界歌词",{"distance","facePlayer","keepAway","spread","stayOnScreen","aboveGround"}},
            {"辉光 · 柔和光晕",{"glow","glowNightOnly","glowColor","glowStrength","glowRadius"}},
            {"逐词与动态 · 文字动画",{"wordPop","wiggle","wiggleFps","wiggleAmount","textFlash","flashSize"}},
            {"翻译 · 双语歌词",{"translation","translationColor","translationAnimation","translationWiggle"}},
            {"歌曲信息 · 经典样式",{"nowPlaying","showCover"}},
            {"节拍律动",{"dance","danceAuto","danceTap","danceSpin","danceAmount","danceOffset","danceBpm"}},
        },
        player={
            {"音乐来源与播放",{"musicSource","volume","normalize","shuffle","repeatOne"}},
            {"入口与快捷键",{"showTopLeftButton","openKey","keyPause","keyPrev","keyNext","keyVolUp","keyVolDown","keyLyrics"}},
            {"环境空间音效",{"envAudio","envStrength","envCave","envLunar","envOcean","envRuins","envAtrium","envForest","envRain","envWater","envIndoor"}},
            {"界面与更新",{"language","checkUpdates"}},
        },
        card={{"歌曲卡片 · 屏幕信息",{"enabled","scale","showPaused","posX","posY"}}},
        island={{"动态岛 · 歌曲提示",{"enabled","glass","showMusic","songNotify","scale","notifyTime"}}},
    }
    local unavailable={}
    for _,group in ipairs(definitions[self.settingsGroup] or {}) do
        local available={}
        for _,key in ipairs(group[2]) do
            if schema[key] then
                if schema[key].supported==false then unavailable[#unavailable+1]=key; assigned[key]=true
                else available[#available+1]=key end
            end
        end
        section(bottom[1]>=bottom[2] and 0 or 1,group[1],available)
    end
    local rest={}; for _,key in ipairs(fields) do if not assigned[key] then rest[#rest+1]=key end end
    local supportedRest={}
    for _,key in ipairs(rest) do
        if schema[key].supported==false then unavailable[#unavailable+1]=key; assigned[key]=true
        else supportedRest[#supportedRest+1]=key end
    end
    section(bottom[1]>=bottom[2] and 0 or 1,"其他调节",supportedRest)
    -- Start unavailable content below both columns.
    if #unavailable>0 then bottom[1]=math.min(bottom[1],bottom[2]); section(0,"暂未支持",unavailable) end
    local height=190-math.min(bottom[1],bottom[2])
    local body=Widget("music_settings_body")
    local host=p
    self.settingRows={}; self.settingControls={}
    p=body
    for _,card in ipairs(cards) do
        UI.Panel(p,card.x,card.y,430,card.height,{1,1,1,.86},"card")
        UI.Label(p,card.title,card.x-200,card.top-17,395,17,UI.ink)
    end
    local groupid=self.settingsGroup
    for n,key in ipairs(fields) do if key then
        local field=schema[key]; local layout=layouts[key]; local left,y=layout.left,0
        local row=body:AddChild(Widget("music_setting_row"))
        row:SetPosition(0,layout.y)
        self.settingRows[#self.settingRows+1]={widget=row,y=layout.y}
        p=row
        local values=(self.controller.settings or {})[groupid] or {}; local value=values[key]; if value==nil then value=field.default end
        local supported=field.supported~=false
        UI.Label(p,LABELS[key] or key,left,y+7,230,18,supported and UI.ink or UI.muted)
        local description=supported and (NOTES[key] or "") or (field.reason or "当前版本暂不支持")
        local note=UI.Label(p,description,left,y-15,235,13,UI.muted)
        if not supported then note:SetTooltip(field.reason or "当前平台暂不支持") end
        local update=function(v) value=v end
        self.settingControls[key]=function(v) update(v) end
        local function save(v) self:SaveSetting(groupid,key,v) end
        if field.type=="boolean" then
            local b=UI.Toggle(p,value,left+365,y,function() save(not value) end)
            update=function(v) value=v; b:SetValue(v) end
            if description~="" then b:SetTooltip(description) end
            local spaceNotes={envLunar="月岛区域触发空间音色",envOcean="海上区域触发空间音色",envRuins="遗迹区域触发空间音色",envAtrium="中庭区域触发空间音色",envForest="桦树林区域触发空间音色"}
            if supported and spaceNotes[key] then
                note:SetString(spaceNotes[key]); b:SetTooltip("跟随 DST 当前区域自动切换；环境效果强度同时控制这些空间音色，雨天柔化独立开关。")
            end
            if supported and key=="envRain" then
                note:SetString("雨天高频柔化与轻度遮蔽")
                b:SetTooltip("跟随降雨自动柔化高频并加入轻度遮蔽；此开关与区域空间效果独立。")
            end
            if key=="wordPop" then b:SetTooltip("有逐字时间时跟随演唱；普通歌词按词展开") end
            if not supported then b:Disable(); b:SetTooltip(field.reason)
            elseif key=="envWater" or key=="envIndoor" then
                note:SetString("DST 暂无对应场景检测")
                b:SetTooltip(key=="envWater" and "水下滤波算法已实现；DST 当前没有对应的水下场景检测，此设置不会自动触发。" or "室内混响算法已实现；DST 当前没有对应的室内场景检测，此设置不会自动触发。")
            end
        elseif key=="textColor" or key=="translationColor" then
            local colour=tonumber(value) or 0
            local swatch=UI.Panel(p,left+250,y,20,20,{math.floor(colour/65536)%256/255,math.floor(colour/256)%256/255,colour%256/255,1},"circle")
            local e=self:Edit(p,left+324,y,92,"RRGGBB",function(text) local hex=text:gsub("#",""); local c=tonumber(hex,16); if #hex==6 and c then save(c) else self.message:SetString("请输入六位十六进制颜色，例如 F7E1D7") end end)
            e:SetString(string.format("%06X",colour)); e:SetTextLengthLimit(7)
            update=function(v)
                if value==v then return end
                value=v; local c=tonumber(v) or 0
                swatch:SetTint(math.floor(c/65536)%256/255,math.floor(c/256)%256/255,c%256/255,1)
                e:SetString(string.format("%06X",c))
            end
        elseif key=="glowColor" or key=="language" or key=="musicSource" then
            local options=key=="glowColor" and {[0]="跟随歌词",[1]="粉色",[2]="蓝色",[3]="金色"} or key=="language" and {[-1]="自动",[0]="中文",[1]="英文"} or {[0]="网易云",[1]="QQ音乐"}
            local b=UI.Button(p,options[value] or tostring(value),left+325,y,125,30,function() local nextv=key=="musicSource" and (value==1 and 0 or 1) or value+1; if key~="musicSource" and nextv>field.max then nextv=field.min end; save(nextv) end)
            b.musicValue=value
            update=function(v) value=v; if b.musicValue~=v then b.musicValue=v; b:SetText(options[v] or tostring(v)) end end
            if description~="" then b:SetTooltip(description) end
            if not supported then b:Disable(); b:SetTooltip(field.reason) end
        elseif key=="openKey" or key:sub(1,3)=="key" then
            local b=UI.Button(p,UI.KeyName(value,key=="openKey"),left+319,y,146,30,function()
                self.keyCapture={group=groupid,key=key,button=nil}; self.message:SetString("按下要绑定的按键 · ESC 取消 · Delete 清除")
            end)
            update=function(v) if value~=v then value=v; b:SetText(UI.KeyName(v,key=="openKey")) end end
            b:SetTooltip(key=="openKey" and "点击后按新按键绑定；Esc 取消，Delete 恢复为跟随 Mod 配置。" or "点击后按新按键绑定；Esc 取消，Delete 清除绑定。")
        elseif field.type=="number" then
            local function numberNote(v) return (description~="" and description.." · " or "")..string.format(field.integer and "%d" or "%.2f",tonumber(v) or 0) end
            note:SetString(numberNote(value))
            local slider=UI.Slider(p,left+319,y,128,value,field.min,field.max,field.integer,save)
            update=function(v) value=v; if supported and not slider.dragging then slider:SetValue(v); slider.committedValue=slider.value; note:SetString(numberNote(v)) end end
            slider.onpreview=function(v) note:SetString(numberNote(v)) end
            if description~="" then slider.rail:SetTooltip(description) end
            if not supported then slider.rail:Disable(); slider.rail:SetTooltip(field.reason); note:SetString(description) end
        end
    end end
    -- Match CharacterBio's vanilla contract: populate the entire subtree
    -- before attaching it below TrueScrollArea's scissored root. Also put an
    -- explicit local clip on the moving body after all descendants exist;
    -- the previous empty-body setup relied only on inherited native state.
    local area=host:AddChild(TrueScrollArea({widget=body,offset={x=0,y=0},size={width=880,height=height}},
        {x=-440,y=-200,width=880,height=390},{h_offset=-20,scroll_per_click=46}))
    self.settingsScroll=area
    if UI.RefreshTheme then UI.RefreshTheme(body) end
    area.bg:SetPosition(0,-5)
    area:SetPosition(93,0); UI.ScrollStyle(area,-200,190)
    local refresh=area.RefreshView
    local settingRows=self.settingRows
    area.RefreshView=function(scroll)
        refresh(scroll)
        local pos=scroll.current_scroll_pos
        body:SetScissor(-440,-200-pos,880,390)
        -- Hide complete controls crossing the viewport boundary as well as
        -- offscreen rows, so their hit targets cannot cover the player bar.
        for _,r in ipairs(settingRows) do
            local y=r.y+pos
            local visible=y-26>=-200 and y+26<=190
            if visible and not r.widget.shown then r.widget:Show()
            elseif not visible and r.widget.shown then
                r.widget:Hide()
                for _,e in ipairs(self.edits or {}) do
                    if e.parent==r.widget then e:SetEditing(false) end
                end
            end
        end
    end
    self:RefreshSettingControls()
    area.current_scroll_pos=math.min(keep,area.scroll_pos_end)
    area.target_scroll_pos=area.current_scroll_pos
    area:RefreshView()
end
function MusicScreen:ShowAccount()
    local s=self.controller.state or {}; local account=s.provider==self.provider and s.account or nil
    local sourceName=self.provider=="qq" and "QQ音乐" or "网易云音乐"
    self.accountIdentity=self.provider..":"..(account and tostring(account.id or account.userId or account.nickname or "logged") or "")
    local p=self:NewContent("account",sourceName.."账号",account and "账号信息保存在本机；关闭游戏面板后继续播放" or "使用手机"..sourceName.." App 扫码登录，账号信息保存在本机")
    if account then
        UI.Label(p,tostring(account.nickname or "已登录"),-300,130,760,30)
        UI.Label(p,"账号已连接，可以浏览自己的歌单。",-300,80,760,20,UI.muted)
        UI.Button(p,"刷新我的歌单",-210,15,180,38,function() self:LoadPlaylists(true); self.message:SetString("已请求刷新歌单") end,true)
        UI.Button(p,"更换账号 / 扫码",25,15,200,38,function() self:StartLogin() end)
        UI.Button(p,"退出账号",250,15,150,38,function()
            self:SourceRequest("/api/logout","POST",{provider=self.provider},function(data)
                if data then if self.controller.InvalidateCatalog then self.controller:InvalidateCatalog(self.provider) end; self.controller.state.account=nil; self.playlists={}; self:RenderSidebar(); self:ShowAccount(); self.controller:Poll() end
            end)
        end)
    else
        UI.Label(p,"无需打开浏览器，音频由本机后台播放器播放。",-300,140,780,20,UI.muted)
        UI.Button(p,"生成登录二维码",80,60,230,44,function() self:StartLogin() end,true)
    end
end
function MusicScreen:StartLogin()
    local p,ver=self:NewContent("login","扫码登录","正在生成二维码…")
    local provider=self.provider
    local sourceVersion=self.sourceVersion or 0
    self.controller:Request("/api/login/start","POST",{provider=provider},function(data,err)
        if self.closed or ver~=self.viewVersion or sourceVersion~=(self.sourceVersion or 0) then
            if data and data.key then self.controller:Request("/api/login/cancel","POST",{key=data.key,provider=provider}) end
            return
        end
        if err then self.message:SetString(tostring(err)) end
        if not data or not data.key then self.subtitle:SetString("无法生成二维码，请稍后重试"); return end
        self.loginKey,self.loginProvider=data.key,provider
        self:SourceRequest("/api/login/artwork?key="..Escape(data.key),"GET",nil,function(qr)
            if ver~=self.viewVersion or self.loginKey~=data.key then return end
            local asset=qr and qr.asset and self.controller:AcquireArtwork(qr.asset)
            if asset then
                local image=p:AddChild(Image(self.controller.modroot..asset.atlas,asset.image)); image:SetPosition(70,40); image:ScaleToSize(234,234); image:SetClickable(false)
                self.loginImage,self.loginLease=image,asset
                self.subtitle:SetString("打开手机"..(self.provider=="qq" and "QQ音乐" or "网易云音乐").." App，扫描二维码并确认登录")
            else self.subtitle:SetString("二维码暂时不可用，请重新生成") end
        end)
        UI.Button(p,"重试确认",-30,-145,170,36,function()
            if self.loginPending or self.loginKey~=data.key then return end
            if self.loginTask then self.loginTask:Cancel(); self.loginTask=nil end
            self.loginErrors=0
            self:CheckLogin(ver,data.key)
        end)
        UI.Button(p,"重新生成",170,-145,170,36,function() self:StartLogin() end)
        self:CheckLogin(ver,data.key)
    end)
end
function MusicScreen:CheckLogin(ver,key)
    self.loginTask=nil
    if self.closed or ver~=self.viewVersion or self.loginKey~=key or self.loginPending then return end
    self.loginPending=true
    self:SourceRequest("/api/login/check?key="..Escape(key),"GET",nil,function(data,err)
        if self.closed or ver~=self.viewVersion or self.loginKey~=key then return end
        self.loginPending=false
        if err then
            -- 网络或本机保存失败时保留原二维码，只重试有限次数，避免不断要求重扫。
            self.loginErrors=(self.loginErrors or 0)+1
            if self.loginErrors<=3 then
                self.subtitle:SetString("登录确认暂未完成，正在重试（"..self.loginErrors.."/3）；原因见下方")
                self.loginTask=self.inst:DoStaticTaskInTime(self.loginErrors*2,function() self:CheckLogin(ver,key) end)
            else
                self.subtitle:SetString("自动确认已暂停：处理下方问题后点「重试确认」，无需重新扫码")
            end
            return
        end
        self.loginErrors=0
        local code=data and tonumber(data.code)
        if code==803 or data and (data.status=="success" or data.loggedIn or data.account) then
            self.loginKey,self.loginProvider=nil,nil
            if data.account then self.controller.state.account=data.account end
            self.subtitle:SetString("登录成功，正在刷新歌单…"); if self.controller.InvalidateCatalog then self.controller:InvalidateCatalog(self.provider) end; self.playlists={}; self.sidebarOffset=0; self:RenderSidebar(); self:LoadPlaylists(); self.controller:Poll()
            self.inst:DoStaticTaskInTime(1,function() if not self.closed and ver==self.viewVersion then self:ShowAccount() end end)
        elseif data and (data.status=="failed" or data.status=="canceled") then
            self.loginKey,self.loginProvider=nil,nil
            self.subtitle:SetString(type(data.message)=="string" and data.message~="" and data.message or "登录已结束，请重新生成二维码")
        elseif code==800 or data and data.status=="expired" then
            self.loginKey,self.loginProvider=nil,nil
            self.subtitle:SetString("二维码已过期，请重新生成")
        else
            if code==802 or data and data.status=="scanned" then self.subtitle:SetString("已扫码，请在手机上确认登录") end
            self.loginTask=self.inst:DoStaticTaskInTime(2,function() self:CheckLogin(ver,key) end)
        end
    end)
end
function MusicScreen:Stop()
    TheFrontEnd:LockFocus(false)
    for _,e in ipairs(self.edits or {}) do if e.inst:IsValid() then e:SetEditing(false) end end
    self.viewVersion=self.viewVersion+1; self.requestVersion=self.requestVersion+1; self.playlistRequest=(self.playlistRequest or 0)+1
    self:ReleaseArtworkTargets()
    self:ReleasePlayerCover()
    if self.updateTask then self.updateTask:Cancel(); self.updateTask=nil end
    if self.unsubscribe then self.unsubscribe(); self.unsubscribe=nil end
    if self.tick then self.tick:Cancel(); self.tick=nil end
    self:CancelLogin()
    if self.locateTask then self.locateTask:Cancel(); self.locateTask=nil end
    if self.scrollList then self.scrollList:StopUpdating() end
    if self.settingsScroll then self.settingsScroll:StopUpdating() end
end
function MusicScreen:Close()
    if self.closed then return end
    self.closed=true; self:Stop(); TheFrontEnd:PopScreen(self)
end
function MusicScreen:OnDestroy()
    self.closed=true; self:Stop(); local cb=self.onclose; self.onclose=nil; if cb then cb() end; Screen.OnDestroy(self)
end
function MusicScreen:OnControl(control,down)
    if self.keyCapture then return true end
    if control==CONTROL_SCROLLFWD or control==CONTROL_SCROLLBACK then
        if down then
            local list=self.scrollList or self.settingsScroll
            if list then list:Scroll((control==CONTROL_SCROLLFWD and 1 or -1)*(list.scroll_per_click or 1)) end
        end
        return true
    end
    if Screen.OnControl(self,control,down) then return true end
    if control==CONTROL_CANCEL and not down then self:Close(); return true end
    return true -- modal: never leak movement/action controls into the world
end
function MusicScreen:OnRawKey(key,down)
    if self.keyCapture then
        if not down then
            local c=self.keyCapture; self.keyCapture=nil
            if key==KEY_ESCAPE then self.message:SetString("已取消按键绑定")
            else self:SaveSetting(c.group,c.key,key==KEY_DELETE and 0 or key) end
        end
        return true
    end
    return Screen.OnRawKey(self,key,down)
end
return MusicScreen
