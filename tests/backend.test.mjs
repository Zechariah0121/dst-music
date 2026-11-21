import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import http from 'node:http';
import { Readable, PassThrough } from 'node:stream';
import { EventEmitter } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { createBridge } from '../helper/server.mjs';
import { createNetease, createMediaOpener, encryptWeapi, validateMediaUrl } from '../helper/netease.mjs';
import {createSettingsStore} from '../helper/settings.mjs';
import {UPDATE_SOURCE} from '../helper/updates.mjs';

const token = 'a'.repeat(64), clientId = 'test_player_01';
async function setup(t, overrides={}, bridgeOptions={}, prepare=async()=>{}) {
  const dir = await mkdtemp(resolve(tmpdir(),'dst-music-test-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));
  await prepare(dir);
  // 连接文件只写入有本项目身份的模组，测试也提供完整的临时身份标记。
  await mkdir(resolve(dir,'mod'),{recursive:true});
  await writeFile(resolve(dir,'mod/music_workshop_identity.json'),JSON.stringify({schema:1,id:'zcc-dst-music',channel:'workshop-beta',version:'0.6.0-beta.6'}),{flag:'wx'})
    .catch(error=>{if(error.code!=='EEXIST')throw error;});
  let clock = 100000, mediaRange;
  const tracks = [1,2,3].map(i=>({id:String(i),name:`歌${i}`,artists:'歌手',duration:200}));
  const upstream = {
    startLogin:async()=>({key:'test-key',url:'https://music.163.com/login?codekey=test-key'}),
    checkLogin:async()=>({status:'success',cookie:'MUSIC_U=secret-cookie'}),
    account:async()=>({id:'1',nickname:'测试'}), playlists:async()=>[{id:'1',name:'歌单',trackCount:3}],
    playlist:async()=>tracks,
    lyrics:async()=>({lrc:{lyric:'[00:01]这里是自写测试歌词'}}),
    discover:async()=>[{id:'9',name:'推荐测试',trackCount:2,cover:'https://p1.music.126.net/test.jpg'}],
    search:async()=>({tracks:tracks.slice(0,2).map(t=>({...t,cover:'https://p1.music.126.net/test.jpg'})),total:2}),
    songUrl:async id=>({url:`https://m1.music.126.net/${id}.mp3`,trial:id==='2',expires:clock+100000}),
    openMedia:async (_url,range)=>{ mediaRange=range; return Object.assign(Readable.from(['abc']),{statusCode:range?206:200,headers:{'content-type':'audio/mpeg','content-length':'3',...(range?{'content-range':'bytes 0-2/3'}:{})}}); },
    ...overrides,
  };
  const bridge = await createBridge({stateDir:resolve(dir,'state'),modDir:resolve(dir,'mod'),token,upstream,now:()=>clock,assets:{cover:async(_id,_url)=>({atlas:'images/music_cache/cover.xml',image:'cover.tex'}),qr:async()=>({atlas:'images/music_cache/qr.xml',image:'qr.tex'})},updateFetch:async()=>Response.json([]),...bridgeOptions});
  t.after(()=>bridge.close());
  const port=await bridge.listen(0), base=`http://127.0.0.1:${port}`;
  async function request(path, data, headers={}) { const r = await fetch(base+path,{method:data?'POST':'GET',headers:{Authorization:`Bearer ${token}`,...headers},...(data?{body:JSON.stringify(data)}:{})}); return {status:r.status,body:await r.json()}; }
  async function login() { await request('/api/login/start',{}); return request('/api/login/check?key=test-key'); }
  async function claim() { return request('/api/player/claim',{clientId}); }
  async function play() { await login(); await claim(); return request('/api/control',{action:'play',playlistId:'1',trackId:'1'}); }
  return {dir,port,base,request,login,claim,play,close:()=>bridge.close(),setTime:n=>clock=n,range:()=>mediaRange};
}

test('退出游戏暂停并唤醒长轮询，保留歌曲队列进度，重进不自动播放',async t=>{
  const f=await setup(t);await f.play();
  const state=async()=> (await f.request('/api/player/state?clientId='+clientId)).body;
  const report=(revision,gameRunning,patch={})=>f.request('/api/player/report',{clientId,revision,position:12.5,duration:200,playing:true,gameRunning,...patch});
  let current=await state();
  await report(current.desired.revision,false);
  assert.equal((await state()).desired.playing,true,'no observed game session: do not interrupt pre-game listening');
  await report(current.desired.revision,true);await f.claim();
  const queue=(await f.request('/api/queue')).body;
  const waiting=f.request(`/api/player/state?clientId=${clientId}&after=${current.audioRevision}&wait=8000`);
  await delay(20);
  assert.equal((await report(current.desired.revision,false,{position:13})).status,200);
  const paused=await Promise.race([waiting,delay(500).then(()=>null)]);
  assert.ok(paused,'game exit must wake the audio worker immediately');
  assert.equal(paused.body.desired.playing,false);assert.equal(paused.body.desired.position,13);
  assert.equal(paused.body.desired.seekRevision,current.desired.seekRevision);
  assert.deepEqual((await f.request('/api/queue')).body,queue);
  assert.equal((await f.request('/api/status')).body.player.playing,false);
  await report(current.desired.revision,false,{ended:true});
  assert.deepEqual((await f.request('/api/queue')).body,queue,'stale ended report cannot advance after exit');
  current=await state();
  await report(current.desired.revision,false,{position:13,playing:false});
  assert.equal((await state()).audioRevision,current.audioRevision,'repeated absence does not create repeated pauses');
  await report(current.desired.revision,true,{position:13,playing:false});
  assert.equal((await state()).desired.playing,false,'reopening game does not resume');
  await f.request('/api/control',{action:'resume'});current=await state();
  await report(current.desired.revision,true);
  assert.equal((await state()).desired.playing,true,'world/menu changes with a living client do not pause');
  await report(current.desired.revision,false);
  assert.equal((await state()).desired.playing,false,'later game sessions re-arm the exit detection');
});

test('游戏退出报告校验、旧播放版本、旧客户端以及更换播放器所有者',async t=>{
  const f=await setup(t);await f.play();
  const report=patch=>f.request('/api/player/report',{clientId,revision:1,position:20,duration:200,playing:true,...patch});
  await report({gameRunning:true});
  assert.equal((await report({gameRunning:'false'})).status,400);
  assert.equal((await report({gameRunning:false,position:-1})).status,400);
  assert.equal((await report({clientId:'foreign_player',gameRunning:false})).status,409);
  await report({});
  assert.equal((await f.request('/api/status')).body.player.playing,true,'old reports without presence do not imply exit');
  await f.request('/api/control',{action:'volume',value:.3});
  assert.equal((await report({gameRunning:false})).status,200);
  assert.equal((await f.request('/api/status')).body.player.playing,false,'stale playback revision still carries current process presence');
  await f.request('/api/control',{action:'resume'});
  let revision=(await f.request('/api/status')).body.revision;
  await report({revision,gameRunning:true});
  f.setTime(110001);
  const newOwner='replacement_player';
  await f.request('/api/player/claim',{clientId:newOwner});
  revision=(await f.request('/api/status')).body.revision;
  await report({clientId:newOwner,revision,gameRunning:false});
  assert.equal((await f.request('/api/player/state?clientId='+newOwner)).body.desired.playing,true,'new owner does not inherit a prior game session');
});

test('关闭游戏时的慢首曲和已开始的自动下一曲不能随后恢复播放',async t=>{
  let heldId='1',enter,release;
  let entered=new Promise(resolve=>enter=resolve);
  const f=await setup(t,{songUrl:async id=>{
    if(id===heldId){enter();await new Promise(resolve=>release=resolve);}
    return{url:`https://m1.music.126.net/${id}.mp3`,expires:999999};
  }});await f.login();await f.claim();
  const report=(revision,gameRunning,patch={})=>f.request('/api/player/report',{clientId,revision,position:0,duration:200,playing:false,gameRunning,...patch});
  await report(0,true);
  const selecting=f.request('/api/control',{action:'play',playlistId:'1',trackId:'1'});await entered;
  try {assert.equal((await report(0,false)).status,200);}finally{release();}
  await selecting;
  let status=(await f.request('/api/status')).body;
  assert.equal(status.player.track.id,'1');assert.equal(status.player.playing,false);
  await f.request('/api/control',{action:'resume'});status=(await f.request('/api/status')).body;
  await report(status.revision,true,{playing:true});
  heldId='2';entered=new Promise(resolve=>enter=resolve);
  const ending=report(status.revision,true,{position:200,ended:true});await entered;
  try {assert.equal((await report(status.revision,false,{position:200})).status,200);}finally{release();}
  await ending;
  for(let i=0;i<20;i++) {
    status=(await f.request('/api/status')).body;
    if(status.player.track.id==='2')break;
    await delay(10);
  }
  assert.equal(status.player.track.id,'2');assert.equal(status.player.playing,false);
});

test('结束歌曲与关闭游戏同一份报告不触发自动下一首',async t=>{
  const f=await setup(t);await f.play();
  const report=patch=>f.request('/api/player/report',{clientId,revision:1,position:200,duration:200,playing:false,...patch});
  await report({gameRunning:true});
  await report({gameRunning:false,ended:true});
  const status=(await f.request('/api/status')).body;
  assert.equal(status.player.track.id,'1');assert.equal(status.player.playing,false);assert.equal(status.player.position,200);
});

test('长轮询即时唤醒控制/环境/声音设置，普通心跳不制造更新',async t=>{
  const f=await setup(t);await f.play();
  const state=async()=> (await f.request('/api/player/state?clientId='+clientId)).body;
  let current=await state();assert.ok(Number.isSafeInteger(current.audioRevision));
  for(const change of [
    ()=>f.request('/api/control',{action:'pause'}),
    ()=>f.request('/api/environment',{water:false,cave:false,indoor:false,rain:.5,region:'lunar'}),
    ()=>f.request('/api/settings',{player:{envStrength:.4}}),
  ]) {
    let settled=false;
    const pending=f.request(`/api/player/state?clientId=${clientId}&after=${current.audioRevision}&wait=8000`).then(r=>{settled=true;return r;});
    await delay(25);assert.equal(settled,false);
    const started=performance.now();assert.equal((await change()).status,200);
    const response=await Promise.race([pending,delay(500).then(()=>null)]);
    assert.ok(response,'audio update must wake the held request');assert.equal(response.status,200);
    assert.ok(performance.now()-started<500);assert.ok(response.body.audioRevision>current.audioRevision);current=response.body;
  }
  assert.equal(current.desired.playing,false);assert.equal(current.desired.audio.env.region,'lunar');assert.equal(current.desired.audio.env.strength,.4);
  await f.request('/api/environment',{water:false,cave:false,indoor:false,rain:.5,region:'lunar'});
  await f.claim();assert.equal((await state()).audioRevision,current.audioRevision);
  const timeout=await f.request(`/api/player/state?clientId=${clientId}&after=${current.audioRevision}&wait=20`);
  assert.equal(timeout.body.audioRevision,current.audioRevision);
  for(const query of ['after=-1','after=no','wait=8001','wait=-1','wait=1.5'])assert.equal((await f.request(`/api/player/state?clientId=${clientId}&${query}`)).status,400);
  assert.equal((await f.request('/api/player/state?clientId=other_player&wait=8000')).status,409);
});

test('长轮询随环境TTL退回干声；断开释放等待名额，关闭服务不留连接',async t=>{
  const f=await setup(t,{}, {now:Date.now});await f.claim();
  await f.request('/api/environment',{water:false,cave:true,indoor:false,rain:.7,region:'atrium'});
  const initial=(await f.request('/api/player/state?clientId='+clientId)).body;
  const expired=await f.request(`/api/player/state?clientId=${clientId}&after=${initial.audioRevision}&wait=8000`);
  assert.equal(expired.body.desired.audio.env.region,'surface');assert.equal(expired.body.desired.audio.env.rain,0);
  assert.ok(expired.body.audioRevision>initial.audioRevision);
  const controllers=Array.from({length:8},()=>new AbortController());
  const waiting=controllers.map(c=>fetch(`${f.base}/api/player/state?clientId=${clientId}&after=${expired.body.audioRevision}&wait=8000`,{headers:{Authorization:`Bearer ${token}`},signal:c.signal}).catch(()=>null));
  await delay(50);for(const c of controllers)c.abort();await Promise.all(waiting);await delay(50);
  assert.equal((await f.request(`/api/player/state?clientId=${clientId}&after=${expired.body.audioRevision}&wait=10`)).status,200);
});

test('慢选歌时暂停/音量/设置/队列立即响应，后到暂停不会被歌曲加载覆盖',async t=>{
  let release,enter;
  const entered=new Promise(resolve=>enter=resolve);
  const f=await setup(t,{songUrl:async id=>{
    if(id==='2'){enter();await new Promise(resolve=>release=resolve);}
    return{url:`https://m1.music.126.net/${id}.mp3`,expires:999999};
  }});await f.play();
  const selecting=f.request('/api/control',{action:'next'});await entered;
  try {
    const actions=Promise.all([
      f.request('/api/control',{action:'pause'}),f.request('/api/control',{action:'volume',value:.3}),
      f.request('/api/settings',{player:{envStrength:.6}}),f.request('/api/settings',{lyrics:{scale:1.25}}),f.request('/api/queue'),
    ]);
    const replies=await Promise.race([actions,delay(500).then(()=>null)]);assert.ok(replies,'transport must not queue behind slow songUrl');
    for(const reply of replies)assert.equal(reply.status,200);
    assert.equal(replies[4].body.currentTrackId,'1');
  } finally {release();}
  assert.equal((await selecting).status,200);
  const state=(await f.request('/api/player/state?clientId='+clientId)).body.desired;
  assert.equal(state.track.id,'2');assert.equal(state.playing,false);assert.equal(state.volume,.3);assert.equal(state.audio.env.strength,.6);
  const persisted=(await createSettingsStore(resolve(f.dir,'state'))).read().settings;
  assert.equal(persisted.player.volume,.3);assert.equal(persisted.player.envStrength,.6);assert.equal(persisted.lyrics.scale,1.25);
  await f.request('/api/control',{action:'resume'});assert.equal((await f.request('/api/status')).body.player.playing,true);
});

test('首曲加载中可暂停，连续待处理next也遵守后来暂停',async t=>{
  let release,enter;let heldId='1';
  let entered=new Promise(resolve=>enter=resolve);
  const f=await setup(t,{songUrl:async id=>{
    if(id===heldId){enter();await new Promise(resolve=>release=resolve);}
    return{url:`https://m1.music.126.net/${id}.mp3`,expires:999999};
  }});await f.login();await f.claim();
  let selected=f.request('/api/control',{action:'play',playlistId:'1',trackId:'1'});await entered;
  try {assert.equal((await f.request('/api/control',{action:'pause'})).status,200);}finally{release();}
  await selected;assert.equal((await f.request('/api/status')).body.player.playing,false);
  heldId='2';entered=new Promise(resolve=>enter=resolve);
  selected=f.request('/api/control',{action:'next'});await entered;
  const queued=f.request('/api/control',{action:'next'});await delay(25);
  try {assert.equal((await f.request('/api/control',{action:'pause'})).status,200);}finally{release();}
  await Promise.all([selected,queued]);
  const status=(await f.request('/api/status')).body;
  assert.equal(status.player.track.id,'3');assert.equal(status.player.playing,false);
});

test('自动下一曲慢请求不占住ended回执，后续心跳可续租',async t=>{
  let enter,release;const entered=new Promise(resolve=>enter=resolve);
  const f=await setup(t,{songUrl:async id=>{
    if(id==='2'){enter();await new Promise(resolve=>release=resolve);}
    return{url:`https://m1.music.126.net/${id}.mp3`,expires:999999};
  }});await f.play();
  const report=f.request('/api/player/report',{clientId,revision:1,position:200,duration:200,playing:false,ended:true});await entered;
  try {
    assert.equal((await Promise.race([report,delay(500).then(()=>({status:0}))])).status,200);
    f.setTime(109000);
    assert.equal((await f.request('/api/player/report',{clientId,revision:1,position:200,duration:200,playing:false})).status,200);
    f.setTime(115000);assert.equal((await f.request('/api/status')).body.playerConnected,true);
  }finally{release();}
  for(let i=0;i<10&&(await f.request('/api/status')).body.player.track.id!=='2';i++)await delay(10);
  assert.equal((await f.request('/api/status')).body.player.track.id,'2');
});
test('当前队列鉴权、空队列、分页验证与元数据白名单',async t=>{
  const tracks=Array.from({length:205},(_,i)=>({id:String(i+1),name:`歌${i+1}`,artists:'歌手',duration:200,cover:'https://p1.music.126.net/test.jpg',mediaUrl:'private',token:'private',account:{secret:true}}));
  const f=await setup(t,{playlist:async()=>tracks});
  assert.equal((await fetch(f.base+'/api/queue')).status,401);
  assert.equal((await f.request('/api/queue',undefined,{Origin:'https://evil.example'})).status,403);
  assert.deepEqual((await f.request('/api/queue')).body,{ok:true,tracks:[],total:0,offset:0,hasMore:false,currentIndex:-1,currentTrackId:null,queueRevision:0});
  await f.claim();
  assert.equal((await f.request('/api/control',{action:'play',source:'queue',trackId:'1'})).status,400);
  for(const query of ['offset=-1','offset=1.5','offset=9007199254740992','limit=101','limit=0','limit=1.5','limit=no'])assert.equal((await f.request('/api/queue?'+query)).status,400);
  await f.play();
  const first=(await f.request('/api/queue')).body;
  assert.equal(first.tracks.length,100);assert.equal(first.total,205);assert.equal(first.hasMore,true);assert.equal(first.currentIndex,0);assert.equal(first.currentTrackId,'1');assert.equal(first.queueRevision,1);
  assert.deepEqual(Object.keys(first.tracks[0]).sort(),['artists','cover','duration','id','name']);
  const last=(await f.request('/api/queue?offset=200&limit=10')).body;
  assert.equal(last.tracks.length,5);assert.equal(last.tracks[0].id,'201');assert.equal(last.offset,200);assert.equal(last.hasMore,false);
  assert.equal((await f.request('/api/queue?offset=500')).body.tracks.length,0);
});

test('队列点歌使用实际队列，版本过期和失败不改变播放，清空递增版本',async t=>{
  let playlistCalls=0,broken=false,songCalls=0;
  const f=await setup(t,{playlist:async()=>{playlistCalls++;return [1,2,3].map(i=>({id:String(i),name:`歌${i}`,artists:'歌手',duration:200}));},songUrl:async id=>{songCalls++;if(broken)throw Error('private');return{url:`https://m1.music.126.net/${id}.mp3`,expires:999999};}});
  await f.play();
  const select=(trackId,queueRevision=1)=>f.request('/api/control',{action:'play',source:'queue',trackId,queueRevision});
  assert.equal((await select('3')).status,200);
  let q=(await f.request('/api/queue')).body;
  assert.equal(q.currentIndex,2);assert.equal(q.currentTrackId,'3');assert.equal(q.queueRevision,1);assert.equal(playlistCalls,1);
  await f.request('/api/control',{action:'next'});
  q=(await f.request('/api/queue')).body;assert.equal(q.currentIndex,0);assert.equal(q.queueRevision,1);
  const before=(await f.request('/api/status')).body, calls=songCalls;
  assert.equal((await select('2',0)).status,409);
  for(const value of [-1,'1',1.5,null])assert.equal((await select('2',value)).status,400);
  for(const trackId of ['', ' ', '999'])assert.equal((await select(trackId)).status,400);
  assert.equal(songCalls,calls);assert.deepEqual((await f.request('/api/status')).body,before);
  broken=true;assert.equal((await select('2')).status,502);
  assert.deepEqual((await f.request('/api/status')).body,before);assert.deepEqual((await f.request('/api/queue')).body,q);
  broken=false;
  await f.request('/api/search?q=test');
  await f.request('/api/control',{action:'play',source:'search',trackId:'2'});
  q=(await f.request('/api/queue')).body;assert.equal(q.total,2);assert.equal(q.queueRevision,2);assert.equal(q.currentIndex,1);
  assert.equal((await select('1',1)).status,409);
  assert.equal((await f.request('/api/control',{action:'play',source:'queue',trackId:'1'})).status,200);
  assert.equal(playlistCalls,1);
  await f.request('/api/logout',{});
  q=(await f.request('/api/queue')).body;assert.equal(q.total,0);assert.equal(q.queueRevision,3);assert.equal(q.currentIndex,-1);assert.equal(q.currentTrackId,null);
});

test('字形光效接口共享歌词缓存、仅传字符集合，失败不影响歌词与播放状态',async t=>{
  let calls=0,received,broken=false;
  const font={size:30,glyphs:{A:{core:'g0_core.tex',near:'g0_near.tex',far:'g0_far.tex'}}};
  const f=await setup(t,{lyrics:async()=>{calls++;return{lrc:{lyric:'[00:01]A A 雨\n[00:03]雨 A'}};}},{glyphs:{build:async chars=>{
    received=chars;if(broken)throw new Error('private source details');
    return {asset:{atlas:'images/music_cache/fixture.xml',image:'fixture.tex'},fonts:{mono:font,smooth:font},missing:[]};
  }}});
  assert.equal((await fetch(f.base+'/api/lyric-glyphs?trackId=1')).status,401);
  const before=await f.request('/api/lyrics?trackId=1');
  const art=await f.request('/api/lyric-glyphs?trackId=1');
  assert.equal(art.status,200);assert.equal(art.body.trackId,'1');assert.equal(calls,1);
  assert.deepEqual([...received].sort(),[' ','A','雨'].sort());
  assert.equal(art.body.fonts.mono.glyphs.A.near,'g0_near.tex');
  assert.deepEqual((await f.request('/api/lyrics?trackId=1')).body,before.body);
  broken=true;
  const failed=await f.request('/api/lyric-glyphs?trackId=1');
  assert.equal(failed.status,502);assert.doesNotMatch(JSON.stringify(failed),/private source/);
  assert.equal((await f.request('/api/status')).body.revision,0);
  assert.equal((await f.request('/api/lyrics?trackId=1')).body.timing,'line');
  assert.equal((await f.request('/api/lyric-glyphs?trackId=../x')).status,400);
});

test('鉴权阻止无凭据、外站 Origin、伪造 Host；健康状态不泄密',async t=>{
  const f=await setup(t);
  assert.equal((await fetch(f.base+'/api/status')).status,401);
  assert.equal((await f.request('/api/status',undefined,{Origin:'https://evil.example'})).status,403);
  assert.equal((await f.request('/api/status',undefined,{'Sec-Fetch-Site':'cross-site'})).status,403);
  const hostile = await new Promise(resolve=>{ http.get(f.base+'/health',{headers:{Host:'evil.example'}},res=>{res.resume();resolve(res.statusCode);}); });
  assert.equal(hostile,403);
  assert.deepEqual(await (await fetch(f.base+'/health')).json(),{ok:true,name:'dst-music-bridge'});
  assert.equal((await f.request('/api/login/check?key=foreign')).status,400);
  const navigation=await fetch(f.base+'/',{headers:{'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate'}});
  assert.equal(navigation.status,200);assert.match(navigation.headers.get('content-type'),/text\/html/);
  assert.equal((await f.request('/api/status',undefined,{'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate'})).status,403);
});
test('扫码不回传 Cookie；歌单分页和本机配置',async t=>{
  const f=await setup(t); const logged=await f.login();
  assert.equal(logged.body.status,'success'); assert.ok(!JSON.stringify(logged).includes('secret-cookie'));
  assert.equal(JSON.parse(await readFile(resolve(f.dir,'state/account.json'),'utf8')).cookie,'MUSIC_U=secret-cookie');
  assert.match(await readFile(resolve(f.dir,'mod/scripts/dangomusic_connection.lua'),'utf8'),new RegExp(`port=${f.port}`));
  const result=await f.request('/api/playlist?id=1&offset=1&limit=1');
  assert.equal(result.body.total,3);assert.equal(result.body.tracks[0].id,'2');
  assert.equal((await f.request('/api/playlist?id=1&limit=101')).status,400);
});
test('租约与断联：另一播放器不可抢占，超时拒绝控制并可重领',async t=>{
  const f=await setup(t); await f.play();
  assert.equal((await f.request('/api/player/claim',{clientId:'other_player'})).status,409);
  f.setTime(110001);
  assert.equal((await f.request('/api/status')).body.playerConnected,false);
  assert.equal((await f.request('/api/control',{action:'next'})).status,409);
  assert.equal((await f.request('/api/player/claim',{clientId:'other_player'})).status,200);
  assert.equal((await f.request('/api/player/report',{clientId,revision:1,position:3,duration:200,playing:true})).status,409);
});
test('连续 next 串行推进；旧 revision 和重复 ended 不覆盖新歌',async t=>{
  const f=await setup(t);await f.play();
  const calls=await Promise.all([f.request('/api/control',{action:'next'}),f.request('/api/control',{action:'next'})]);
  assert.ok(calls.every(r=>r.status===200));
  let s=(await f.request('/api/status')).body;assert.equal(s.player.track.id,'3');assert.equal(s.revision,3);
  await f.request('/api/player/report',{clientId,revision:1,position:123,duration:200,playing:false,ended:true});
  s=(await f.request('/api/status')).body;assert.equal(s.revision,3);assert.equal(s.player.position,0);
  const report={clientId,revision:3,position:200,duration:200,playing:false,ended:true};
  await Promise.all([f.request('/api/player/report',report),f.request('/api/player/report',report)]);
  s=(await f.request('/api/status')).body;assert.equal(s.player.track.id,'1');assert.equal(s.revision,4);
});
test('安全媒体代理转发 Range，不接受任意地址、无 Cookie 下传',async t=>{
  const f=await setup(t);await f.play();
  const state=(await f.request('/api/player/state?clientId='+clientId)).body.desired;
  assert.match(state.mediaUrl,/^\/api\/media\?/);
  const r=await fetch(f.base+state.mediaUrl,{headers:{Range:'bytes=0-2'}});
  assert.equal(r.status,206);assert.equal(r.headers.get('content-range'),'bytes 0-2/3');assert.equal(await r.text(),'abc');assert.equal(f.range(),'bytes=0-2');assert.equal(r.headers.get('set-cookie'),null);
  assert.equal((await fetch(f.base+state.mediaUrl,{headers:{Range:'bytes=0-1,3-4'}})).status,416);
  assert.equal((await f.request('/api/media?trackId=999&url=https://evil.example')).status,410);
  for(const bad of ['https://127.0.0.1/a','https://music.126.net.evil.example/a','https://m1.music.126.net:444/a','https://u:p@m1.music.126.net/a']) assert.throws(()=>validateMediaUrl(bad));
});
test('上游失败保留当前歌曲，错误不泄密；媒体中断可恢复服务',async t=>{
  let broken=false;
  const f=await setup(t,{songUrl:async id=>{if(broken)throw new Error('MUSIC_U=do-not-leak');return{url:`https://m1.music.126.net/${id}`,expires:999999};},openMedia:async()=>{throw new Error('network secret');}});
  await f.play();broken=true;
  const failed=await f.request('/api/control',{action:'next'});assert.equal(failed.status,502);assert.ok(!JSON.stringify(failed).includes('do-not-leak'));
  assert.equal((await f.request('/api/status')).body.player.track.id,'1');
  assert.equal((await f.request('/api/media?trackId=1')).status,502);
  assert.equal((await f.request('/api/status')).status,200);
});
test('中途断流关闭下游连接，服务仍响应；JSON/非法数值不修改状态',async t=>{
  const f=await setup(t,{openMedia:async()=>{ const source=new Readable({read(){this.push(Buffer.from('a'));setImmediate(()=>this.destroy(new Error('disconnect')));}});return Object.assign(source,{statusCode:200,headers:{'content-type':'audio/mpeg','content-length':'100000'}});}});
  await f.play();
  try { const response=await fetch(f.base+'/api/media?trackId=1',{headers:{Authorization:`Bearer ${token}`}});await response.arrayBuffer(); assert.fail('应因流中断失败'); } catch(e) { assert.ok(e); }
  assert.equal((await f.request('/api/control',{action:'volume',value:3})).status,400);
  assert.equal((await f.request('/api/status')).body.revision,1);
  const malformed=await fetch(f.base+'/api/control',{method:'POST',headers:{Authorization:`Bearer ${token}`},body:'{'});assert.equal(malformed.status,400);
});
test('网易云补齐 trackIds 缺失资料并保持原次序，试听不换版本',async()=>{
  const urls=[];
  const api=createNetease({fetchImpl:async url=>{urls.push(url);let b;
    if(url.includes('playlist/detail'))b={code:200,playlist:{trackIds:[{id:2},{id:1}],tracks:[{id:1,name:'a',dt:1000}]}};
    else if(url.includes('song/detail'))b={code:200,songs:[{id:2,name:'b',dt:2000}]};
    else b={code:200,data:[{id:2,url:'http://m1.music.126.net/2.mp3',freeTrialInfo:{start:0,end:30}}]};
    return new Response(JSON.stringify(b));
  }});
  assert.deepEqual((await api.playlist('1','')).map(t=>t.id),['2','1']);
  const media=await api.songUrl('2','');assert.equal(media.trial,true);assert.match(media.url,/^https:/);assert.equal(urls.length,3);
  const encrypted=encryptWeapi({type:1});assert.equal(encrypted.get('encSecKey').length,256);assert.ok(encrypted.get('params'));
});
test('慢上游不阻塞心跳；音量 revision 保留当前进度；过期媒体刷新不换权限',async t=>{
  let release, waiting, count=0, isTrial=false;
  const entered=new Promise(resolve=>waiting=resolve);
  const f=await setup(t,{songUrl:async id=>{
    count++;
    if(count===2){waiting();await new Promise(resolve=>release=resolve);}
    return{url:`https://m1.music.126.net/${id}`,trial:isTrial,expires:100001};
  }});
  await f.play();
  await f.request('/api/player/report',{clientId,revision:1,position:42,duration:200,playing:true});
  await f.request('/api/control',{action:'volume',value:0.3});
  assert.equal((await f.request('/api/status')).body.player.position,42);
  const pending=f.request('/api/control',{action:'next'});await entered;
  f.setTime(109000);
  const heartbeat=await f.request('/api/player/report',{clientId,revision:2,position:44,duration:200,playing:true});
  assert.equal(heartbeat.status,200);
  f.setTime(111000);release();assert.equal((await pending).status,200);
  const refreshed=await fetch(f.base+'/api/media?trackId=2',{headers:{Authorization:`Bearer ${token}`}});
  assert.equal(refreshed.status,200);await refreshed.arrayBuffer();assert.equal(count,3);
  isTrial=true;
  assert.equal((await f.request('/api/media?trackId=2')).status,410);
});
test('上游超时与限额失败统一返回安全错误，不泄露响应',async()=>{
  for(const fetchImpl of [async()=>{throw new DOMException('MUSIC_U=secret','TimeoutError');},async()=>new Response('MUSIC_U=secret',{status:503}),async()=>new Response('x'.repeat(13*1024*1024))]) {
    const api=createNetease({fetchImpl});
    await assert.rejects(()=>api.account('cookie'),e=>e.message==='网易云请求失败，请稍后重试或重新登录');
  }
});
test('seekRevision 仅歌曲选择和显式 seek 推进，小于2秒的 seek 保留准确位置',async t=>{
  const f=await setup(t); await f.play();
  const state=async()=> (await f.request('/api/player/state?clientId='+clientId)).body.desired;
  const original=await state();assert.equal(original.seekRevision,1);
  for(const data of [{action:'volume',value:0.2},{action:'pause'},{action:'resume'},{action:'toggle'}]) {
    await f.request('/api/control',data);assert.equal((await state()).seekRevision,original.seekRevision);
  }
  await f.request('/api/control',{action:'seek',value:1.25});
  const sought=await state();assert.equal(sought.position,1.25);assert.equal(sought.seekRevision,2);
  await f.request('/api/control',{action:'seek',value:0.75});
  assert.equal((await state()).seekRevision,3);assert.equal((await state()).position,0.75);
  await f.request('/api/control',{action:'next'});assert.equal((await state()).seekRevision,4);
});
test('媒体只限制连接与响应头阶段，长响应和回压不被连接总计时截断；caller abort 有效',async()=>{
  let transportSignal, idle, source;
  const opener=createMediaOpener({connectTimeoutMs:15,idleTimeoutMs:80,lookupImpl:async()=>[{address:'1.1.1.1',family:4}],getImpl:(_url,options,callback)=>{
    const req=new EventEmitter();transportSignal=options.signal;
    source=Object.assign(new PassThrough(),{statusCode:200,headers:{'content-type':'audio/mpeg'},setTimeout(ms,fn){assert.equal(ms,80);idle=fn;return this;}});
    source.on('error',()=>{});
    options.signal.addEventListener('abort',()=>{source.destroy();req.emit('error',new Error('aborted'));},{once:true});
    queueMicrotask(()=>callback(source));return req;
  }});
  const caller=new AbortController(), response=await opener('https://m1.music.126.net/a',undefined,caller.signal);
  response.pause(); await delay(35);
  assert.equal(transportSignal.aborted,false);assert.equal(response.destroyed,false);
  idle();assert.equal(response.destroyed,false,'回压暂停不应因空闲被关闭');
  const chunks=[];response.on('data',chunk=>chunks.push(chunk.toString()));response.resume();response.write('audio');
  await delay(0);assert.deepEqual(chunks,['audio']);
  caller.abort();await delay(0);assert.equal(response.destroyed,true);
});
test('媒体 DNS 和响应头等待都有时限；未暂停的空闲流会关闭',async()=>{
  const keepAlive=setTimeout(()=>{},1000);
  try {
    const dnsHang=createMediaOpener({connectTimeoutMs:10,lookupImpl:()=>new Promise(()=>{})});
    await assert.rejects(()=>dnsHang('https://m1.music.126.net/a'),/音频连接超时/);
    const headerHang=createMediaOpener({connectTimeoutMs:10,lookupImpl:async()=>[{address:'1.1.1.1',family:4}],getImpl:(_url,options)=>{
      const req=new EventEmitter();options.signal.addEventListener('abort',()=>req.emit('error',new Error('timeout')),{once:true});return req;
    }});
    await assert.rejects(()=>headerHang('https://m1.music.126.net/a'),/timeout/);
    let idle;
    const idleStream=createMediaOpener({lookupImpl:async()=>[{address:'1.1.1.1',family:4}],getImpl:(_url,_options,callback)=>{
      const req=new EventEmitter();const response=Object.assign(new PassThrough(),{statusCode:200,headers:{},setTimeout(_ms,fn){idle=fn;}});
      response.on('error',()=>{});queueMicrotask(()=>callback(response));return req;
    }});
    const response=await idleStream('https://m1.music.126.net/a');response.resume();idle();assert.equal(response.destroyed,true);
  } finally { clearTimeout(keepAlive); }
});
test('网易云版权会员受控错误保留中文，未知上游错误仍脱敏',async t=>{
  const api=createNetease({fetchImpl:async()=>new Response(JSON.stringify({code:200,data:[{id:2,url:null}]}))});
  await assert.rejects(()=>api.songUrl('2',''),e=>e.status===403 && /会员、版权或地区限制/.test(e.message));
  const f=await setup(t,{songUrl:api.songUrl});await f.login();await f.claim();
  const result=await f.request('/api/control',{action:'play',playlistId:'1',trackId:'2'});
  assert.equal(result.status,403);assert.match(result.body.error,/会员、版权或地区限制/);
});
test('租约失效后 claim 从已报告位置恢复；活跃同ID重入不修改期望指令',async t=>{
  const f=await setup(t);await f.play();
  const get=async who=>(await f.request('/api/player/state?clientId='+who)).body.desired;
  await f.request('/api/player/report',{clientId,revision:1,position:42.5,duration:200,playing:true});
  const original=await get(clientId);
  await f.claim();assert.deepEqual(await get(clientId),original);
  assert.equal((await f.request('/api/player/claim',{clientId:'second_player'})).status,409);
  f.setTime(110001);await f.claim();
  const reconnected=await get(clientId);
  assert.equal(reconnected.position,42.5);assert.equal(reconnected.revision,original.revision+1);assert.equal(reconnected.seekRevision,original.seekRevision+1);assert.equal(reconnected.playing,true);
  await f.request('/api/player/report',{clientId,revision:reconnected.revision,position:57.75,duration:200,playing:true});
  f.setTime(120002);
  await f.request('/api/player/claim',{clientId:'second_player'});
  const replaced=await get('second_player');assert.equal(replaced.position,57.75);assert.equal(replaced.revision,reconnected.revision+1);assert.equal(replaced.seekRevision,reconnected.seekRevision+1);
  assert.equal((await f.request('/api/player/state?clientId='+clientId)).status,409);
});
test('歌词、推荐、搜索队列和游戏图片API完整数据链路',async t=>{
 const f=await setup(t);
 const lyrics=await f.request('/api/lyrics?trackId=1');assert.equal(lyrics.body.timing,'line');assert.equal(lyrics.body.trackId,'1');assert.deepEqual(lyrics.body.lines[0].words,[]);
 assert.equal((await f.request('/api/artwork?trackId=1')).status,404);
 const lists=await f.request('/api/discover?section=recommend');assert.equal(lists.body.playlists[0].cover,'https://p1.music.126.net/test.jpg');
 assert.equal((await f.request('/api/artwork?playlistId=9')).body.asset.image,'cover.tex');
 assert.equal((await f.request('/api/discover?section=unknown')).status,400);
 await f.request('/api/login/start',{});assert.equal((await f.request('/api/login/artwork?key=test-key')).body.asset.image,'qr.tex');
 assert.equal((await f.request('/api/login/artwork?key=foreign')).status,400);
 await f.login();assert.equal((await f.request('/api/login/artwork?key=test-key')).status,400);
 const search=await f.request('/api/search?q=test&offset=0&limit=2');assert.equal(search.body.total,2);assert.equal(search.body.offset,0);
 assert.equal((await f.request('/api/artwork?trackId=1')).body.asset.image,'cover.tex');
 await f.claim();assert.equal((await f.request('/api/control',{action:'play',source:'search',trackId:'1'})).status,200);
 await f.request('/api/control',{action:'next'});assert.equal((await f.request('/api/status')).body.player.track.id,'2');
 assert.equal((await f.request('/api/control',{action:'play',source:'search',trackId:'3'})).status,400);
 assert.equal((await f.request('/api/search?q=&limit=2')).status,400);
});
test('设置严格校验、持久化；模式真实控制ended；不支持项明确拒绝',async t=>{
 const f=await setup(t);await f.play();
 const original=(await f.request('/api/settings')).body;assert.equal(original.settings.player.openKey,0);assert.notEqual(original.schema.player.envCave.supported,false);
 const update=await f.request('/api/settings',{lyrics:{scale:1.5,textColor:0x112233},card:{posX:.2},player:{volume:.4}});
 assert.equal(update.body.settings.lyrics.scale,1.5);assert.equal(update.body.settingsRevision,1);
 assert.equal((await f.request('/api/settings',{lyrics:{unknown:true}})).status,422);
 assert.equal((await f.request('/api/settings',{lyrics:{scale:5}})).status,422);
 assert.equal((await f.request('/api/settings',{lyrics:{danceAuto:true}})).status,422);
 assert.equal((await f.request('/api/settings',{player:{shuffle:true,repeatOne:true}})).status,422);
 const loaded=await createSettingsStore(resolve(f.dir,'state'));assert.equal(loaded.read().settings.lyrics.textColor,0x112233);assert.equal(loaded.read().settingsRevision,1);
 await f.request('/api/control',{action:'mode',value:'single'});
 let status=(await f.request('/api/status')).body;assert.equal(status.mode,'single');assert.equal(status.settingsRevision,2);
 await f.request('/api/player/report',{clientId,revision:status.revision,position:200,duration:200,playing:false,ended:true});
 assert.equal((await f.request('/api/status')).body.player.track.id,'1');
 await f.request('/api/control',{action:'mode',value:'shuffle'});await f.request('/api/control',{action:'next'});
 status=(await f.request('/api/status')).body;assert.equal(status.mode,'shuffle');assert.notEqual(status.player.track.id,'1');
});
test('状态外推仅在连接正常且播放中；音量命令不重定位；native租约拒浏览器抢占',async t=>{
 const native='native_test_player';
 const f=await setup(t,{songUrl:async id=>({url:`https://m1.music.126.net/${id}`,gainDb:-6,peak:1,expires:999999})});
 await f.login();await f.request('/api/player/claim',{clientId:native});await f.request('/api/control',{action:'play',playlistId:'1',trackId:'1'});
 await f.request('/api/player/report',{clientId:native,revision:1,position:10,duration:200,playing:true});f.setTime(100500);
 let status=(await f.request('/api/status')).body;assert.equal(status.playerEngine,'native');assert.equal(status.sampledAt,100500);assert.equal(status.player.position,10.5);
 const before=(await f.request('/api/player/state?clientId='+native)).body.desired;
 await f.request('/api/control',{action:'volume',value:.5});f.setTime(100700);
 status=(await f.request('/api/status')).body;assert.equal(status.player.position,10.7);assert.equal(status.player.volume,.5);
 const after=(await f.request('/api/player/state?clientId='+native)).body.desired;assert.equal(after.seekRevision,before.seekRevision);assert.equal(after.position,before.position);assert.ok(Math.abs(after.volume-.5*Math.pow(10,-6/20))<1e-9);
 assert.equal((await f.claim()).status,409);
 await f.request('/api/player/report',{clientId:native,revision:after.revision,position:12,duration:200,playing:true,error:'error raw secret'});f.setTime(101000);
 assert.equal((await f.request('/api/status')).body.player.position,12);
 f.setTime(120000);status=(await f.request('/api/status')).body;assert.equal(status.player.position,12);assert.equal(status.player.playing,false);
});
test('歌词卡片动态岛总开关可持久化，未实现的生物舞蹈字段不可调',async t=>{
 const f=await setup(t);
 const initial=(await f.request('/api/settings')).body;
 for(const group of ['lyrics','card','island'])assert.equal(initial.settings[group].enabled,true);
 const updated=await f.request('/api/settings',{lyrics:{enabled:false},card:{enabled:false},island:{enabled:false}});
 assert.equal(updated.status,200);
 const reloaded=(await createSettingsStore(resolve(f.dir,'state'))).read();
 for(const group of ['lyrics','card','island'])assert.equal(reloaded.settings[group].enabled,false);
 assert.equal(initial.schema.player.language.supported,false);
 assert.equal((await f.request('/api/settings',{player:{language:1}})).status,422);
 for(const [key,value]of Object.entries({dance:true,danceAuto:true,danceTap:true,danceSpin:true,danceAmount:1.5,danceOffset:5,danceBpm:130})) {
  assert.equal(initial.schema.lyrics[key].supported,false);assert.ok(initial.schema.lyrics[key].reason);
  const result=await f.request('/api/settings',{lyrics:{[key]:value}});assert.equal(result.status,422);
 }
});
test('环境遥测严格鉴权与字段验证，5秒失效，开关与强度进入原生DSP且不改进度',async t=>{
 const f=await setup(t);await f.play();
 const state=async()=>(await f.request('/api/player/state?clientId='+clientId)).body.desired;
 const initial=await state();assert.deepEqual(initial.audio.env,{enabled:true,water:false,cave:false,indoor:false,rain:0,region:'surface',strength:1});
 const telemetry={water:true,cave:true,indoor:true,rain:.75};
 assert.equal((await fetch(f.base+'/api/environment',{method:'POST',body:JSON.stringify(telemetry)})).status,401);
 assert.equal((await f.request('/api/environment',telemetry,{Origin:'https://evil.example'})).status,403);
 for(const bad of [{water:true,cave:false,rain:0},{...telemetry,extra:1},{...telemetry,water:1},{...telemetry,rain:true},{...telemetry,rain:1.1}])assert.equal((await f.request('/api/environment',bad)).status,400);
 const posted=await f.request('/api/environment',telemetry);assert.equal(posted.body.expiresAt,105000);
 let desired=await state();assert.deepEqual(desired.audio.env,{enabled:true,...telemetry,region:'cave',strength:1});assert.equal(desired.revision,initial.revision);assert.equal(desired.seekRevision,initial.seekRevision);assert.equal(desired.position,initial.position);
 f.setTime(104999);assert.equal((await state()).audio.env.water,true);
 f.setTime(105000);assert.deepEqual((await state()).audio.env,{enabled:true,water:false,cave:false,indoor:false,rain:0,region:'surface',strength:1});
 await f.request('/api/environment',telemetry);
 const patched=await f.request('/api/settings',{player:{envAudio:false,envWater:false,envCave:false,envIndoor:false,envRain:false,envStrength:.4}});assert.equal(patched.status,200);
 desired=await state();assert.deepEqual(desired.audio.env,{enabled:false,water:false,cave:false,indoor:false,rain:0,region:'surface',strength:.4});assert.equal(desired.seekRevision,initial.seekRevision);
 assert.equal((await f.request('/api/settings',{player:{envStrength:2}})).status,422);
});

test('地区预设分别开关、雨独立叠加，旧客户端兼容及失联回退',async t=>{
 const f=await setup(t);await f.play();
 const state=async()=>(await f.request('/api/player/state?clientId='+clientId)).body.desired;
 const initial=await state();
 const switches={lunar:'envLunar',ocean:'envOcean',ruins:'envRuins',atrium:'envAtrium',forest:'envForest'};
 for(const [region,key] of Object.entries(switches)) {
  const cave=['ruins','atrium'].includes(region),telemetry={water:false,cave,indoor:false,rain:.7,region};
  assert.equal((await f.request('/api/environment',telemetry)).status,200);
  let desired=await state();assert.equal(desired.audio.env.region,region);assert.equal(desired.audio.env.rain,.7);
  assert.equal(desired.seekRevision,initial.seekRevision);assert.equal(desired.revision,initial.revision);
  await f.request('/api/settings',{player:{[key]:false}});
  desired=await state();assert.equal(desired.audio.env.region,cave?'cave':'surface');assert.equal(desired.audio.env.rain,.7);
  if(cave) {
   await f.request('/api/settings',{player:{envCave:false}});
   assert.equal((await state()).audio.env.region,'surface');
   await f.request('/api/settings',{player:{[key]:true}});
   assert.equal((await state()).audio.env.region,region,'specific underground profile is independently enabled');
   await f.request('/api/settings',{player:{envCave:true}});
  }
  await f.request('/api/settings',{player:{[key]:true,envRain:false}});
  desired=await state();assert.equal(desired.audio.env.region,region);assert.equal(desired.audio.env.rain,0);
  await f.request('/api/settings',{player:{envRain:true}});
 }
 const valid={water:false,cave:false,indoor:false,rain:.7,region:'lunar'};
 await f.request('/api/environment',valid);
 for(const patch of [{region:'unknown'},{region:'__proto__'},{region:null},{region:4},{region:'atrium'},{cave:true},{extra:true}]) {
  assert.equal((await f.request('/api/environment',{...valid,...patch})).status,400);
  assert.equal((await state()).audio.env.region,'lunar','invalid sample cannot replace last valid environment');
 }
 f.setTime(105000);
 assert.equal((await state()).audio.env.region,'surface');assert.equal((await state()).audio.env.rain,0);
 await f.request('/api/environment',{water:false,cave:true,indoor:false,rain:0});
 assert.equal((await state()).audio.env.region,'cave');
 const stored=(await createSettingsStore(resolve(f.dir,'state'))).read().settings;
 for(const key of Object.values(switches))assert.equal(stored.player[key],true);
});
test('归一化回退遵循增益边界与peak余量，native保留未归一化baseVolume避免双应用',async t=>{
 const f=await setup(t,{songUrl:async id=>({url:`https://m1.music.126.net/${id}`,gainDb:20,peak:2,expires:999999})});await f.play();
 const desired=(await f.request('/api/player/state?clientId='+clientId)).body.desired;
 assert.equal(desired.audio.baseVolume,.7);assert.equal(desired.audio.gainDb,20);assert.equal(desired.audio.peak,2);assert.equal(desired.audio.normalize,true);assert.ok(Math.abs(desired.volume-.7*.98/2)<1e-9);
});

test('原生播放错误保留当前音频下载原因，换歌后不沿用旧错，未知内容不外泄',async t=>{
 const f=await setup(t,{openMedia:async()=>{throw Object.assign(new Error('音频域名解析失败，请检查代理或网络后重试'),{status:502});}});
 const native='native_error_fixture';await f.login();await f.request('/api/player/claim',{clientId:native});
 await f.request('/api/control',{action:'play',playlistId:'1',trackId:'1'});
 const sendError=async(error='secret URL and token')=>{
  const s=(await f.request('/api/status')).body;
  await f.request('/api/player/report',{clientId:native,revision:s.revision,position:0,duration:0,playing:false,error});
  return (await f.request('/api/status')).body.player.error;
 };
 const state=async()=>(await f.request('/api/player/state?clientId='+native)).body.desired;
 assert.equal((await f.request('/api/media?trackId=1')).status,502);
 assert.match(await sendError(),/音频域名解析失败/);
 const failed=await state();
 await f.request('/api/control',{action:'volume',value:.3});
 await f.request('/api/control',{action:'resume'});
 const retry=await state();
 assert.equal(retry.seekRevision,failed.seekRevision+1);assert.equal(retry.playing,true);
 await f.request('/api/control',{action:'resume'});
 assert.equal((await state()).seekRevision,retry.seekRevision);
 await f.request('/api/control',{action:'next'});
 const next=await state();
 await f.request('/api/player/report',{clientId:native,revision:retry.revision,position:0,duration:0,playing:false,error:'Native media HTTP failed'});
 assert.equal((await f.request('/api/status')).body.player.error,null);
 await f.request('/api/control',{action:'resume'});
 assert.equal((await state()).seekRevision,next.seekRevision);
 const message=await sendError();assert.match(message,/本机音频播放失败/);assert.doesNotMatch(message,/域名|secret|浏览器/);
 assert.equal(await sendError('Native media HTTP failed'),'音频下载失败，请重试或检查网络');
});
test('仅扫码开始与退出兼容旧DST空表编码[]，其它数组和端点仍拒绝',async t=>{
 const f=await setup(t);
 const send=async(path,value)=>{
  const response=await fetch(f.base+path,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(value)});
  return{status:response.status,body:await response.json()};
 };
 const start=await send('/api/login/start',[]);assert.equal(start.status,200);assert.equal(start.body.key,'test-key');
 await f.request('/api/login/check?key=test-key');assert.ok((await f.request('/api/status')).body.account);
 assert.equal((await send('/api/logout',[])).status,200);assert.equal((await f.request('/api/status')).body.account,null);
 for(const path of ['/api/login/start','/api/logout'])for(const value of [[{}],[1],null,''])assert.equal((await send(path,value)).status,400);
 for(const path of ['/api/control','/api/settings','/api/environment','/api/player/claim','/api/player/report'])assert.equal((await send(path,[])).status,400);
 assert.equal((await f.request('/api/login/start',{})).status,200);
});

test('更新路由只读缓存、校验凭据和参数，并为游戏交付异步收据',async t=>{
 let calls=0,respond;
 const pending=new Promise(resolve=>{respond=resolve;});
 const f=await setup(t,{}, {updateFetch:async url=>{
  calls++;
  assert.equal(url,UPDATE_SOURCE.apiUrl);
  return pending;
 }},async dir=>{
  await Promise.all(['mod','state'].map(name=>mkdir(resolve(dir,name))));
  await Promise.all([
   writeFile(resolve(dir,'mod/music_workshop_identity.json'),'\ufeff'+JSON.stringify({schema:1,id:'zcc-dst-music',version:'0.6.0-beta.2'})),
   writeFile(resolve(dir,'state/settings.json'),JSON.stringify({settings:{player:{checkUpdates:false}},revision:7})),
  ]);
 });
 const initial=await f.request('/api/updates');
 assert.deepEqual(initial.body,{ok:true,status:'idle',currentVersion:'0.6.0-beta.2',channel:'beta',latest:null,checkedAt:null,stale:false,error:null,source:UPDATE_SOURCE});
 assert.equal((await f.request('/api/updates/check',{}, {Authorization:''})).status,401);
 assert.equal((await f.request('/api/updates/check',{url:'https://external.invalid'})).status,400);
 assert.equal((await f.request('/api/updates')).body.status,'idle');
 assert.equal(calls,0,'persisted opt-out and cache reads must not fetch');
 const receipt=await f.request('/api/updates/check?gameAsync=1',{});
 assert.equal(receipt.status,200);
 assert.equal(receipt.body.pending,true);
 const endpoint='/api/request/result?id='+receipt.body.requestId;
 assert.equal((await f.request(endpoint)).body.pending,true);
 assert.equal((await f.request('/api/updates')).body.status,'checking');
 respond(Response.json([{tag_name:'v0.6.0-beta.10',draft:false,prerelease:true}]));
 const done=(await f.request(endpoint)).body;
 assert.equal(done.pending,false);
 assert.equal(done.response.status,'available');
 assert.equal(done.response.latest.version,'0.6.0-beta.10');
 assert.deepEqual((await f.request('/api/updates')).body,done.response);
 assert.equal(calls,1);
});

test('自动更新按开关启动和重复检查，关闭服务清理计时并中止进行中的请求',async t=>{
 const requests=[];
 let nextRequest;
 const f=await setup(t,{}, {
  currentVersion:'0.6.0',updateIntervalMs:150,updateMinIntervalMs:0,
  updateFetch:async (_url,{signal})=>{
   requests.push(signal);
   nextRequest?.();
   return requests.length===3?new Promise(()=>{}):Response.json([]);
  },
 });
 const startup=await f.request('/api/settings');
 assert.equal(startup.body.settings.player.checkUpdates,true);
 assert.equal(startup.body.schema.player.checkUpdates.consumer,'backend');
 assert.equal(requests.length,1);
 assert.equal((await f.request('/api/updates')).body.currentVersion,'0.6.0');
 assert.equal((await f.request('/api/settings',{player:{checkUpdates:false}})).body.settings.player.checkUpdates,false);
 f.setTime(100_150);
 await delay(190);
 assert.equal(requests.length,1);
 assert.equal((await f.request('/api/settings',{player:{checkUpdates:true}})).body.settings.player.checkUpdates,true);
 assert.equal(requests.length,2);
 f.setTime(100_300);
 await Promise.race([new Promise(resolve=>{nextRequest=resolve;}),delay(1500,undefined,{ref:false})]);
 assert.equal(requests.length,3,'automatic timer repeats a check');
 assert.equal(requests[2].aborted,false);
 await f.close();
 assert.equal(requests[2].aborted,true);
 await delay(190);
 assert.equal(requests.length,3);
});

test('模组目录接口回传实际打开和前台状态',async t=>{
 let opens=0;
 const f=await setup(t,{}, {openModFolder:async()=>({opened:true,focused:++opens===2})});
 assert.deepEqual((await f.request('/api/local/open-mod-folder',{})).body,{ok:true,opened:true,focused:false});
 assert.deepEqual((await f.request('/api/open-mod-folder',{})).body,{ok:true,opened:true,focused:true});
 assert.equal((await f.request('/api/local/open-mod-folder',{path:'C:/other'})).status,400);
 assert.equal(opens,2);
});
