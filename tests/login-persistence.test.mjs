import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm, writeFile, rename} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createBridge} from '../helper/server.mjs';
import {createNetease} from '../helper/netease.mjs';

const token = 'login_persistence_fixture_'.padEnd(64,'x');
const deferred = () => Promise.withResolvers();
async function fixture(t, options = {}) {
  const dir = await mkdtemp(join(tmpdir(),'music-login-'));
  const stateDir = join(dir,'state');
  const calls = [];
  let sequence = 0;
  const providers = Object.fromEntries(['netease','qq'].map(provider => [provider, {
    startLogin:async () => ({key:`${provider}-${++sequence}`,url:'https://music.163.com/login?codekey=fake'}),
    checkLogin:async key => {
      calls.push([provider,'check',key]);
      return {status:'success',cookie:provider==='qq' ? {uin:'123',key:'fake-qq',loginType:2} : 'MUSIC_U=fake-netease'};
    },
    account:async () => ({id:'123',nickname:provider}),
    cancelLogin:key => calls.push([provider,'cancel',key]),
    close:() => {},
    ...options[provider],
  }]));
  let bridge, base;
  async function start() {
    bridge = await createBridge({stateDir,modDir:join(dir,'mod'),token,upstream:providers.netease,providers:{qq:providers.qq},saveAccount:options.saveAccount});
    base = `http://127.0.0.1:${await bridge.listen(0)}`;
  }
  await start();
  t.after(async () => {await bridge.close();await rm(dir,{recursive:true,force:true});});
  async function call(path,data) {
    const response = await fetch(base+path,{method:data===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`},...(data===undefined?{}:{body:JSON.stringify(data)})});
    return {status:response.status,body:await response.json()};
  }
  const qr = async provider => (await call('/api/login/start',{provider})).body.key;
  return {calls,stateDir,call,qr,restart:async () => {await bridge.close();await start();}};
}

for (const provider of ['netease','qq']) {
  test(`${provider} 登录保存后跨服务重启恢复，重复轮询不再次消费凭据`,async t => {
    const f = await fixture(t);
    const key = await f.qr(provider);
    const first = await f.call('/api/login/check?key='+key);
    assert.equal(first.body.status,'success');
    assert.deepEqual(await f.call('/api/login/check?key='+key),first);
    assert.equal(f.calls.filter(row=>row[1]==='check').length,1);
    assert.equal((await f.call('/api/login/artwork?key='+key)).status,400);
    await f.restart();
    assert.deepEqual((await f.call('/api/status?provider='+provider)).body.account,{id:'123',nickname:provider});
    assert.equal(f.calls.filter(row=>row[1]==='check').length,1);
  });

  test(`${provider} 保存失败保留旧账号，同一码重试不假成功、不再次请求扫码结果`,async t => {
    let rejectSave = false, revision = 0;
    const f = await fixture(t,{
      [provider]:{account:async () => ({id:String(++revision),nickname:'revision-'+revision})},
      saveAccount:async (path,value) => {
        if(rejectSave)throw new Error('synthetic disk failure');
        await writeFile(path+'.tmp',JSON.stringify(value));await rename(path+'.tmp',path);
      },
    });
    await f.call('/api/login/check?key='+await f.qr(provider));
    const path = join(f.stateDir,provider==='qq'?'account-qq.json':'account.json');
    const before = await readFile(path,'utf8');
    const key = await f.qr(provider);
    rejectSave = true;
    const failed = await f.call('/api/login/check?key='+key);
    assert.equal(failed.status,507);assert.match(failed.body.error,/保存账号失败/);
    assert.equal((await f.call('/api/status?provider='+provider)).body.account.id,'1');
    assert.equal(await readFile(path,'utf8'),before);
    rejectSave = false;
    assert.equal((await f.call('/api/login/check?key='+key)).body.status,'success');
    assert.equal(f.calls.filter(row=>row[1]==='check' && row[2]===key).length,1);
    assert.equal(revision,2);
  });
}

test('重新扫码等待旧提交结束，旧成功轮询不能关闭或冒充新会话',async t => {
  const writing = deferred(), release = deferred();
  let saves = 0;
  const f = await fixture(t,{saveAccount:async (path,value) => {
    if(++saves===1){writing.resolve();await release.promise;}
    await writeFile(path+'.tmp',JSON.stringify(value));await rename(path+'.tmp',path);
  }});
  const oldKey = await f.qr('qq');
  const oldCheck = f.call('/api/login/check?key='+oldKey);
  await writing.promise;
  let newStarted = false;
  const nextQr = f.qr('qq').then(key => {newStarted=true;return key;});
  await new Promise(resolve=>setTimeout(resolve,40));
  assert.equal(newStarted,false);
  release.resolve();
  assert.equal((await oldCheck).body.status,'success');
  const newKey = await nextQr;
  assert.notEqual(newKey,oldKey);
  assert.equal((await f.call('/api/login/check?key='+oldKey)).status,400);
  assert.equal((await f.call('/api/login/check?key='+newKey)).body.status,'success');
});

test('账号读取暂时失败后保留扫码成功结果，只重试账号读取',async t => {
  let count = 0;
  const f = await fixture(t,{netease:{account:async () => {
    if(++count===1)throw Object.assign(new Error('账号暂不可用，请稍后重试'),{status:502});
    return {id:'123',nickname:'recovered'};
  }}});
  const key = await f.qr('netease');
  assert.equal((await f.call('/api/login/check?key='+key)).status,502);
  assert.equal((await f.call('/api/login/check?key='+key)).body.account.nickname,'recovered');
  assert.equal(f.calls.filter(row=>row[1]==='check').length,1);
});

test('网易云保留失效、限流和业务错误码，网络错误不泄露响应',async () => {
  for(const [code,status,pattern] of [[301,401,/登录已失效/],[401,401,/登录已失效/],[429,429,/过于频繁/],[509,502,/错误码 509/]]) {
    let calls = 0;
    const api = createNetease({fetchImpl:async () => {calls++;return Response.json({code,message:'MUSIC_U=private'});}});
    await assert.rejects(api.account('MUSIC_U=fake'),error => error.status===status && pattern.test(error.message) && !error.message.includes('private'));
    assert.equal(calls,1);
  }
  const api = createNetease({fetchImpl:async () => {throw Object.assign(new Error('private'),{status:401});}});
  await assert.rejects(api.account('MUSIC_U=fake'),error => error.status===502 && !error.message.includes('private'));
});

test('网易云扫码仅在有效 MUSIC_U 返回后成功，空凭据不伪装成登录过期',async () => {
  for(const [value,success] of [['MUSIC_U=fixture-value; Path=/',true],['MUSIC_U=; Path=/',false]]) {
    const api = createNetease({fetchImpl:async () => Response.json({code:803},{headers:{'Set-Cookie':value}})});
    if(success)assert.equal((await api.checkLogin('test-key')).cookie,'MUSIC_U=fixture-value');
    else await assert.rejects(api.checkLogin('test-key'),error => error.status===502 && /未返回有效登录凭据/.test(error.message));
  }
});
