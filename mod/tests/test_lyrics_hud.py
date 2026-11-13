"""Offline Lua contracts; no claim of game render/network verification."""
import pathlib
import unittest
from lupa.lua51 import LuaRuntime
from luaparser import ast

ROOT = pathlib.Path(__file__).resolve().parents[1]


class LyricsContracts(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('package.path = ' + repr(str(ROOT / 'scripts' / '?.lua').replace('\\', '/')) + ' .. ";" .. package.path')

    def test_shared_native_asset_leases(self):
        self.lua.execute(r'''
            function Class(ctor)
                local c={};c.__index=c
                return setmetatable(c,{__call=function(_,...) local o=setmetatable({},c);ctor(o,...);return o end})
            end
            Prefabs={};local loads,unloads,unregisters=0,0,0
            function resolvefilepath_soft(path) return path end
            function Prefab(name,fn,assets) return {name=name,assets=assets} end
            function Asset(kind,path) return {kind,path} end
            function RegisterSinglePrefab(prefab) Prefabs[prefab.name]=prefab end
            TheSim={LoadPrefabs=function() loads=loads+1 end,
                UnloadPrefabs=function() unloads=unloads+1 end,
                UnregisterPrefabs=function(_,names) unregisters=unregisters+1;Prefabs[names[1]]=nil end,
                AtlasContains=function() return true end}
            local A=require('dangomusic_assets')('mod/')
            local hash=string.rep('a',64)
            local desc={atlas='images/music_cache/'..hash..'.xml',image=hash..'.tex'}
            local first=A:Acquire(desc);local second=A:Acquire(desc);local third=A:Acquire(desc)
            assert(first and second and third and loads==1)
            first:Release();first:Release();assert(unloads==0 and unregisters==0)
            second:Release();assert(unloads==0,'remaining consumer must retain native asset')
            third:Release();assert(unloads==1 and unregisters==1,'last reference unloads exactly once')
            A:Close();assert(unloads==1)
        ''')

    def test_lua_syntax(self):
        for path in (ROOT / 'scripts/widgets').glob('music_*.lua'):
            ast.parse(path.read_text(encoding='utf-8'))

    def test_timing_and_utf8_boundaries(self):
        self.lua.execute('''
            local L = require "widgets/music_lyriclogic"
            local lines = {
                {start=1, ["end"]=3, text="你好"},
                {start=5, ["end"]=7, text="世界"}
            }
            assert(L.FindLine(lines, 0) == nil)
            assert(L.FindLine(lines, 1) == 1)
            assert(L.FindLine(lines, 2.99) == 1)
            assert(L.FindLine(lines, 3) == nil) -- instrumental gap
            assert(L.FindLine(lines, 5) == 2)
            assert(L.FindLine(lines, 7) == nil)
            assert(L.FindLine(lines, 1.5) == 1) -- seek backwards
            local glyphs, precise = L.Glyphs(lines[1], "line", true)
            assert(#glyphs == 2 and glyphs[1].text == "你" and not precise)
            assert(glyphs[1].start == glyphs[2].start) -- never invented timing
            local line = {start=1, ["end"]=4, text="你\n好", words={
                {text="你", start=1, ["end"]=2},
                {text="\n好", start=2, ["end"]=4}
            }}
            glyphs, precise = L.Glyphs(line, "word", true)
            assert(precise and #glyphs == 2 and glyphs[2].row == 1)
            assert(glyphs[2].start == 2 and glyphs[2].finish == 4)
            glyphs = L.Glyphs({text=string.rep("A",200)}, "none", true)
            assert(#glyphs == 96)
        '''.replace('text="你\n好"', 'text="你\\n好"').replace('text="\n好"', 'text="\\n好"'))

    def test_font_metrics_and_two_row_word_wrap(self):
        self.lua.execute('''
            local L=require('widgets/music_lyriclogic')
            local g, _, rows, width=L.Glyphs({text='Wi'},'line',false,
                function(c) return c=='W' and 21 or 3 end)
            assert(width==24 and g[2].x-g[1].x==12)
            local sentence='We need to communicate and understand each other in every conversation'
            g, _, rows=L.Glyphs({text=sentence},'line',true)
            assert(rows==1)
            local start=assert(sentence:find('communicate',1,true))
            local row=g[start].row
            for i=start,start+#'communicate'-1 do assert(g[i].row==row) end
            for _,glyph in ipairs(g) do assert(glyph.row<=1) end
            g, _, rows=L.Glyphs({text=string.rep('中文',40)},'line',true)
            assert(rows==1)
            for _,glyph in ipairs(g) do assert(glyph.row<=1) end
            g, _, rows=L.Glyphs({text='first\\nsecond\\nthird'},'line',true)
            assert(rows==1)
            g, _, rows=L.Glyphs({text=sentence},'line',false)
            assert(rows==0)
        ''')

    def test_yrc_complete_english_words_keep_original_times(self):
        self.lua.execute('''
            local L=require('widgets/music_lyriclogic')
            local line={start=1,['end']=5,words={
                {text='Bright',start=1,['end']=1.3},
                {text='est ',start=1.3,['end']=1.6},
                {text='light. ',start=2,['end']=3},
                {text='你',start=3,['end']=3.5},
                {text='好',start=3.5,['end']=4}}}
            local g,p=L.Glyphs(line,'word',true)
            assert(p and g[1].revealWord.text=='Brightest')
            for i=1,9 do assert(g[i].popStart==1) end
            assert(g[7].start==1.3 and g[7].finish==1.6)
            assert(line.words[2].start==1.3 and line.words[2].text=='est ')
            assert(g[11].popStart==2)
            assert(g[18].text=='你' and g[18].popStart==3)
            assert(g[19].text=='好' and g[19].popStart==3.5)
            for _,t in ipairs({1.06,1.2,1.4,1.9}) do
                for i=1,9 do assert(L.Appearance(g[i],t,true)) end
                assert(not L.Appearance(g[11],t,true))
            end
            assert(L.Appearance(g[11],2.06,true))
            assert(not L.Appearance(g[18],2.9,true))
            assert(L.Appearance(g[18],3.06,true))
            assert(not L.Appearance(g[19],3.3,true))
            assert(L.Appearance(g[19],3.56,true))
            g=L.Glyphs({start=0,['end']=3,words={
                {text="don'",start=0,['end']=.3},{text='t stop',start=.3,['end']=2}}},'word',true)
            assert(g[1].revealWord.text=="don't" and g[5].popStart==0)
            assert(g[7].popStart==.3)
            g=L.Glyphs({start=0,['end']=3,words={
                {text='one'..string.char(10)..'two',start=0,['end']=2}}},'word',true)
            assert(g[1].revealWord~=g[4].revealWord)
        ''')

    def test_lrc_decorative_reveal_pause_seek_and_utf8(self):
        self.lua.execute('''
            local L=require('widgets/music_lyriclogic')
            local line={text='We see bright light',start=10,['end']=14}
            local g,p=L.Glyphs(line,'line',true,nil,14)
            assert(not p and line.words==nil)
            assert(g[1].popStart==10 and math.abs(g[4].popStart-10.33)<.00001)
            assert(math.abs(g[8].popStart-10.66)<.00001)
            assert(math.abs(g[15].popStart-10.99)<.00001)
            for _,x in ipairs(g) do assert(x.start==10 and x.finish==14) end
            assert(L.Appearance(g[1],10.06,true))
            assert(not L.Appearance(g[4],10.06,true))
            assert(L.Appearance(g[4],10.39,true))
            assert(not L.Appearance(g[8],10.39,true))
            assert(L.Appearance(g[8],10.72,true))
            assert(not L.Appearance(g[15],10.72,true))
            assert(L.Appearance(g[15],11.05,true))
            local shown,a,s,y=L.Appearance(g[4],10.36,true)
            for i=1,20 do
                local shown2,a2,s2,y2=L.Appearance(g[4],10.36,true)
                assert(shown==shown2 and a==a2 and s==s2 and y==y2)
            end
            assert(not L.Appearance(g[4],10.1,true))
            shown,a,s,y=L.Appearance(g[4],10.36,true,10.36)
            assert(shown and a==1 and s==1 and y==0)
            assert(not L.Appearance(g[8],10.36,true,10.36))
            assert(not L.Appearance(g[4],10.06,false))
            assert(L.Appearance(g[4],11,false))
            local chars=L.Glyphs({text='中文日本'..string.char(10)..'继续',start=0,['end']=3},'line',true)
            assert(#chars==6 and chars[5].row==1)
            assert(chars[1].popStart==chars[2].popStart)
            assert(chars[3].popStart>chars[2].popStart)
            assert(chars[5].popStart>chars[4].popStart)
            assert(chars[5].text=='继' and chars[6].text=='续')
        ''')

    def test_widget_world_anchor_seek_cleanup_and_missing_art(self):
        self.lua.execute('''
            unpack = unpack or table.unpack
            math.atan2 = math.atan2 or math.atan
            function Class(base, ctor)
                if ctor == nil then ctor, base = base, nil end
                local c = {_ctor=ctor, _base=base}; c.__index=c
                return setmetatable(c, {__index=base, __call=function(_, ...)
                    local x=setmetatable({},c); ctor(x,...); return x
                end})
            end
            CREATED=0; WIDGETS={}
            local W=Class(function(self)
                self.children={}; self.shown=true; self.inst={IsValid=function() return not self.dead end}; CREATED=CREATED+1
                WIDGETS[#WIDGETS+1]=self
            end)
            function W:AddChild(c) self.children[#self.children+1]=c; c.parent=self; return c end
            function W:SetPosition(x,y) self.x,self.y=x,y end
            function W:SetScale(x,y) self.scale=x end
            function W:SetScaleMode(mode) self.scaleMode=mode end
            function W:SetFont(font) self.font=font end
            function W:ResetRegionSize() end
            function W:GetRegionSize()
                local width=0
                for _,char in ipairs(require('widgets/music_lyriclogic').Characters(self.string)) do
                    width=width+(#char>1 and 28 or (char==' ' and 7 or (char=='i' and 5 or 14)))
                end
                return width,30
            end
            function W:SetRotation(x) self.rotation=x end
            function W:Show() self.shown=true end
            function W:Hide() self.shown=false end
            function W:Kill()
                self.dead=true
                for _,child in ipairs(self.children) do if not child.dead then child:Kill() end end
            end
            function W:SetString(x) self.string=x end
            function W:SetTexture(a,b) self.atlas,self.image=a,b end
            for _,n in ipairs({'SetClickable','SetMaxPropUpscale',
                'StartUpdating','SetColour','SetRegionSize','SetSize',
                'SetHAnchor','SetVAnchor','ScaleToSize'}) do W[n]=function() end end
            function W:SetTint(r,g,b,a) self.tint={r,g,b,a} end
            function W:SetBlendMode(mode) self.blend=mode end
            function W:ScaleToSize(w,h) self.width,self.height=w,h end
            function W:SetTruncatedString(s) self.string=s end
            COUNTS={}
            for _,name in ipairs({'SetPosition','SetScale','SetRotation','Show','Hide',
                'SetString','SetTruncatedString','SetTexture','SetTint','SetColour','ScaleToSize','GetRegionSize'}) do
                local original=W[name]
                W[name]=function(self,...)
                    COUNTS[name]=(COUNTS[name] or 0)+1
                    return original(self,...)
                end
            end
            package.preload['widgets/widget']=function() return W end
            local T=Class(W,function(self,font,size,text) W._ctor(self); self.string=text; self.font=font end)
            package.preload['widgets/text']=function() return T end
            package.preload['widgets/image']=function() return W end
            UIFONT='ui'; TALKINGFONT='talk'; CHATFONT='chat'; CODEFONT='mono'; DEFAULTFONT='sans'; MAX_HUD_SCALE=1.25
            SCALEMODE_NONE=0
            BLENDMODE={Additive=5}
            ANCHOR_TOP=1; ANCHOR_LEFT=2; ANCHOR_MIDDLE=3; SCALEMODE_PROPORTIONAL=1
            NOW=1.1; function GetStaticTime() return NOW end
            function resolvefilepath_soft(path) return not path:find('missing') and path or nil end
            function resolvefilepath(path) assert(resolvefilepath_soft(path)); return path end
            TheSim={GetScreenSize=function() return 1920,1080 end,
                GetScreenPos=function(_,x,y,z) return 960+x*24,540+z*16+y*24 end}
            TheCamera={GetDownVec=function() return {x=0,z=1} end,
                GetRightVec=function() return {x=1,z=0} end}
            TheWorld={state={isnight=false},HasTag=function() return false end}
            PX=0
            owner={IsValid=function() return true end,HasTag=function() return true end,
                Transform={GetWorldPosition=function() return PX,0,0 end}}
            local data={timing='word',lines={{start=1,['end']=5,text='你好',translation='hello',words={
                {start=1,['end']=2,text='你'},{start=2,['end']=5,text='好'}}}}}
            c={modroot='mod/',settings={lyrics={wordPop=true,glow=false},card={enabled=true},island={enabled=true}},
                state={player={track={id='347230',name='歌曲',artists='歌手甲 / 歌手乙',duration=10},playing=true,duration=10}},callbacks={},removed=0}
            function c:Subscribe(fn) self.callbacks[#self.callbacks+1]=fn; return function() self.removed=self.removed+1 end end
            function c:GetLyrics() return data end
            local glyphData=nil
            function c:GetLyricGlyphs() return glyphData end
            local taken={}; local denyLease=false
            c.leasesTaken,c.leasesReleased=0,0
            function c:TakeLyricGlyphLease(value)
                if denyLease or taken[value] then return nil end
                taken[value]=true; self.leasesTaken=self.leasesTaken+1
                local lease={released=false}
                function lease:Release()
                    assert(not self.released)
                    for _,widget in ipairs(WIDGETS) do
                        if widget.atlas=='mod/'..value.asset.atlas then
                            assert(widget.dead, 'atlas released before ImageWidget destruction')
                        end
                    end
                    self.released=true; c.leasesReleased=c.leasesReleased+1
                end
                return lease
            end
            function c:GetPosition() return NOW end
            function c:GetArtwork() return {atlas='missing.xml',image='missing.tex'} end
            lyric=require('widgets/music_lyrics')(c,owner)
            lyric:OnUpdate(.03)
            assert(lyric.shown and lyric.glyphs[1].shown and not lyric.glyphs[2].shown)
            assert(lyric.glyphs[1].core.font==CODEFONT)
            assert(not lyric.glowRoot.shown and lyric.glyphs[1].glowGroup==nil)
            local allocated=CREATED
            for i=1,20 do lyric:OnUpdate(.03) end
            assert(CREATED==allocated) -- disabled glow has no Image allocations
            c.settings.lyrics.glow=true; lyric:OnUpdate(.03)
            assert(CREATED==allocated and lyric.glyphs[1].core.shown) -- no assets: Text, never circles
            -- Assets arrive during a pop: only the rendering changes, with no
            -- anchor replacement, seek suppression, or animation phase reset.
            local ax0,az0=lyric.anchor.x,lyric.anchor.z
            local popScale=lyric.glyphs[1].scale
            local mask={core='ni-core',near='ni-near',far='ni-far',
                width=44,height=50,advance=22,offsetX=11,offsetY=9,
                layers={core={width=44,height=50,offsetX=11,offsetY=9,pixelScale=2},
                    near={width=60,height=66,offsetX=13,offsetY=12,pixelScale=1},
                    far={width=84,height=90,offsetX=10,offsetY=14,pixelScale=1}}}
            local mask2={core='hao-core',near='hao-near',far='hao-far',
                width=48,height=50,advance=24,offsetX=12,offsetY=9}
            glyphData={asset={atlas='images/music_cache/test.xml',image='test.tex'},fonts={
                mono={lineHeight=30,baseline=24,glyphs={['你']=mask,['好']=mask2}},
                smooth={lineHeight=30,baseline=24,glyphs={['你']=mask2,['好']=mask}}}}
            c.settings.lyrics.glow=false; lyric:OnUpdate(.03)
            local shaped=lyric.glyphs[1]
            assert(shaped.sprite and not shaped.core.shown and not shaped.shadow.shown)
            assert(shaped.spriteShadow and shaped.spriteShadow.shown)
            assert(shaped.spriteShadow.x==1.8 and shaped.spriteShadow.y==-1.8)
            assert(shaped.spriteShadow.tint[4]==.86)
            assert(shaped.glowGroup==nil) -- core images alone when glow disabled
            assert(shaped.sprite.image=='ni-core' and shaped.sprite.atlas=='mod/images/music_cache/test.xml')
            assert(lyric.layout[1].advance==22 and lyric.layout[2].advance==24)
            assert(shaped.sprite.x==0 and shaped.sprite.y==0) -- canvas baseline alignment
            assert(shaped.scale==popScale and lyric.anchor.x==ax0 and lyric.anchor.z==az0)
            assert(c.leasesTaken==1 and c.leasesReleased==0)
            c.settings.lyrics.glow=true; c.settings.lyrics.glowStrength=0
            allocated=CREATED; lyric:OnUpdate(.03)
            assert(CREATED==allocated and shaped.glowGroup==nil)
            c.settings.lyrics.glowStrength=.3; lyric:OnUpdate(.03)
            local near,far=shaped.glowNear,shaped.glowFar
            assert(near and far and shaped.glowGroup.shown)
            assert(near.blend==BLENDMODE.Additive and far.blend==BLENDMODE.Additive)
            assert(shaped.glowGroup.parent==lyric.glowRoot)
            assert(shaped.glowGroup.x==shaped.x and shaped.glowGroup.y==shaped.y)
            assert(shaped.glowGroup.scale==shaped.scale)
            assert(shaped.sprite.width==44 and shaped.sprite.height==50 and shaped.sprite.x==0 and shaped.sprite.y==0)
            assert(near.width==60 and near.height==66 and near.x==2 and near.y==3)
            assert(far.width==84 and far.height==90 and far.x==-1 and far.y==5)
            assert(near.tint[4]>.7 and far.tint[4]>.5) -- visible glow at default .3 strength
            c.settings.lyrics.textColor='#4080C0'; lyric:OnUpdate(.03)
            assert(math.abs(near.tint[1]-64/255)<.00001 and math.abs(near.tint[3]-192/255)<.00001)
            assert(shaped.sprite.tint[1]>near.tint[1] and shaped.sprite.tint[3]>near.tint[3])
            local narrowAlpha=far.tint[4]
            c.settings.lyrics.glowRadius=1; c.settings.lyrics.glowColor=2
            lyric:OnUpdate(.03)
            assert(far.tint[4]>narrowAlpha and near.tint[3]==1)
            assert(near.width==60 and far.width==84) -- radius never rescales masks
            c.settings.lyrics.glowStrength=0; lyric:OnUpdate(.03)
            assert(not lyric.glowRoot.shown and not shaped.glowGroup.shown)
            c.settings.lyrics.glowStrength=.3; c.settings.lyrics.glowNightOnly=true
            lyric:OnUpdate(.03); assert(not lyric.glowRoot.shown)
            TheWorld.state.isnight=true; lyric:OnUpdate(.03)
            assert(lyric.glowRoot.shown and shaped.glowGroup.shown)
            TheWorld.state.isnight=false; TheWorld.state.isdusk=true
            lyric:OnUpdate(.03); assert(lyric.glowRoot.shown)
            TheWorld.state.isdusk=false; c.settings.lyrics.glow=false
            allocated=CREATED
            for i=1,20 do lyric:OnUpdate(.03) end
            assert(CREATED==allocated and not shaped.glowGroup.shown)
            c.settings.lyrics.smoothFont=true; lyric:OnUpdate(.03)
            assert(lyric.glyphs[1].core.font==DEFAULTFONT)
            assert(shaped.sprite.image=='hao-core' and shaped.sprite.width==48)
            c.settings.lyrics.smoothFont=false; lyric:OnUpdate(.03)
            assert(shaped.sprite.image=='ni-core' and shaped.sprite.width==44)
            assert(CREATED==allocated) -- switching cached fonts never allocates new layers
            assert(c.leasesTaken==1 and c.leasesReleased==0) -- font/line share one current lease
            assert(lyric.scaleMode==SCALEMODE_NONE)
            assert(math.abs(lyric.root.scale-24/30)<0.00001) -- projected pixels used once
            local ax,az=lyric.anchor.x,lyric.anchor.z
            PX=2; c.callbacks[1](); lyric:OnUpdate(.03)
            assert(lyric.anchor.x==ax and lyric.anchor.z==az) -- status isn't reanchor
            NOW=2.1; c.settings.lyrics.glow=true; c.settings.lyrics.glowNightOnly=false
            lyric:OnUpdate(.03); assert(lyric.glyphs[2].shown and lyric.glyphs[2].glowGroup.shown)
            local beforeShort=data
            data={timing='line',lines={{start=1,['end']=5,text='你'}}}
            lyric:OnUpdate(.03)
            assert(not lyric.glyphs[2].shown and not lyric.glyphs[2].glowGroup.shown)
            data=beforeShort; lyric:OnUpdate(.03)
            assert(lyric.glyphs[2].shown and lyric.glyphs[2].glowGroup.shown)
            allocated=CREATED
            for i=1,20 do lyric:OnUpdate(.03) end
            assert(CREATED==allocated) -- bounded sprite pool, including both blur layers
            NOW=1.1; lyric:OnUpdate(.03)
            assert(not lyric.glyphs[2].shown and not lyric.glyphs[2].glowGroup.shown)
            c.settings.lyrics.glow=false; lyric:OnUpdate(.03)
            c.settings.lyrics.worldMode=false; lyric:OnUpdate(.03)
            assert(lyric.root.x==960 and lyric.root.y==1080*.23)
            c.settings.lyrics.worldMode=true; c.settings.lyrics.keepAway=true
            PX=lyric.anchor.x; local ownerZ=lyric.anchor.z+1
            owner.Transform.GetWorldPosition=function() return PX,0,ownerZ end
            local z=lyric.anchor.z; lyric:OnUpdate(.03); assert(lyric.anchor.z<z)
            local count=#lyric.glyphs
            for i=1,100 do lyric:OnUpdate(.03) end
            assert(#lyric.glyphs==count)
            NOW=8; lyric:OnUpdate(.03); assert(not lyric.root.shown)
            NOW=1.1; lyric:OnUpdate(.03); assert(lyric.root.shown)
            -- Exercise the real widget with ordinary LRC: it must not show a
            -- whole English line at its first timestamp. Small playback steps
            -- distinguish normal entrances from seek/late-load suppression.
            local source=data
            data={timing='line',lines={
                {start=1,['end']=5,text='We see bright light'},
                {start=5,['end']=8,text='新的'..string.char(10)..'歌词'}}}
            NOW=1.06; lyric:OnUpdate(.03)
            assert(lyric.glyphs[1].shown and not lyric.glyphs[4].shown)
            NOW=1.2; lyric:OnUpdate(.03); assert(not lyric.glyphs[4].shown)
            NOW=1.39; lyric:OnUpdate(.03)
            assert(lyric.glyphs[4].shown and not lyric.glyphs[8].shown)
            local scale=lyric.glyphs[4].scale
            c.state.player.playing=false
            for i=1,20 do lyric:OnUpdate(.03) end
            assert(lyric.glyphs[4].scale==scale and not lyric.glyphs[8].shown)
            c.state.player.playing=true
            NOW=1.72; lyric:OnUpdate(.03)
            assert(lyric.glyphs[8].shown and not lyric.glyphs[15].shown)
            NOW=2.05; lyric:OnUpdate(.03); assert(lyric.glyphs[15].shown)
            NOW=1.06; lyric:OnUpdate(.03)
            assert(not lyric.glyphs[4].shown and lyric.glyphs[1].scale==1)
            NOW=5.06; lyric:OnUpdate(.03)
            assert(lyric.glyphs[1].core.string=='新' and lyric.glyphs[2].shown)
            assert(not lyric.glyphs[3].shown and not lyric.glyphs[5].shown)
            NOW=5.4; lyric:OnUpdate(.03)
            assert(lyric.glyphs[3].shown and lyric.layout[3].row==1)
            data=source; NOW=1.1; lyric:OnUpdate(.03)
            local cachedFonts=glyphData.fonts
            local oldSprite,oldShadow,oldNear,oldFar=shaped.sprite,shaped.spriteShadow,shaped.glowNear,shaped.glowFar
            glyphData=nil; lyric:OnUpdate(.03)
            assert(lyric.glyphs[1].core.shown and lyric.glyphs[1].sprite==nil)
            assert(lyric.glyphs[1].glowGroup==nil and lyric.glyphs[1].glowNear==nil)
            assert(oldSprite.dead and oldShadow.dead and oldNear.dead and oldFar.dead)
            assert(c.leasesTaken==c.leasesReleased)
            -- Repeated atlas replacements release each previous resource only
            -- after core and both blur ImageWidgets have been destroyed.
            c.settings.lyrics.glow=true
            for n=1,3 do
                glyphData={asset={atlas='images/music_cache/lifecycle'..n..'.xml'},fonts=cachedFonts}
                lyric:OnUpdate(.03)
                assert(shaped.sprite and shaped.glowGroup)
                assert(c.leasesTaken-c.leasesReleased==1)
            end
            -- Losing the track must clean up before the first early return.
            local track=c.state.player.track
            c.state.player.track=nil; lyric:OnUpdate(.03)
            assert(shaped.sprite==nil and shaped.glowGroup==nil)
            assert(c.leasesTaken==c.leasesReleased)
            c.state.player.track=track
            glyphData={asset={atlas='images/music_cache/nolyrics.xml'},fonts=cachedFonts}
            lyric:OnUpdate(.03)
            local previousData=data; data={lines={}}; lyric:OnUpdate(.03)
            assert(shaped.sprite==nil and c.leasesTaken==c.leasesReleased)
            data=previousData
            glyphData={asset={atlas='images/music_cache/denied.xml'},fonts=cachedFonts}
            denyLease=true; lyric:OnUpdate(.03)
            assert(shaped.sprite==nil and shaped.core.shown)
            assert(c.leasesTaken==c.leasesReleased) -- metadata never bypasses ownership
            denyLease=false
            glyphData={asset={atlas='images/music_cache/kill.xml'},fonts=cachedFonts}
            lyric:OnUpdate(.03)
            assert(c.leasesTaken-c.leasesReleased==1)
            local card=require('widgets/music_songcard')(c,owner)
            local island=require('widgets/music_island')(c,owner)
            assert(card.shown and island.shown) -- ghost is allowed
            local U=require('widgets/music_hudutil')
            assert(U.Artist(c.state.player.track)=='歌手甲 / 歌手乙')
            assert(card.artist.string=='歌手甲 / 歌手乙')
            assert(island.status.string:find('歌手甲 / 歌手乙',1,true))
            assert(U.Artist({artist='legacy artist'})=='legacy artist')
            assert(U.Artist({artists={{name='甲'},'乙'}})=='甲 / 乙')
            assert(U.Artist({artists={}})=='' and U.Artist({})=='')
            assert(U.Artist({artists=23})=='' and U.Artist(nil)=='')
            assert(card.cover.image=='card.tex') -- missing artwork safely falls back
            assert(card.cover.tint[1]<.4 and card.cover.tint[3]<.4)
            assert(card.title.font==CHATFONT and island.label.font==CHATFONT)
            c.settings.lyrics.nowPlaying=false; card:OnUpdate(.03); lyric:OnUpdate(.03)
            assert(card.shown and not lyric.classic.shown) -- independent settings
            c.settings.card.enabled=false; c.settings.lyrics.nowPlaying=true
            c.settings.lyrics.enabled=false; NOW=8 -- no active lyric
            card:OnUpdate(.03); lyric:OnUpdate(.03)
            assert(not card.shown and lyric.classic.shown and not lyric.root.shown)
            assert(lyric.classic.artist.string=='歌手甲 / 歌手乙')
            assert(lyric.classic.title.font==CHATFONT)
            c.settings.lyrics.showCover=false; lyric:OnUpdate(.03)
            assert(not lyric.classic.cover.shown)
            c.settings.card.enabled=true; c.settings.lyrics.nowPlaying=false
            c.settings.card.showPaused=false; c.state.player.playing=false; card:OnUpdate(.03)
            assert(not card.shown)
            c.settings.card.showPaused=true; card:OnUpdate(.03); assert(card.shown)
            -- Stable, fully revealed 96-glyph line with masks and both glow layers.
            -- Count native-boundary calls after warmup, independently of game FPS.
            c.settings.lyrics={enabled=true,worldMode=false,nowPlaying=true,glow=true,
                wiggle=false,wordPop=true,textColor={.3,.4,.5},translation=true}
            c.state.player.playing=false; c.state.player.duration=100
            data={timing='line',lines={{start=1,['end']=100,text=string.rep('你',96),translation='translation'}}}
            NOW=40
            lyric:OnUpdate(.016); card:OnUpdate(.016); island:OnUpdate(.016)
            COUNTS={}
            for i=1,120 do
                lyric:OnUpdate(1/60); card:OnUpdate(1/60); island:OnUpdate(1/60)
            end
            BENCH_STABLE=COUNTS
            for name,count in pairs(COUNTS) do assert(count==0, name..' repeated on stable frame') end
            COUNTS={}
            -- In-place colour edits must invalidate colours even with the same table.
            local g=lyric.glyphs[1]
            c.settings.lyrics.textColor[1]=.7; lyric:OnUpdate(.016)
            assert(g.glowNear.tint[1]==.7 and g.sprite.tint[1]>.7)
            -- Projection must continue every frame even while audio is paused.
            c.settings.lyrics.worldMode=true
            local projection=TheSim.GetScreenPos
            TheSim.GetScreenPos=function(self,x,y,z) local sx,sy=projection(self,x,y,z); return sx+37,sy end
            local beforeX=lyric.root.x
            lyric:OnUpdate(.016); assert(lyric.root.x~=beforeX)
            -- Existing wiggle cadence remains 8Hz, native transforms only change
            -- at those ticks. Playback/progress continue to update at 60Hz.
            c.settings.lyrics.worldMode=false; c.settings.lyrics.wiggle=true
            c.state.player.playing=true
            lyric:OnUpdate(.016); card:OnUpdate(.016); island:OnUpdate(.016)
            COUNTS={}
            for i=1,120 do
                NOW=40+i/60
                lyric:OnUpdate(1/60); card:OnUpdate(1/60); island:OnUpdate(1/60)
            end
            BENCH_PLAYING=COUNTS
            assert((COUNTS.SetTruncatedString or 0)==0)
            assert((COUNTS.SetTexture or 0)==0 and (COUNTS.SetTint or 0)==0)
            assert((COUNTS.SetString or 0)<=3) -- clock only at integer seconds
            assert((COUNTS.SetPosition or 0)>0) -- wiggle/progress retain animation
            assert((COUNTS.SetPosition or 0)<120*96*2)
            -- Shared atlas has one independent lease for each HUD image.
            -- Releasing one consumer must leave the other two valid.
            local refs,acquired,released={},0,0
            function c:RequestArtwork(kind,id)
                return {atlas='covers/'..tostring(id)..'.xml',image='cover.tex'}
            end
            function c:AcquireArtwork(asset)
                local path='mod/'..asset.atlas
                refs[path]=(refs[path] or 0)+1;acquired=acquired+1
                local lease={released=false}
                function lease:Release()
                    assert(not self.released);self.released=true;released=released+1
                    refs[path]=refs[path]-1
                    if refs[path]==0 then
                        for _,widget in ipairs(WIDGETS) do
                            assert(widget.dead or widget.atlas~=path,'last lease released while an image still uses atlas')
                        end
                    end
                end
                return lease
            end
            c.settings.lyrics.nowPlaying=true;c.settings.lyrics.showCover=true
            c.settings.card.enabled=true;c.settings.island.enabled=true;c.state.player.playing=true
            local function changed(id)
                c.state.player.track={id=id,name='track '..id,artists='artist'}
                for _,fn in ipairs(c.callbacks) do fn() end
            end
            changed('A');lyric:OnUpdate(.016);card:OnUpdate(.016);island:OnUpdate(.016)
            assert(refs['mod/covers/A.xml']==3)
            for i=1,30 do
                local id=tostring(i);local old=(i==1 and 'A' or tostring(i-1))
                changed(id);card:OnUpdate(.016)
                assert(refs['mod/covers/'..old..'.xml']==2,'other HUDs must retain old atlas until they switch')
                lyric:OnUpdate(.016);island:OnUpdate(.016)
                assert(refs['mod/covers/'..old..'.xml']==0 and refs['mod/covers/'..id..'.xml']==3)
                assert(acquired-released==3,'live native leases stay bounded across tracks')
            end
            c.settings.card.enabled=false;card:OnUpdate(.016)
            assert(refs['mod/covers/30.xml']==2)
            c.settings.lyrics.showCover=false;lyric:OnUpdate(.016)
            assert(refs['mod/covers/30.xml']==1)
            c.settings.island.enabled=false;island:OnUpdate(.016)
            assert(refs['mod/covers/30.xml']==0 and acquired==released)
            c.settings.card.enabled=true;c.settings.lyrics.showCover=true;c.settings.island.enabled=true
            changed('kill');lyric:OnUpdate(.016);card:OnUpdate(.016);island:OnUpdate(.016)
            assert(refs['mod/covers/kill.xml']==3)
            lyric:Kill();assert(refs['mod/covers/kill.xml']==2)
            card:Kill();assert(refs['mod/covers/kill.xml']==1)
            island:Kill();assert(refs['mod/covers/kill.xml']==0 and acquired==released)
            assert(c.removed==3 and c.leasesTaken==c.leasesReleased)
        ''')


if __name__ == '__main__':
    unittest.main()
