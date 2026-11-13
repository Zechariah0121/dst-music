import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createBridge} from '../helper/server.mjs';

const token='game_request_integration_token_123456789';
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};

async function fixture(t,qq,options={}) {
  const dir=await mkdtemp(join(tmpdir(),'dst-game-request-'));
  const bridge=await createBridge({stateDir:join(dir,'state'),modDir:join(dir,'mod'),token,providers:{qq},...options});
  const port=await bridge.listen(0),base=`http://127.0.0.1:${port}`;
  t.after(async()=>{await bridge.close();await rm(dir,{recursive:true,force:true});});
  const raw=(path,data,authenticated=true)=>fetch(base+path,{method:data===undefined?'GET':'POST',
    headers:authenticated?{Authorization:`Bearer ${token}`}:{},...(data===undefined?{}:{body:JSON.stringify(data)})});
  const call=async(path,data,auth)=>{const r=await raw(path,data,auth);return {status:r.status,body:await r.json()};};
  return {call};
}

test('游戏慢请求先返回收据，轮询鉴权且保留原结果，快速状态不受影响',async t=>{
  const search=deferred();
  const f=await fixture(t,{search:()=>search.promise});
  const initial=await f.call('/api/search?provider=qq&q=test&gameAsync=1');
  assert.equal(initial.status,200);
  assert.equal(initial.body.pending,true);
  assert.match(initial.body.requestId,/^[a-f0-9]{32}$/);
  const endpoint='/api/request/result?id='+initial.body.requestId;
  assert.equal((await f.call(endpoint,undefined,false)).status,401);
  assert.equal((await f.call(endpoint)).body.pending,true);
  assert.equal((await f.call('/api/status?provider=qq')).body.provider,'qq');
  search.resolve({tracks:[{id:'qq:track1',name:'测试',artists:'测试',duration:60}],total:1});
  const result=await f.call(endpoint);
  assert.equal(result.body.pending,false);
  assert.equal(result.body.status,200);
  assert.equal(result.body.response.tracks[0].id,'qq:track1');
  assert.deepEqual((await f.call(endpoint)).body,result.body);
});

test('打开模组目录必须鉴权且不能传入路径，隐藏入口设置可持久读取',async t=>{
  let opened=0;
  const f=await fixture(t,{}, {openModFolder:async()=>{opened++;}});
  assert.equal((await f.call('/api/open-mod-folder',{},false)).status,401);
  assert.equal((await f.call('/api/open-mod-folder',{path:'C:/other'})).status,400);
  assert.equal(opened,0);
  assert.equal((await f.call('/api/open-mod-folder',{})).body.ok,true);
  assert.equal(opened,1);
  const changed=await f.call('/api/settings',{player:{showTopLeftButton:false}});
  assert.equal(changed.body.settings.player.showTopLeftButton,false);
  assert.equal((await f.call('/api/settings')).body.settings.player.showTopLeftButton,false);
});

test('游戏延迟错误保留业务状态，取消扫码收据会清理迟到二维码',async t=>{
  const search=deferred(),login=deferred(),cancelled=[];
  const f=await fixture(t,{search:()=>search.promise,startLogin:()=>login.promise,cancelLogin:key=>cancelled.push(key)});
  const [pendingSearch,pendingLogin]=await Promise.all([
    f.call('/api/search?provider=qq&q=test&gameAsync=1'),
    f.call('/api/login/start?gameAsync=1',{provider:'qq'}),
  ]);
  const searchId=pendingSearch.body.requestId,loginId=pendingLogin.body.requestId;
  search.reject(Object.assign(new Error('此版本当前不可播放'),{status:403}));
  const failed=await f.call('/api/request/result?id='+searchId);
  assert.equal(failed.status,200);
  assert.deepEqual(failed.body,{ok:true,pending:false,status:403,response:{ok:false,error:'此版本当前不可播放'}});
  assert.equal((await f.call('/api/request/cancel',{requestId:loginId})).body.ok,true);
  login.resolve({key:'late-private-qr',image:Buffer.from('test')});
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(cancelled.includes('late-private-qr'));
  assert.equal((await f.call('/api/request/result?id='+loginId)).status,410);
  assert.equal((await f.call('/api/login/image?key=late-private-qr')).status,404);
  assert.equal((await f.call('/api/request/cancel',{requestId:loginId})).body.ok,true);
});
