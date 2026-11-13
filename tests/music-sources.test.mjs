import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Readable,PassThrough} from 'node:stream';
import {createBridge} from '../helper/server.mjs';
import {musicId} from '../helper/music-source.mjs';

const token='test_music_sources_'.padEnd(64,'a'),clientId='native_sources_test';
async function fixture(t,overrides={}) {
  const dir=await mkdtemp(join(tmpdir(),'music-sources-')),calls=[];
  let now=1000;
  const sources=Object.fromEntries(['netease','qq'].map(provider=>{
    const id=provider==='qq'?'qq:1':'1',listId=provider==='qq'?'qq:playlist:1':'1';
    const track={id,name:provider,artists:'test',duration:60,cover:provider==='qq'?'https://y.gtimg.cn/music/photo_new/test.jpg':'https://p1.music.126.net/test.jpg'};
    return [provider,{
      startLogin:async()=>({key:provider+'-qr',...(provider==='qq'?{image:Buffer.from('test-png')}:{url:'https://music.163.com/login?codekey=netease-qr'})}),
      checkLogin:async()=>({status:'success',cookie:provider==='qq'?{uin:'1',key:'fake-qq-key',loginType:2}:'MUSIC_U=fake-netease'}),
      account:async()=>({id:'1',nickname:provider}),
      playlists:async(cookie)=>{calls.push([provider,'lists',cookie]);return[{id:listId,name:provider,trackCount:1}];},
      playlist:async()=>[track],
      search:async()=>({tracks:[track],total:1}),
      discover:async()=>[{id:listId,name:provider,trackCount:1}],
      lyrics:async()=>provider==='qq'?{timing:'word',lines:[{start:1,end:2,text:'q',words:[{start:1,end:2,text:'q'}]}]}:{lrc:{lyric:'[00:01]n'}},
      songUrl:async(id,cookie)=>{calls.push([provider,'url',id,cookie]);return{url:provider==='qq'?'https://isure.stream.qqmusic.qq.com/q.mp3':'https://m1.music.126.net/n.mp3',trial:false,expires:now+100};},
      validateMediaUrl:value=>{assert.equal(new URL(value).hostname,provider==='qq'?'isure.stream.qqmusic.qq.com':'m1.music.126.net');return new URL(value);},
      openMedia:async()=>Object.assign(Readable.from([provider]),{statusCode:200,headers:{'content-type':'audio/mpeg'}}),
      cancelLogin:key=>calls.push([provider,'cancel',key]),close:()=>{},
      ...(overrides[provider]||{}),
    }];
  }));
  const bridge=await createBridge({stateDir:join(dir,'state'),modDir:join(dir,'mod'),token,upstream:sources.netease,providers:{qq:sources.qq},now:()=>now,
    assets:{cover:async(id)=>({atlas:id,image:id}),qrImage:async()=>({atlas:'qq-qr',image:'qq-qr'}),qr:async()=>({atlas:'netease-qr',image:'netease-qr'})}});
  const port=await bridge.listen(0),base=`http://127.0.0.1:${port}`;
  t.after(async()=>{await bridge.close();await rm(dir,{recursive:true,force:true});});
  const raw=(path,data)=>fetch(base+path,{method:data===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`},...(data===undefined?{}:{body:JSON.stringify(data)})});
  const request=async(path,data)=>{const r=await raw(path,data);return{status:r.status,body:await r.json()};};
  const login=async provider=>{await request('/api/login/start',{provider});return request('/api/login/check?key='+provider+'-qr');};
  const play=async provider=>{await request('/api/search?q=test&provider='+provider);return request('/api/control',{action:'play',source:'search',trackId:provider==='qq'?'qq:1':'1'});};
  await request('/api/player/claim',{clientId});
  return{dir,raw,request,login,play,calls,tick:n=>now+=n};
}

test('来源ID校验保持网易云兼容并拒绝路径、超长或未知来源',()=>{
  for(const id of ['1','9007199254740991','qq:001abcXYZ','qq:playlist:123','qq:chart:26','qq:liked:123'])assert.equal(musicId(id),id);
  for(const id of ['0','9007199254740992','qq:','qq:../file','qq:chart:-1','qq:playlist:0','qq:'+'x'.repeat(65),'kugou:1'])assert.throws(()=>musicId(id));
});

test('两来源独立登录、同号曲库与歌词隔离，QQ图片扫码不暴露凭据',async t=>{
  const f=await fixture(t);
  const start=await f.request('/api/login/start',{provider:'qq'});
  assert.deepEqual(start.body,{ok:true,key:'qq-qr',provider:'qq'});
  assert.equal((await f.request('/api/login/artwork?key=qq-qr')).body.asset.image,'qq-qr');
  assert.equal(await(await f.raw('/api/login/image?key=qq-qr')).text(),'test-png');
  await f.login('netease');await f.login('qq');
  for(const provider of ['netease','qq']) {
    const status=(await f.request('/api/status?provider='+provider)).body;
    assert.equal(status.provider,provider);assert.equal(status.account.nickname,provider);
    assert.doesNotMatch(JSON.stringify(status),/fake-|qqmusic_key|MUSIC_U/);
    assert.equal((await f.request('/api/playlists?provider='+provider)).body.playlists[0].name,provider);
    await f.request('/api/search?q=x&provider='+provider);
  }
  assert.equal((await f.request('/api/lyrics?trackId=1')).body.lines[0].text,'n');
  assert.equal((await f.request('/api/lyrics?trackId=qq:1')).body.lines[0].text,'q');
  assert.equal((await f.request('/api/artwork?trackId=1')).body.asset.image,'1');
  assert.equal((await f.request('/api/artwork?trackId=qq:1')).body.asset.image,'qq:1');
  assert.equal(JSON.parse(await readFile(join(f.dir,'state/account.json'),'utf8')).account.nickname,'netease');
  assert.equal(JSON.parse(await readFile(join(f.dir,'state/account-qq.json'),'utf8')).account.nickname,'qq');
});

test('切浏览来源后原歌曲续签、歌词与队列仍属于原音源',async t=>{
  const f=await fixture(t);await f.login('netease');await f.login('qq');await f.play('netease');
  const before=(await f.request('/api/player/state?clientId='+clientId)).body;
  const queue=(await f.request('/api/queue')).body;
  assert.equal((await f.request('/api/settings',{player:{musicSource:1}})).status,200);
  assert.equal((await f.request('/api/status')).body.provider,'qq');
  assert.deepEqual((await f.request('/api/player/state?clientId='+clientId)).body,before);
  assert.deepEqual((await f.request('/api/queue')).body,queue);
  f.tick(101);
  const media=await f.raw('/api/media?trackId=1');assert.equal(await media.text(),'netease');
  assert.equal(f.calls.filter(x=>x[1]==='url').at(-1)[0],'netease');
  await f.request('/api/logout',{provider:'qq'});
  assert.deepEqual((await f.request('/api/player/state?clientId='+clientId)).body,before);
  assert.equal((await f.request('/api/status?provider=netease')).body.account.nickname,'netease');
});

test('QQ选择失败保留原曲，退出当前音源暂停清理并保留另一来源登录',async t=>{
  let reject=true;
  const f=await fixture(t,{qq:{songUrl:async()=>{if(reject)throw Object.assign(new Error('此曲需要会员权限'),{status:403});return{url:'https://isure.stream.qqmusic.qq.com/q.mp3',expires:999999};}}});
  await f.login('netease');await f.login('qq');await f.play('netease');
  const before=(await f.request('/api/queue')).body;
  assert.equal((await f.play('qq')).status,403);assert.deepEqual((await f.request('/api/queue')).body,before);
  assert.equal((await f.request('/api/status')).body.player.track.id,'1');
  reject=false;await f.play('qq');await f.request('/api/logout',{provider:'qq'});
  const status=(await f.request('/api/status?provider=qq')).body;
  assert.equal(status.account,null);assert.equal(status.player.track,null);assert.equal(status.player.playing,false);
  assert.equal((await f.request('/api/status?provider=netease')).body.account.nickname,'netease');
});

test('待完成搜索在账号退出后不写回旧缓存，取消扫码只关闭指定会话',async t=>{
  let resolveSearch,entered;
  const started=new Promise(r=>entered=r),waiting=new Promise(r=>resolveSearch=r);
  const f=await fixture(t,{qq:{search:async()=>{entered();await waiting;return{tracks:[{id:'qq:1',name:'old',artists:'x',duration:30}],total:1};}}});
  await f.login('qq');
  const search=f.request('/api/search?q=x&provider=qq');await started;
  await f.request('/api/logout',{provider:'qq'});resolveSearch();assert.equal((await search).status,409);
  assert.equal((await f.request('/api/control',{action:'play',source:'search',trackId:'qq:1'})).status,400);
  await f.request('/api/login/start',{provider:'qq'});await f.request('/api/login/start',{provider:'netease'});
  assert.equal((await f.request('/api/login/cancel',{key:'qq-qr',provider:'netease'})).status,400);
  assert.equal((await f.request('/api/login/cancel',{key:'qq-qr',provider:'qq'})).status,200);
  assert.equal((await f.request('/api/login/cancel',{key:'qq-qr'})).status,200);
  assert.equal((await f.request('/api/login/check?key=qq-qr')).status,400);
  assert.equal((await f.request('/api/login/check?key=netease-qr')).body.status,'success');
});

for(const phase of ['checkLogin','account'])test(`取消QQ扫码后迟到的${phase}不得保存账号`,async t=>{
  let unblock,entered;
  const waiting=new Promise(r=>unblock=r),started=new Promise(r=>entered=r);
  const overrides={qq:{[phase]:async()=>{entered();await waiting;return phase==='checkLogin'?{status:'success',cookie:{uin:'1',key:'late-key',loginType:2}}:{id:'1',nickname:'late'};}}};
  const f=await fixture(t,overrides);
  await f.request('/api/login/start',{provider:'qq'});
  const pending=f.request('/api/login/check?key=qq-qr');await started;
  assert.equal((await f.request('/api/login/cancel',{key:'qq-qr',provider:'qq'})).status,200);
  unblock();assert.equal((await pending).status,409);
  assert.equal((await f.request('/api/status?provider=qq')).body.account,null);
  await assert.rejects(readFile(join(f.dir,'state/account-qq.json'),'utf8'),{code:'ENOENT'});
});

test('同曲重选试听后旧全曲续签不得覆盖新权限',async t=>{
  let count=0,entered,unblock;
  const waiting=new Promise(r=>unblock=r),started=new Promise(r=>entered=r);
  const f=await fixture(t,{qq:{songUrl:async()=>{
    const call=++count;
    if(call===2){entered();await waiting;}
    return{url:'https://isure.stream.qqmusic.qq.com/q.mp3',trial:call>=3,expires:call===1?1001:999999};
  }}});
  await f.play('qq');f.tick(2);
  const oldMedia=f.raw('/api/media?trackId=qq:1');await started;
  await f.play('qq');unblock();assert.equal((await oldMedia).status,410);
  assert.equal((await f.request('/api/status')).body.player.track.trial,true);
  assert.equal(await(await f.raw('/api/media?trackId=qq:1')).text(),'qq');
});

test('同次选择的并发续签可以共享结果，退出来源会关闭它的活动音频流',async t=>{
  let count=0,entered,unblock,liveStream=false;
  const waiting=new Promise(r=>unblock=r),started=new Promise(r=>entered=r),stream=new PassThrough();
  const f=await fixture(t,{qq:{songUrl:async()=>{
    const call=++count;if(call>1){if(call===3)entered();await waiting;}
    return{url:'https://isure.stream.qqmusic.qq.com/q.mp3',trial:false,expires:call===1?1001:999999};
  },openMedia:async()=>liveStream?Object.assign(stream,{statusCode:200,headers:{'content-type':'audio/mpeg'}}):Object.assign(Readable.from(['qq']),{statusCode:200,headers:{'content-type':'audio/mpeg'}})}});
  await f.play('qq');f.tick(2);
  const a=f.raw('/api/media?trackId=qq:1'),b=f.raw('/api/media?trackId=qq:1');await started;unblock();
  for(const result of await Promise.all([a,b])){assert.equal(result.status,200);assert.equal(await result.text(),'qq');}
  liveStream=true;
  const response=f.raw('/api/media?trackId=qq:1');stream.write('first');
  const reader=(await response).body.getReader();await reader.read();
  await f.request('/api/logout',{provider:'qq'});
  await assert.rejects(reader.read());assert.equal(stream.destroyed,true);
});
