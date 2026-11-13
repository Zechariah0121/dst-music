import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {createMediaOpener} from '../helper/netease.mjs';
import {createPublicMediaResolver, qqMediaHostname} from '../helper/media-dns.mjs';

const host='m801.music.126.net';
const reply=(ip='1.1.1.1',ttl=60,name=host)=>new Response(JSON.stringify({Status:0,Question:[{name,type:1}],Answer:[{name,type:1,TTL:ttl,data:ip}]}));
const transport=onRequest=>(url,options,callback)=>{
 onRequest(url,options);
 const source=Object.assign(new PassThrough(),{statusCode:200,headers:{'content-type':'audio/mpeg'},setTimeout(){}});
 queueMicrotask(()=>callback(source));return new EventEmitter();
};

test('slow primary DNS is hedged, first valid answer wins, loser is cancelled and cached',async()=>{
 let primaryCancelled=false,queries=0;
 const resolve=createPublicMediaResolver({fetchImpl:async(url,{signal})=>{
  queries++;
  if(url.hostname==='dns.alidns.com')return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>{primaryCancelled=true;reject(signal.reason);},{once:true}));
  return reply();
 }});
 const start=performance.now();assert.deepEqual(await resolve(host),[{address:'1.1.1.1',family:4}]);
 assert.ok(performance.now()-start<1500,'a stalled primary must not impose its 8s timeout');
 assert.equal(queries,2);assert.equal(primaryCancelled,true);
 await resolve(host);assert.equal(queries,2);
});

test('fake-IP is resolved through HTTPS and the real address is pinned without changing TLS hostname or Range',async()=>{
 let requests=0,dnsQueries=0;
 const opener=createMediaOpener({lookupImpl:async()=>[{address:'198.18.1.200',family:4}],dnsFetchImpl:async(url,options)=>{
  dnsQueries++;assert.equal(url.hostname,'dns.alidns.com');assert.equal(url.searchParams.get('name'),host);
  assert.deepEqual([...url.searchParams.keys()],['name','type']);assert.equal(options.redirect,'error');
  assert.equal(options.credentials,'omit');
  assert.deepEqual(options.headers,{Accept:'application/dns-json'});return reply();
 },getImpl:transport((url,options)=>{
  requests++;assert.equal(url.hostname,host);assert.equal(options.headers.Range,'bytes=0-4095');
  options.lookup(host,{},(error,ip,family)=>{assert.equal(error,null);assert.equal(ip,'1.1.1.1');assert.equal(family,4);});
  options.lookup(host,{all:true},(error,addresses)=>assert.deepEqual(addresses,[{address:'1.1.1.1',family:4}]));
 })});
 for(let i=0;i<2;i++)(await opener('https://'+host+'/private-media-path','bytes=0-4095')).destroy();
 assert.equal(requests,2);assert.equal(dnsQueries,1,'short DNS cache avoids repeat lookups for range requests');
});

test('QQ fake-IP fallback only resolves its media CDN and rejects private replies', async () => {
 const names = ['stream.qqmusic.qq.com', 'dl.stream.qqmusic.qq.com'];
 const foreign = ['qq.com', 'y.qq.com', 'qqmusic.qq.com', 'notstream.qqmusic.qq.com',
  'stream.qqmusic.qq.com.example.com', 'stream.qqmusic.qq.com.', 'a..stream.qqmusic.qq.com', '-a.stream.qqmusic.qq.com'];
 let queries = 0;
 const resolve = createPublicMediaResolver({fetchImpl: async (url, options) => {
  queries++;
  const name = url.searchParams.get('name');
  assert.ok(names.includes(name));
  assert.deepEqual([...url.searchParams.keys()], ['name', 'type']);
  assert.deepEqual(options.headers, {Accept:'application/dns-json'});
  assert.equal(options.credentials, 'omit');
  return reply(name === names[0] ? '1.1.1.1' : '192.168.1.8', 60, name);
 }});
 for (const name of names) assert.equal(qqMediaHostname(name), true);
 assert.deepEqual(await resolve(names[0]), [{address:'1.1.1.1', family:4}]);
 await assert.rejects(() => resolve(names[1]), /域名解析失败/);
 assert.equal(queries, 3);
 for (const name of foreign) {
  assert.equal(qqMediaHostname(name), false);
  await assert.rejects(() => resolve(name), /域名解析失败/);
 }
 assert.equal(queries, 3);
});

test('custom media URL validation and fixed headers apply to every redirect while retaining Range and IP pinning', async () => {
 const first = 'stream.qqmusic.qq.com', next = 'dl.stream.qqmusic.qq.com';
 const validated = [], lookedUp = [], requests = [];
 const validateUrl = value => {
  const url = new URL(value);
  validated.push(url.hostname);
  if (url.protocol !== 'https:' || url.port || url.username || url.password || !qqMediaHostname(url.hostname)) {
   throw new Error('QQ audio source is not permitted');
  }
  return url;
 };
 const getImpl = (url, options, callback) => {
  requests.push([url.hostname, options.headers]);
  options.lookup(url.hostname, {}, (error, address, family) => {
   assert.equal(error, null);
   assert.equal(address, '1.1.1.1');
   assert.equal(family, 4);
  });
  const headers = url.pathname === '/redirect' ? {location:`https://${next}/audio`}
   : url.pathname === '/foreign' ? {location:'https://y.qq.com/media'}
   : url.pathname === '/private' ? {location:`https://private.${first}/audio`} : {};
  const source = Object.assign(new PassThrough(), {statusCode:headers.location ? 302 : 206, headers, setTimeout(){}});
  queueMicrotask(() => callback(source));
  return new EventEmitter();
 };
 const open = createMediaOpener({validateUrl, headers:{Referer:'https://y.qq.com/', range:'overridden'}, getImpl,
  lookupImpl:async name => {
   lookedUp.push(name);
   return [{address:name.startsWith('private.') ? '10.0.0.2' : '1.1.1.1', family:4}];
  },
 });
 const result = await open(`https://${first}/redirect`, 'bytes=2-6');
 assert.equal(result.statusCode, 206);
 result.destroy();
 const expectedHeaders = {Referer:'https://y.qq.com/', Range:'bytes=2-6'};
 assert.deepEqual(requests, [[first, expectedHeaders], [next, expectedHeaders]]);
 assert.deepEqual(validated, [first, next]);
 assert.deepEqual(lookedUp, [first, next]);
 await assert.rejects(() => open(`https://${first}/foreign`), /not permitted/);
 assert.equal(validated.at(-1), 'y.qq.com');
 assert.equal(lookedUp.at(-1), first);
 assert.deepEqual(requests.at(-1), [first, {Referer:'https://y.qq.com/'}]);
 await assert.rejects(() => open(`https://${first}/private`), /解析失败/);
 assert.equal(lookedUp.at(-1), `private.${first}`);
 assert.equal(requests.length, 4);
});

test('ordinary public DNS needs no fallback; private/mixed/invalid responses and foreign media hosts remain rejected',async()=>{
 let dnsQueries=0,connected=0;
 const options={dnsFetchImpl:async()=>{dnsQueries++;return reply();},getImpl:transport(()=>connected++)};
 (await createMediaOpener({...options,lookupImpl:async()=>[{address:'8.8.8.8',family:4}]})('https://'+host+'/a')).destroy();
 assert.equal(dnsQueries,0);assert.equal(connected,1);
 for(const addresses of [[],['127.0.0.1'],['10.0.0.1'],['198.18.1.200','127.0.0.1'],['1.1.1.1','192.168.1.1'],['999.2.3.4']]) {
  const open=createMediaOpener({...options,lookupImpl:async()=>addresses.map(address=>({address,family:4}))});
  await assert.rejects(()=>open('https://'+host+'/a'),/解析失败/);
 }
 await assert.rejects(()=>createMediaOpener(options)('https://example.com/a'),/许可范围/);
 assert.equal(dnsQueries,0);assert.equal(connected,1);
});

test('fallback validates DNS question and public answers, tries the second provider, bounds responses and expires TTL',async()=>{
 let time=0,queries=0;
 const resolve=createPublicMediaResolver({now:()=>time,fetchImpl:async url=>{queries++;return url.hostname==='dns.alidns.com'?reply('127.0.0.1'):reply('1.1.1.1',2);}});
 assert.deepEqual(await resolve(host),[{address:'1.1.1.1',family:4}]);assert.equal(queries,2);
 time=1999;await resolve(host);assert.equal(queries,2);
 time=2000;await resolve(host);assert.equal(queries,4);
 for(const response of [()=>reply('198.19.2.3'),()=>reply('1.1.1.1',60,'wrong.music.126.net'),()=>new Response('x'.repeat(65537)),()=>new Response('{}')]) {
  await assert.rejects(()=>createPublicMediaResolver({fetchImpl:async()=>response()})(host),/域名解析失败/);
 }
 let zeroQueries=0;
 const zero=createPublicMediaResolver({fetchImpl:async()=>{zeroQueries++;return reply('1.1.1.1',0);}});
 await zero(host);await zero(host);assert.equal(zeroQueries,2);
 let boundedQueries=0;
 const bounded=createPublicMediaResolver({fetchImpl:async url=>{boundedQueries++;return reply('1.1.1.1',60,url.searchParams.get('name'));}});
 for(let i=0;i<65;i++)await bounded('m'+i+'.music.126.net');
 await bounded('m0.music.126.net');assert.equal(boundedQueries,66,'resolver cache has a bounded 64-host budget');
});

test('aborted callers and the connection deadline cancel fallback without starting an audio connection',async()=>{
 let connected=0;
 const fetchImpl=async(_url,{signal})=>new Promise((resolve,reject)=>{
  if(signal.aborted)reject(signal.reason);else signal.addEventListener('abort',()=>reject(signal.reason),{once:true});
 });
 const controller=new AbortController();
 const resolve=createPublicMediaResolver({fetchImpl});const pending=resolve(host,controller.signal);controller.abort();
 await assert.rejects(pending);await assert.rejects(()=>resolve(host,controller.signal));
 const timer=setTimeout(()=>{},100);
 try {
  const open=createMediaOpener({lookupImpl:async()=>[{address:'198.18.1.1',family:4}],dnsFetchImpl:fetchImpl,connectTimeoutMs:10,getImpl:transport(()=>connected++)});
  await assert.rejects(()=>open('https://'+host+'/a'));assert.equal(connected,0);
 } finally {clearTimeout(timer);}
});
