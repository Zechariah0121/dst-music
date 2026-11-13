import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { resolve, dirname, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pipeline } from 'node:stream/promises';
import { createNetease, validateMediaUrl } from './netease.mjs';
import { createQq } from './qqmusic.mjs';
import {musicId,providerForId,musicProvider,providerLabel} from './music-source.mjs';
import {parseLyrics} from './lyrics.mjs';
import {createSettingsStore,SETTINGS_SCHEMA} from './settings.mjs';
import {createGameRequests} from './game-requests.mjs';
import {createModFolderOpener} from './local-actions.mjs';
import {createUpdateChecker,UPDATE_SOURCE} from './updates.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const NEUTRAL_ENVIRONMENT=Object.freeze({water:false,cave:false,indoor:false,rain:0,region:'surface'});
const REGION_SETTINGS=Object.freeze({cave:'envCave',lunar:'envLunar',ocean:'envOcean',ruins:'envRuins',atrium:'envAtrium',forest:'envForest'});
const UNDERGROUND_REGIONS=new Set(['cave','ruins','atrium']);
const GAME_SLOW_READS=new Set(['/api/discover','/api/search','/api/playlists','/api/playlist',
  '/api/lyrics','/api/lyric-glyphs','/api/artwork','/api/login/artwork','/api/login/check']);
const UPDATE_INTERVAL_MS=6*60*60*1000;
const fail = (message, status = 400) => Object.assign(new Error(message), { status });
const id = musicId;
function client(value) { if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{8,100}$/.test(value)) throw fail('播放器标识无效'); return value; }
function numeric(value, min, max) { if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) throw fail('数值超出有效范围'); return value; }
async function atomic(path, value) { const temp = path + '.tmp'; await writeFile(temp, JSON.stringify(value, null, 2), { mode: 0o600 }); await rename(temp, path); }
async function readCompanionVersion(modDir) {
  try {
    const data=await readFile(resolve(modDir,'music_workshop_identity.json'),'utf8');
    const marker=JSON.parse(data.replace(/^\uFEFF/,''));
    if(marker.schema===1 && marker.id==='zcc-dst-music')return marker.version;
  } catch { /* Keep audio available when update metadata is missing or invalid. */ }
}

export async function createBridge(options = {}) {
  const stateDir = resolve(options.stateDir || resolve(root, '.state'));
  const modDir = resolve(options.modDir || resolve(root, 'mod'));
  const publicDir = resolve(options.publicDir || resolve(root, 'helper/public'));
  const openModFolder=options.openModFolder || createModFolderOpener(options.runtimeModDir || modDir);
  const providers = {netease:options.upstream || createNetease(),qq:options.providers?.qq || createQq()};
  const now = options.now || Date.now;
  await mkdir(stateDir, { recursive: true });
  let saved;
  try { saved = JSON.parse(await readFile(resolve(stateDir, 'bridge.json'), 'utf8')); } catch (e) { if (e.code !== 'ENOENT') throw new Error('本机配置损坏，请检查 bridge.json'); }
  const token = options.token || saved?.token || randomBytes(32).toString('hex');
  if (!/^[a-zA-Z0-9_-]{24,128}$/.test(token)) throw new Error('本机 token 格式无效');
  const accounts = {};
  const accountFile = provider => resolve(stateDir, provider === 'netease' ? 'account.json' : 'account-qq.json');
  for (const provider of Object.keys(providers)) {
    try { const auth = JSON.parse(await readFile(accountFile(provider), 'utf8')); accounts[provider] = {cookie:auth.cookie || '',account:auth.account || null}; }
    catch (e) { if (e.code !== 'ENOENT') throw new Error('账号凭据文件损坏'); accounts[provider] = {cookie:'',account:null}; }
  }
  const settingsStore = await createSettingsStore(stateDir);
  let {settings,settingsRevision}=settingsStore.read();
  const updateInterval=options.updateIntervalMs ?? UPDATE_INTERVAL_MS;
  const updates=createUpdateChecker({
    currentVersion:options.currentVersion ?? await readCompanionVersion(modDir),
    fetchImpl:options.updateFetch,
    minIntervalMs:options.updateMinIntervalMs,
    ttlMs:updateInterval,
    now,
  });
  const updateResponse=state=>({ok:true,...state,source:UPDATE_SOURCE});
  let updateTimer,updateSchedule,updatesStopped=false;
  function setAutomaticUpdates(enabled) {
    clearTimeout(updateTimer);
    updateSchedule=undefined;
    if(!enabled || updatesStopped)return;
    const check=async()=>{
      const {checkedAt,error}=await updates.check();
      if(updateSchedule!==check)return;
      // A manual check can refresh the cache between scheduled checks.
      const delay=checkedAt===null || error ? updateInterval : Math.max(1,checkedAt+updateInterval-now());
      updateTimer=setTimeout(check,delay);
      updateTimer.unref();
    };
    updateSchedule=check;
    void check();
  }
  const selectedProvider = () => settings.player.musicSource === 1 ? 'qq' : 'netease';
  const sourceContext = value => {const provider=musicProvider(value ?? selectedProvider());return {provider,api:providers[provider],auth:accounts[provider]};};
  const trackContext = value => sourceContext(providerForId(value));
  const assertAccountUnchanged = ctx => {if(accounts[ctx.provider] !== ctx.auth)throw fail('账号已变化，请重新读取此来源',409);};
  const playlists = new Map(), media = new Map(), loginKeys = new Map(), knownTracks=new Map(), knownPlaylists=new Map(), lyricsCache=new Map(),searchQueues=new Map();
  let mediaSelection=0;
  const mediaStreams={netease:new Set(),qq:new Set()};
  const loginVersions={netease:0,qq:0};
  function cancelLogins(provider) {
    loginVersions[provider]++;
    for (const [key,entry] of loginKeys) if(entry.provider === provider) {providers[provider].cancelLogin?.(key);loginKeys.delete(key);}
    providers[provider].cancelLogin?.();
  }
  function clearSourceCaches(provider) {
    for(const controller of mediaStreams[provider])controller.abort();
    for (const cache of [playlists,media,knownTracks,knownPlaylists,lyricsCache,searchQueues]) {
      for (const key of cache.keys()) if(providerForId(key) === provider) cache.delete(key);
    }
  }
  let assetProvider=options.assets;
  async function gameAssets(){
    if(!assetProvider) {
      const {createGameAssets}=await import('./game-assets.mjs');
      assetProvider=createGameAssets({stateDir,modDir,runtimeModDir:options.runtimeModDir,ktechPath:options.ktechPath,pythonPath:options.pythonPath});
    }
    return assetProvider;
  }
  async function assetRequest(fn) { try{return await fn(await gameAssets());}catch{throw fail('游戏图片资源暂不可用，请检查包内运行库与Mod安装路径',502);} }
  let glyphProvider=options.glyphs;
  async function lyricGlyphs(characters) {
    try {
      if(!glyphProvider) {
        const {createLyricGlyphs}=await import('./lyric-glyphs.mjs');
        glyphProvider=createLyricGlyphs({stateDir,modDir,runtimeModDir:options.runtimeModDir,ktechPath:options.ktechPath,pythonPath:options.pythonPath,fontsPath:options.fontsPath});
      }
      return await glyphProvider.build(characters);
    } catch { throw fail('字形光效暂不可用，歌词仍可正常显示',502); }
  }
  async function loadLyrics(trackId) {
    if(!lyricsCache.has(trackId)) {
      const ctx=trackContext(trackId),track=knownTracks.get(trackId);
      const raw=await ctx.api.lyrics(trackId,ctx.auth.cookie,track);
      assertAccountUnchanged(ctx);
      lyricsCache.set(trackId,ctx.provider==='qq'?raw:parseLyrics(raw,track?.duration||0));
    }
    return lyricsCache.get(trackId);
  }
  function remember(items,cache,provider) {
    if(!Array.isArray(items) || items.some(item=>providerForId(item.id)!==provider))throw fail('音乐来源返回了无效的曲库资料',502);
    for(const item of items)cache.set(String(item.id),item);
    return items;
  }
  const rememberTracks=(tracks,provider)=>remember(tracks,knownTracks,provider);
  const rememberPlaylists=(lists,provider)=>remember(lists,knownPlaylists,provider);
  let revision = 0, queueRevision = 0, queue = [], index = -1, owner = null, lastSeen = 0, endedRevision = -1;
  let gameRunning = null;
  let player = { track: null, playing: false, position: 0, duration: 0, volume: settings.player.volume, error: null };
  let playerUpdatedAt=now(),mediaFailure=null,nativeFailureSeekRevision=null;
  let environment=NEUTRAL_ENVIRONMENT,environmentAt=-Infinity,environmentTimer;
  let audioRevision=0,transportRevision=0,pendingSelections=0,playIntent=false;
  const audioWaiters=new Set();
  const touchAudio=()=>{audioRevision++;for(const wake of [...audioWaiters])wake();};
  let desired = { track: null, playing: false, position: 0, volume: settings.player.volume, mediaUrl: null, seekRevision: 0 };
  const mode=()=>settings.player.shuffle?'shuffle':settings.player.repeatOne?'single':'loop';
  const connected = () => !!owner && now() - lastSeen < 10000;
  const verifyOwner = value => { if (!connected() || client(value) !== owner) throw fail('播放器已断开，请重新连接本机播放器', 409); };
  function sampledPosition(at=now()) {
    const position=player.position+(player.playing&&connected()&&!player.error?Math.max(0,at-playerUpdatedAt)/1000:0);
    const duration=player.duration||player.track?.duration||0;
    return duration>0?Math.min(position,duration):position;
  }
  function desiredForPlayer() {
    const entry=desired.track&&media.get(desired.track.id);
    let factor=settings.player.normalize&&entry?Math.max(.25,Math.min(2,Math.pow(10,(Number(entry.gainDb)||0)/20))):1;
    if(settings.player.normalize&&entry?.peak>0)factor=Math.min(factor,.98/entry.peak);
    const env=now()-environmentAt<5000?environment:NEUTRAL_ENVIRONMENT;
    // Specific underground profiles fall back to the ordinary cave profile
    // when switched off. Rain is independent of every regional switch.
    let region=env.region;
    if(region!=='surface'&&!settings.player[REGION_SETTINGS[region]])region=env.cave&&settings.player.envCave?'cave':'surface';
    // The native DSP consumes logical baseVolume + source gain once. volume is
    // the clamped compatibility fallback for older/browser players.
    return{...desired,revision,volume:Math.max(0,Math.min(1,desired.volume*factor)),audio:{baseVolume:desired.volume,normalize:settings.player.normalize,gainDb:Number(entry?.gainDb)||0,peak:Number(entry?.peak)||0,env:{enabled:settings.player.envAudio,water:settings.player.envWater&&env.water,cave:settings.player.envCave&&env.cave,indoor:settings.player.envIndoor&&env.indoor,rain:settings.player.envRain?env.rain:0,region,strength:settings.player.envStrength}}};
  }
  let tail = Promise.resolve();
  function serial(fn) { const task = tail.then(fn); tail = task.catch(() => {}); return task; }
  const bump = (preservePosition=false) => {
    revision++;
    touchAudio();
    if(preservePosition) {player={...player,volume:desired.volume};return;}
    player={...player,track:desired.track,playing:desired.playing,position:desired.position,volume:desired.volume,error:null};playerUpdatedAt=now();
  };
  let settingsTail=Promise.resolve();
  function updateSettings(patch) {
    // Disk writes stay ordered without waiting for playlist/song URL requests.
    const task=settingsTail.then(async()=>{
      const previous=settings;
      ({settings,settingsRevision}=await settingsStore.patch(patch));
      if(previous.player.checkUpdates!==settings.player.checkUpdates)setAutomaticUpdates(settings.player.checkUpdates);
      if(previous.player.volume!==settings.player.volume||previous.player.normalize!==settings.player.normalize) {desired.volume=settings.player.volume;bump(true);}
      else if(Object.keys(settings.player).some(key=>key.startsWith('env')&&previous.player[key]!==settings.player[key]))touchAudio();
      return{settings,settingsRevision};
    });
    settingsTail=task.catch(()=>{});return task;
  }
  async function loadPlaylist(value) {
    const key = id(value);
    const ctx=trackContext(key);
    if ((ctx.provider==='netease'||key.startsWith('qq:liked:'))&&(!ctx.auth.cookie||!ctx.auth.account))throw fail(`请先扫码登录${providerLabel(ctx.provider)}账号`,401);
    if (!playlists.has(key)) {
      const tracks=await ctx.api.playlist(key,ctx.auth.cookie);assertAccountUnchanged(ctx);
      playlists.set(key,rememberTracks(tracks,ctx.provider));
    }
    return playlists.get(key);
  }
  async function choose(newQueue, newIndex, intentRevision=transportRevision) {
    const requestedOwner = owner;
    const track = newQueue[newIndex];
    if (!track) throw fail('歌单中没有可播放的歌曲');
    const ctx=trackContext(track.id);
    const result = await ctx.api.songUrl(track.id,ctx.auth.cookie,track);
    assertAccountUnchanged(ctx);
    (ctx.api.validateMediaUrl || validateMediaUrl)(result.url);
    if (!connected() || owner !== requestedOwner) throw fail('播放器已断开，请在浏览器重新连接', 409);
    media.set(track.id, {...result,selection:++mediaSelection});
    if (queue !== newQueue) queueRevision++;
    queue = newQueue; index = newIndex;
    // A pause received while songUrl was pending must survive its completion.
    desired = { ...desired, track: { ...track, trial: !!result.trial }, playing: intentRevision===transportRevision?true:playIntent, position: 0, mediaUrl: `/api/media?trackId=${encodeURIComponent(track.id)}&token=${encodeURIComponent(token)}`, seekRevision: desired.seekRevision + 1 };
    player.duration = track.duration; bump();
  }
  const move = async (delta,ended=false,intentRevision=transportRevision) => {
    if (!queue.length) throw fail('请先选择歌曲');
    const next=ended&&mode()==='single'?index:mode()==='shuffle'&&queue.length>1?(index+1+Math.floor((options.random?.() ?? Math.random())*(queue.length-1)))%queue.length:(index+delta+queue.length)%queue.length;
    await choose(queue,next,intentRevision);
  };
  async function body(req, allowEmptyArray = false) {
    let bytes = 0; const chunks = [];
    for await (const chunk of req) { bytes += chunk.length; if (bytes > 16384) throw fail('请求内容过大', 413); chunks.push(chunk); }
    try {
      const result = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      // Older DST bridges encode an empty Lua table as []. Only these bodyless
      // account actions accept that one legacy representation.
      if(allowEmptyArray && Array.isArray(result) && result.length===0)return{};
      if (!result || Array.isArray(result) || typeof result !== 'object') throw 0;
      return result;
    } catch { throw fail('请求 JSON 格式无效'); }
  }
  function sendJson(res, data, status = 200) {
    if(res.destroyed || res.writableEnded)return;
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
    res.end(JSON.stringify(data));
  }
  const gameRequests=createGameRequests({send:sendJson});
  function json(res, data, status = 200) {
    if(!gameRequests.complete(res,data,status))sendJson(res,data,status);
  }
  const server = http.createServer(async (req, res) => {
    try {
      const port = server.address()?.port;
      const host = req.headers.host;
      if (host !== `127.0.0.1:${port}`) throw fail('仅允许本机固定地址访问', 403);
      if (req.headers.origin && req.headers.origin !== `http://127.0.0.1:${port}`) throw fail('拒绝外站请求', 403);
      const url = new URL(req.url, `http://${host}`);
      if (url.pathname.startsWith('/api/') && req.headers['sec-fetch-site'] === 'cross-site') throw fail('拒绝外站请求', 403);
      if (url.pathname === '/health' && req.method === 'GET') return json(res, { ok: true, name: 'dst-music-bridge' });
      if (url.pathname.startsWith('/api/')) {
        const presented = req.headers.authorization?.replace(/^Bearer /, '') || url.searchParams.get('token') || '';
        const a = Buffer.from(presented), b = Buffer.from(token);
        if (a.length !== b.length || !timingSafeEqual(a,b)) throw fail('本机访问凭据无效，请通过启动器打开', 401);
        const q = url.searchParams;
        if(req.method==='GET' && url.pathname==='/api/request/result')return json(res,gameRequests.poll(q.get('id')));
        // QueryServer's native low-speed timeout can precede Lua's timer. Give
        // the game a short receipt, then deliver the result with short polls.
        // Native/browser callers retain the original HTTP response contract.
        if(req.method==='GET' && q.get('gameAsync')==='1' && GAME_SLOW_READS.has(url.pathname))gameRequests.begin(res);
        if (req.method === 'GET' && url.pathname === '/api/status') {const sampledAt=now(),ctx=sourceContext(q.get('provider'));return json(res, { ok:true,provider:ctx.provider,account:ctx.auth.account, playerConnected:connected(),playerEngine:connected()?(owner.startsWith('native_')?'native':'browser'):null, player:{...player,position:sampledPosition(sampledAt), playing:connected() && player.playing}, revision,mode:mode(),settingsRevision,sampledAt });}
        if (req.method === 'GET' && url.pathname === '/api/player/state') {
          const requestedOwner=q.get('clientId');verifyOwner(requestedOwner);
          const after=q.has('after')?Number(q.get('after')):null,wait=Number(q.get('wait')||0);
          if((after!==null&&(!Number.isSafeInteger(after)||after<0))||!Number.isInteger(wait)||wait<0||wait>8000)throw fail('播放器等待参数无效');
          if(after===audioRevision&&wait>0) {
            if(audioWaiters.size>=8)throw fail('播放器等待请求过多',429);
            await new Promise(resolve=>{
              const finish=()=>{clearTimeout(timer);audioWaiters.delete(finish);res.off('close',finish);resolve();};
              const timer=setTimeout(finish,wait);timer.unref();
              audioWaiters.add(finish);res.once('close',finish);
            });
          }
          if(res.destroyed)return;
          verifyOwner(requestedOwner);
          return json(res, { ok:true,audioRevision,desired:desiredForPlayer() });
        }
        if (req.method === 'GET' && url.pathname === '/api/settings') return json(res,{ok:true,settings,settingsRevision,schema:SETTINGS_SCHEMA});
        if (req.method === 'GET' && url.pathname === '/api/updates') return json(res,updateResponse(updates.read()));
        if (req.method === 'GET' && url.pathname === '/api/lyrics') {
          const trackId=id(q.get('trackId'));
          return json(res,{ok:true,trackId,...await loadLyrics(trackId)});
        }
        if (req.method === 'GET' && url.pathname === '/api/lyric-glyphs') {
          const trackId=id(q.get('trackId')), lyrics=await loadLyrics(trackId);
          // Only unique glyphs cross into the local compiler; it never receives
          // account credentials or the original timed lyric document.
          const characters=[...new Set(lyrics.lines.flatMap(line=>[...line.text]))].sort().join('');
          const result=characters?await lyricGlyphs(characters):{fonts:{},missing:[]};
          return json(res,{ok:true,trackId,...result});
        }
        if(req.method==='GET'&&url.pathname==='/api/artwork') {
          const isPlaylist=q.has('playlistId'), key=id(q.get(isPlaylist?'playlistId':'trackId'));
          const cover=(isPlaylist?knownPlaylists:knownTracks).get(key)?.cover;
          if(!cover)throw fail('此项目没有可用封面，请先读取歌单或搜索结果',404);
          return json(res,{ok:true,asset:await assetRequest(assets=>assets.cover(key,cover))});
        }
        if(req.method==='GET'&&url.pathname==='/api/login/artwork') {
          const key=q.get('key'),entry=loginKeys.get(key);
          if(!entry||now()-entry.createdAt>180000)throw fail('二维码已过期，请重新生成');
          return json(res,{ok:true,asset:await assetRequest(assets=>entry.image?assets.qrImage(key,entry.image):assets.qr(key,entry.url))});
        }
        if(req.method==='GET'&&url.pathname==='/api/login/image') {
          const entry=loginKeys.get(q.get('key'));
          if(!entry?.image||now()-entry.createdAt>180000)throw fail('二维码已过期，请重新生成',404);
          res.writeHead(200,{'Content-Type':'image/png','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'});res.end(entry.image);return;
        }
        if(req.method==='GET'&&url.pathname==='/api/discover') {
          const section=q.get('section');if(!['recommend','charts'].includes(section))throw fail('推荐分类无效');
          const ctx=sourceContext(q.get('provider')),lists=await ctx.api.discover(section,ctx.auth.cookie);assertAccountUnchanged(ctx);
          return json(res,{ok:true,provider:ctx.provider,playlists:rememberPlaylists(lists,ctx.provider)});
        }
        if(req.method==='GET'&&url.pathname==='/api/search') {
          const query=(q.get('q')||'').trim(),offset=Number(q.get('offset')||0),limit=Number(q.get('limit')||50);
          if(!query||query.length>200||!Number.isSafeInteger(offset)||offset<0||offset>10000||!Number.isInteger(limit)||limit<1||limit>100)throw fail('搜索内容或分页参数无效');
          const ctx=sourceContext(q.get('provider')),result=await ctx.api.search(query,offset,limit,ctx.auth.cookie);assertAccountUnchanged(ctx);
          rememberTracks(result.tracks,ctx.provider);for(const track of result.tracks)searchQueues.set(track.id,result.tracks);
          return json(res,{ok:true,provider:ctx.provider,...result,offset});
        }
        if (req.method === 'GET' && url.pathname === '/api/playlists') {
          const ctx=sourceContext(q.get('provider'));
          if (!ctx.auth.cookie || !ctx.auth.account) throw fail(`请先扫码登录${providerLabel(ctx.provider)}账号`,401);
          const lists=await ctx.api.playlists(ctx.auth.cookie,ctx.auth.account);assertAccountUnchanged(ctx);
          return json(res, { ok:true,provider:ctx.provider,playlists:rememberPlaylists(lists,ctx.provider) });
        }
        if (req.method === 'GET' && url.pathname === '/api/playlist') {
          const offset = Number(q.get('offset') || 0), limit = Number(q.get('limit') || 50);
          if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isInteger(limit) || limit < 1 || limit > 100) throw fail('分页参数无效（每页最多 100 首）');
          const tracks = await serial(() => loadPlaylist(q.get('id')));
          return json(res, { ok:true, tracks:tracks.slice(offset,offset+limit), total:tracks.length, offset });
        }
        if (req.method === 'GET' && url.pathname === '/api/queue') {
          const offset = Number(q.get('offset') || 0), limit = Number(q.get('limit') || 100);
          if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isInteger(limit) || limit < 1 || limit > 100) throw fail('分页参数无效（每页最多 100 首）');
          const snapshot = {
            tracks:queue.slice(offset,offset+limit).map(({id,name,artists,duration,cover})=>({id,name,artists,duration,...(cover?{cover}:{})})),
            total:queue.length,offset,hasMore:offset+limit<queue.length,
            currentIndex:index,currentTrackId:queue[index]?.id ?? null,queueRevision,
          };
          return json(res,{ok:true,...snapshot});
        }
        if (req.method === 'GET' && url.pathname === '/api/login/check') {
          const key = q.get('key');
          const result = await serial(async () => {
            if (!loginKeys.has(key) || now() - loginKeys.get(key).createdAt > 180000) throw fail('二维码已过期，请重新生成');
            const entry=loginKeys.get(key),ctx=sourceContext(entry.provider);
            const checked = await ctx.api.checkLogin(key);
            if(loginKeys.get(key)!==entry)throw fail('扫码会话已取消，请重新生成二维码',409);
            if (checked.status === 'success') {
              const nextAccount = checked.account || await ctx.api.account(checked.cookie);
              if(loginKeys.get(key)!==entry)throw fail('扫码会话已取消，请重新生成二维码',409);
              // Once a verified login begins its local commit, cancellation
              // waits for that short commit. It never acknowledges cancellation
              // and then lets a late upstream result install credentials.
              entry.commitPromise=(async()=>{
                await atomic(accountFile(ctx.provider), { cookie:checked.cookie, account:nextAccount });
                accounts[ctx.provider]={cookie:checked.cookie,account:nextAccount};
              })();
              await entry.commitPromise;
              cancelLogins(ctx.provider);
              // A new account invalidates entitlement/metadata caches for this source only.
              clearSourceCaches(ctx.provider);
              if(desired.track&&providerForId(desired.track.id)===ctx.provider) {
                if(queue.length)queueRevision++;queue=[];index=-1;playIntent=false;transportRevision++;
                desired={...desired,track:null,mediaUrl:null,playing:false,position:0};bump();
              }
              return { status:checked.status,provider:ctx.provider,account:nextAccount };
            }
            if (['expired','failed','canceled'].includes(checked.status)) {
              ctx.api.cancelLogin?.(key);loginKeys.delete(key);
              if(checked.status!=='expired')return {status:checked.status,provider:ctx.provider,message:checked.error||'扫码未完成，请重新生成二维码'};
            }
            return { status:checked.status,provider:ctx.provider };
          });
          return json(res, { ok:true, ...result });
        }
        if (req.method === 'GET' && url.pathname === '/api/media') {
          const trackId = id(q.get('trackId'));
          const ctx=trackContext(trackId);
          const mediaRevision=revision;
          let streamAbort;
          try {
          let entry = media.get(trackId);
          if (!entry) throw fail('音频链接已过期，请重新选择此曲', 410);
          if (entry.expires < now()) {
            const refreshed = await ctx.api.songUrl(trackId,ctx.auth.cookie,knownTracks.get(trackId));
            assertAccountUnchanged(ctx);
            (ctx.api.validateMediaUrl || validateMediaUrl)(refreshed.url);
            const current=media.get(trackId);
            if(!current||current.selection!==entry.selection)throw fail('歌曲选择已变化，请重试当前播放',410);
            // A fresh entitlement must not silently change full playback into a trial.
            if (!!refreshed.trial !== !!entry.trial) throw fail('歌曲播放权限已变化，请重新选择此曲',410);
            if(current===entry) {entry={...refreshed,selection:entry.selection};media.set(trackId,entry);}
            else entry=current; // Another request renewed the same selection.
          }
          const range = req.headers.range;
          if (range && !/^bytes=(?:\d+-\d*|-\d+)$/.test(range)) throw fail('仅支持单段音频范围', 416);
          const abort = new AbortController();
          streamAbort=abort;mediaStreams[ctx.provider].add(abort);
          res.on('close', () => abort.abort());
          const source = await ctx.api.openMedia(entry.url, range, abort.signal);
          if(accounts[ctx.provider]!==ctx.auth||media.get(trackId)?.selection!==entry.selection) {source.destroy();throw fail('音频会话已变化，请重新选择歌曲',410);}
          if (![200,206,416].includes(source.statusCode)) { source.destroy(); throw fail('音频上游暂时不可用', 502); }
          const headers = { 'Cache-Control':'no-store', 'Referrer-Policy':'no-referrer', 'X-Content-Type-Options':'nosniff' };
          for (const h of ['content-type','content-length','content-range','accept-ranges']) if (source.headers[h]) headers[h] = source.headers[h];
          if (source.statusCode !== 416 && headers['content-type'] && !/^(audio\/|application\/octet-stream)/i.test(headers['content-type'])) { source.destroy(); throw fail('上游未返回音频内容', 502); }
          res.writeHead(source.statusCode, headers);
          await pipeline(source, res, {signal:abort.signal});
          if(mediaFailure?.revision===mediaRevision&&mediaFailure.trackId===trackId)mediaFailure=null;
          return;
          } catch(error) {
            if(desired.track?.id===trackId&&revision===mediaRevision)mediaFailure={trackId,revision:mediaRevision,message:error.status?error.message:'音频下载中断，请检查网络后重试'};
            throw error;
          } finally {if(streamAbort)mediaStreams[ctx.provider].delete(streamAbort);}
        }
        if (req.method === 'POST') {
          const data = await body(req,['/api/login/start','/api/logout'].includes(url.pathname));
          if(url.pathname==='/api/open-mod-folder' || url.pathname==='/api/local/open-mod-folder') {
            if(Object.keys(data).length)throw fail('打开模组目录不接受路径参数');
            return json(res,{ok:true,...await openModFolder()});
          }
          if(url.pathname==='/api/request/cancel') {
            if(typeof data.requestId!=='string' || !/^[a-f0-9]{32}$/.test(data.requestId))throw fail('请求标识无效');
            gameRequests.cancel(data.requestId);
            return json(res,{ok:true});
          }
          if(q.get('gameAsync')==='1' && (url.pathname==='/api/login/start' || url.pathname==='/api/updates/check' ||
              url.pathname==='/api/control' && ['play','next','previous'].includes(data.action))) {
            gameRequests.begin(res,{onDiscard:url.pathname==='/api/login/start' ? result=>{
              const entry=loginKeys.get(result?.key);
              if(entry){providers[entry.provider].cancelLogin?.(result.key);loginKeys.delete(result.key);}
            } : undefined});
          }
          if(url.pathname==='/api/updates/check') {
            if(Object.keys(data).length)throw fail('检查更新不接受参数');
            return json(res,updateResponse(await updates.check({force:true})));
          }
          if(url.pathname==='/api/login/start') {
            // QR setup has its own bounded network handshake; it must not
            // queue behind a slow song URL or block audio controls.
            res.setTimeout(50000);
            const ctx=sourceContext(data.provider);cancelLogins(ctx.provider);
            const version=loginVersions[ctx.provider],result=await ctx.api.startLogin();
            if(version!==loginVersions[ctx.provider]) {ctx.api.cancelLogin?.(result.key);throw fail('扫码会话已更新，请重新打开登录',409);}
            loginKeys.set(result.key,{createdAt:now(),provider:ctx.provider,url:result.url,image:result.image});
            return json(res,{ok:true,key:result.key,provider:ctx.provider,...(result.url?{url:result.url}:{})});
          }
          if(url.pathname==='/api/login/cancel') {
            if(typeof data.key!=='string'||!data.key||data.key.length>512)throw fail('二维码标识无效');
            const entry=loginKeys.get(data.key);
            if(entry) {
              if(data.provider&&musicProvider(data.provider)!==entry.provider)throw fail('二维码音乐来源不匹配');
              if(entry.commitPromise)await entry.commitPromise.catch(()=>{});
              providers[entry.provider].cancelLogin?.(data.key);loginKeys.delete(data.key);
            }
            return json(res,{ok:true});
          }
          if(url.pathname==='/api/environment') {
            const keys=Object.keys(data);
            if((keys.length!==4&&keys.length!==5)||keys.some(key=>!['water','cave','indoor','rain','region'].includes(key))||typeof data.water!=='boolean'||typeof data.cave!=='boolean'||typeof data.indoor!=='boolean')throw fail('环境遥测必须完整提供 water、cave、indoor 布尔值和 rain 数值，可附带 region');
            numeric(data.rain,0,1);
            // Keep the four-field 0.3 client working during a staged update.
            const region=Object.hasOwn(data,'region')?data.region:(data.cave?'cave':'surface');
            if(typeof region!=='string'||(region!=='surface'&&!Object.hasOwn(REGION_SETTINGS,region))||UNDERGROUND_REGIONS.has(region)!==data.cave)throw fail('环境区域无效或与洞穴状态不一致');
            const previous=now()-environmentAt<5000?environment:NEUTRAL_ENVIRONMENT;
            environment={water:data.water,cave:data.cave,indoor:data.indoor,rain:data.rain,region};environmentAt=now();
            clearTimeout(environmentTimer);
            environmentTimer=setTimeout(()=>{environment=NEUTRAL_ENVIRONMENT;environmentAt=-Infinity;touchAudio();},5000);environmentTimer.unref();
            if(Object.keys(environment).some(key=>environment[key]!==previous[key]))touchAudio();
            return json(res,{ok:true,expiresAt:environmentAt+5000});
          }
          // Heartbeats must not wait behind slow playlist/song requests.
          if (url.pathname === '/api/player/claim') {
            const next = client(data.clientId);
            const active = connected();
            if (active && owner !== next) throw fail('已有其他浏览器正在播放',409);
            // A replacement/reconnecting player starts from the last acknowledged
            // position. Active re-entry is only a heartbeat, never a seek command.
            if (desired.track && (!active || owner !== next)) {
              desired.position = player.position;
              desired.seekRevision++;
              revision++;
              touchAudio();
            }
            if (!active || owner !== next) gameRunning = null;
            owner = next; lastSeen = now(); return json(res,{ok:true});
          }
          if (url.pathname === '/api/player/report') {
            verifyOwner(data.clientId);
            if (!Number.isSafeInteger(data.revision) || data.revision < 0 || data.revision > revision) throw fail('播放器状态版本无效');
            if (data.gameRunning !== undefined && typeof data.gameRunning !== 'boolean') throw fail('游戏运行状态无效');
            if (data.revision === revision) {
              numeric(data.position,0,86400); numeric(data.duration,0,86400);
              if (typeof data.playing !== 'boolean') throw fail('播放状态无效');
            }
            lastSeen = now();
            if (data.gameRunning !== undefined) {
              const exited = gameRunning === true && data.gameRunning === false;
              gameRunning = data.gameRunning;
              if (exited) {
                // This lifecycle observation is useful even when playback
                // revision is stale. Invalidate pending selections as a pause
                // would, without changing the queue or seeking the native audio.
                playIntent = false; transportRevision++;
                desired.position = data.revision === revision ? data.position : sampledPosition();
                desired.playing = false;
                bump();
                return json(res,{ok:true});
              }
            }
            if (data.revision !== revision) return json(res,{ok:true});
            const native=owner.startsWith('native_');
            nativeFailureSeekRevision=native&&desired.track&&data.error?desired.seekRevision:null;
            let playbackError='网页音频播放失败，请重试或检查浏览器音频权限';
            if(native) {
              if(mediaFailure?.trackId===desired.track?.id&&mediaFailure?.revision===revision)playbackError=mediaFailure.message;
              else if(data.error==='Native media HTTP failed')playbackError='音频下载失败，请重试或检查网络';
              else playbackError='本机音频播放失败，请重试或检查音频输出';
            }
            player = { ...player, position:data.position, duration:data.duration, playing:data.playing, error:data.error ? playbackError : null };
            playerUpdatedAt=now();
            if (data.ended === true) {
              const advance=serial(async () => {
                if (data.revision !== revision || endedRevision === revision) return;
                endedRevision = revision;
                try { await move(1,true); } catch (e) { desired.playing = false; bump(); player.error = e.status ? e.message : '下一首暂不可播放，请重新选择歌曲'; }
              });
              // The worker needs the acknowledgement now so heartbeats can
              // continue even while the next song URL is slow to resolve.
              json(res,{ok:true});await advance;return;
            }
            return json(res,{ok:true});
          }
          if(url.pathname==='/api/settings')return json(res,{ok:true,...await updateSettings(data)});
          if(url.pathname==='/api/control'&&['mode','volume','pause','resume','toggle','seek'].includes(data.action)) {
            if(data.action==='mode') {
              if(!['loop','single','shuffle'].includes(data.value))throw fail('循环模式无效');
              return json(res,{ok:true,...await updateSettings({player:{shuffle:data.value==='shuffle',repeatOne:data.value==='single'}})});
            }
            if(!connected())throw fail('播放器未连接，请启动本机播放器',409);
            if(data.action==='volume')return json(res,{ok:true,...await updateSettings({player:{volume:numeric(data.value,0,1)}})});
            if(data.action==='seek') {
              if(!desired.track)throw fail('请先选择歌曲');
              desired.position=numeric(data.value,0,player.duration||desired.track.duration);desired.seekRevision++;
            } else {
              if(!desired.track&&!pendingSelections)throw fail('请先选择歌曲');
              const wasPlaying=pendingSelections?playIntent:desired.playing;
              // A failed native worker has stopped even if the last play intent
              // is still true. A deliberate play command can reopen that stream.
              const retry=desired.track&&!pendingSelections&&nativeFailureSeekRevision===desired.seekRevision&&data.action!=='pause';
              playIntent=data.action==='toggle'?retry||!wasPlaying:data.action==='resume';transportRevision++;
              desired.position=sampledPosition();desired.playing=playIntent;
              if(retry)desired.seekRevision++;
            }
            bump();return json(res,{ok:true});
          }
          const selecting=url.pathname==='/api/control'&&['play','next','previous'].includes(data.action);
          const intentRevision=transportRevision;
          if(selecting){pendingSelections++;playIntent=true;}
          let result;
          try { result = await serial(async () => {
            if (url.pathname === '/api/logout') {
              const ctx=sourceContext(data.provider);
              await atomic(accountFile(ctx.provider),{cookie:'',account:null});accounts[ctx.provider]={cookie:'',account:null};
              cancelLogins(ctx.provider);clearSourceCaches(ctx.provider);
              if(desired.track&&providerForId(desired.track.id)===ctx.provider) {
                if(queue.length)queueRevision++;queue=[];index=-1;playIntent=false;transportRevision++;
                desired={...desired,track:null,mediaUrl:null,playing:false,position:0};bump();
              }
              return {provider:ctx.provider};
            }
            if (url.pathname === '/api/control') {
              if (!connected()) throw fail('播放器未连接，请启动本机播放器',409);
              if (data.action === 'play') {
                const trackId = id(data.trackId);
                if(data.source==='queue' && data.queueRevision!==undefined) {
                  if(!Number.isSafeInteger(data.queueRevision)||data.queueRevision<0)throw fail('播放队列版本无效');
                  if(data.queueRevision!==queueRevision)throw fail('播放队列已变化，请刷新后重试',409);
                }
                const tracks=data.source==='queue'?queue:data.source==='search'?(searchQueues.get(trackId)||[]):await loadPlaylist(data.playlistId);
                const idx = tracks.findIndex(t => t.id === trackId);
                if (idx < 0) throw fail('所选歌曲不在当前队列、已读取的歌单或搜索结果');
                await choose(tracks,idx,intentRevision); return {};
              }
              if (data.action === 'next' || data.action === 'previous') { await move(data.action === 'next' ? 1 : -1,false,intentRevision); return {}; }
              throw fail('未知播放指令');
            }
            throw fail('接口不存在',404);
          }); } finally {if(selecting&&--pendingSelections===0)playIntent=desired.playing;}
          return json(res, { ok:true, ...result });
        }
        throw fail('接口或请求方法无效',404);
      }
      if (req.method !== 'GET') throw fail('请求方法无效',405);
      const pathname = decodeURIComponent(url.pathname);
      const target = resolve(publicDir, '.' + (pathname === '/' ? '/index.html' : pathname));
      if (!target.startsWith(publicDir + sep)) throw fail('文件路径无效',403);
      let content; try { content = await readFile(target); } catch { throw fail('页面不存在',404); }
      res.writeHead(200, { 'Content-Type':({'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml'})[extname(target)] || 'application/octet-stream', 'Cache-Control':'no-store', 'Referrer-Policy':'no-referrer', 'X-Content-Type-Options':'nosniff', 'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: https://*.music.126.net; media-src 'self' blob: data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" }); res.end(content);
    } catch (e) {
      const error={ok:false,error:e.status ? e.message : '操作失败，上游或本机服务暂不可用，请重试'};
      if(gameRequests.complete(res,error,e.status || 502))return;
      if (res.headersSent) { res.destroy(); return; }
      sendJson(res,error,e.status || 502);
    }
  });
  server.requestTimeout = 20000; server.headersTimeout = 10000; server.timeout = 30000;
  return {
    server,
    async listen(port = options.port ?? 17863) {
      await new Promise((accept,reject) => { server.once('error',reject); server.listen(port,'127.0.0.1',accept); });
      const actualPort = server.address().port;
      await atomic(resolve(stateDir,'bridge.json'), { host:'127.0.0.1',port:actualPort,token });
      await mkdir(resolve(modDir,'scripts'), {recursive:true});
      await writeFile(resolve(modDir,'scripts/dangomusic_connection.lua'), `return {host="127.0.0.1",port=${actualPort},token="${token}"}\n`, {mode:0o600});
      setAutomaticUpdates(settings.player.checkUpdates);
      return actualPort;
    },
    async close() { updatesStopped=true;setAutomaticUpdates(false);updates.close();gameRequests.close();clearTimeout(environmentTimer);for(const provider of Object.keys(providers)){cancelLogins(provider);providers[provider].close?.();}for(const wake of [...audioWaiters])wake();server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); },
  };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2), options = {};
    for (let i=0; i<args.length; i+=2) { const name = {'--port':'port','--state-dir':'stateDir','--mod-dir':'modDir','--runtime-mod-dir':'runtimeModDir','--fonts-path':'fontsPath','--ktech':'ktechPath','--python':'pythonPath'}[args[i]]; if (!name || !args[i+1]) throw new Error('启动参数无效'); options[name] = name === 'port' ? Number(args[i+1]) : args[i+1]; }
    if (options.port !== undefined && (!Number.isInteger(options.port) || options.port < 1 || options.port > 65535)) throw new Error('端口无效');
    const bridge = await createBridge(options); const port = await bridge.listen();
    console.log(`本机音乐桥已启动：127.0.0.1:${port}`);
  } catch { console.error('本机音乐桥启动失败，请检查端口、参数与本机配置文件'); process.exitCode=1; }
}
