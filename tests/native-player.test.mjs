// Real native/STA playback against a wholly isolated loopback mock. No accounts,
// NetEase traffic, browser, production state, or real music are involved.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {Readable} from 'node:stream';
import {setTimeout as delay} from 'node:timers/promises';
import {createBridge} from '../helper/server.mjs';

const token = 'native_fixture_only_not_a_real_secret';
const powershell = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
function wave(seconds) {
  const bytes = Buffer.alloc(44 + 16000 * seconds);
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8);
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22);
  bytes.writeUInt32LE(8000, 24); bytes.writeUInt32LE(16000, 28); bytes.writeUInt16LE(2, 32);
  bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(bytes.length - 44, 40);
  return bytes;
}
async function until(predicate, label, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) { if (predicate()) return; await delay(50); }
  assert.fail(`Timed out: ${label}`);
}
for (const codec of ['wav','mp3']) test(`native ${codec} worker claims, plays, pauses, seeks, ends, reports failure, and exits without backend`, {skip:process.platform !== 'win32', timeout:60000}, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dango-native-test-'));
  const audio = codec === 'wav' ? wave(8) : await readFile(new URL('./native-player-silence.mp3',import.meta.url)), reports = [];
  let claimed = '', mediaRequests = 0, delayReports = false;
  let desired = {revision:0, seekRevision:0, track:null, mediaUrl:null, playing:false, volume:0, position:0};
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if ((req.headers.authorization !== `Bearer ${token}`) && url.searchParams.get('token') !== token) { res.writeHead(401); res.end('{}'); return; }
    if (url.pathname === '/api/media') {
      mediaRequests++;
      if (url.searchParams.get('trackId') === '9') { res.writeHead(500); res.end(); return; }
      let start = 0, end = audio.length - 1;
      const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '');
      if (range) { start = +range[1]; if (range[2]) end = Math.min(end, +range[2]); }
      res.writeHead(range ? 206 : 200, {'content-type':codec === 'wav'?'audio/wav':'audio/mpeg','content-length':end-start+1,'accept-ranges':'bytes',...(range?{'content-range':`bytes ${start}-${end}/${audio.length}`}:{})});
      res.end(audio.subarray(start,end+1)); return;
    }
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString() || '{}');
    const json = value => { res.writeHead(200, {'content-type':'application/json'}); res.end(JSON.stringify(value)); };
    if (url.pathname === '/api/player/claim') { claimed = body.clientId; json({ok:true}); }
    else if (url.pathname === '/api/player/state') json({ok:true, desired});
    else if (url.pathname === '/api/player/report') {
      assert.equal(body.clientId, claimed); reports.push({...body, at:Date.now()});
      if (delayReports) await delay(1000);
      json({ok:true});
    } else { res.writeHead(404); res.end('{}'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await writeFile(join(dir, 'bridge.json'), JSON.stringify({host:'127.0.0.1', port, token}));
  const child = spawn(powershell, ['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',resolve('helper/NativePlayer.ps1'),'-StateDir',dir,'-ParentProcessId',String(process.pid),'-MaxUnavailableSeconds','3'], {windowsHide:true});
  let output = '', exitCode = null, exited = false;
  child.stdout.on('data', data => output += data); child.stderr.on('data', data => output += data);
  child.on('exit', code => { exited = true; exitCode = code; });
  const latest = () => reports.at(-1);
  function change(patch) { desired = {...desired, ...patch, revision:desired.revision+1}; }
  try {
    await until(() => reports.length > 0 || exited, 'worker startup');
    assert.equal(exited, false, output);
    assert.match(claimed, /^native_[a-f0-9]{32}$/);
    await until(() => reports.some(report => typeof report.gameRunning === 'boolean'), 'native OS game presence included in reports');
    change({track:{id:'1'},mediaUrl:`/api/media?trackId=1&token=${token}`,playing:true,seekRevision:1});
    await until(() => latest()?.revision === 1 && latest().playing && latest().position > 0.4 && latest().duration >= 7.9, 'real MediaOpened and advancing playback');
    assert.ok(mediaRequests > 0);
    change({playing:false});
    await until(() => latest()?.revision === 2 && !latest().playing, 'pause');
    const paused = latest().position;
    await delay(900);
    assert.ok(Math.abs(latest().position-paused) < 0.15, 'paused clock remains still');
    change({position:4,seekRevision:2});
    await until(() => latest()?.revision === 3 && Math.abs(latest().position-4) < 0.2, 'seek while paused');
    delayReports = true;
    change({playing:true,volume:0,audio:{baseVolume:0,normalize:true,gainDb:6,peak:.8,env:{enabled:true,water:true,cave:true,indoor:true,rain:.8,strength:.6,...(codec==='mp3'?{region:'atrium'}:{})}}});
    await until(() => latest()?.revision === 4 && latest().position > 4.5, 'resume');
    const beforeSlowReport = latest().position;
    const beforeRegionMediaRequests=mediaRequests;
    // Environmental changes arrive without revision/seekRevision changes.
    desired={...desired,audio:{...desired.audio,env:{...desired.audio.env,water:false,cave:false,indoor:false,region:'forest'}}};
    await until(() => latest()?.position > beforeSlowReport + 0.65, 'STA keeps advancing during delayed HTTP reports');
    assert.equal(mediaRequests,beforeRegionMediaRequests,'regional transition must not reopen the audio stream');
    delayReports = false;
    change({position:7.6,seekRevision:3});
    await until(() => reports.some(r => r.revision === 5 && r.ended), 'MediaEnded report');
    change({track:{id:'9'},mediaUrl:`/api/media?trackId=9&token=${token}`,position:0,seekRevision:4});
    await until(() => latest()?.revision === 6 && !!latest().error && !latest().playing, 'MediaFailed report');
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    await until(() => exited, 'worker exits after sustained backend outage', 7000);
    assert.equal(exitCode, 0, output);
    assert.ok(!output.includes(token), 'never prints credentials');
  } finally {
    if (!exited) child.kill();
    server.closeAllConnections(); if (server.listening) await new Promise(resolve => server.close(resolve));
    await rm(dir, {recursive:true, force:true});
  }
});

test('explicit native play retries one failed HTTP download and preserves the queue', {skip:process.platform !== 'win32', timeout:30000}, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'dango-native-http-retry-'));
  const audio = await readFile(new URL('./native-player-silence.mp3', import.meta.url));
  const tracks = ['1', '2'].map(id => ({id, name:`Track ${id}`, artists:'Fixture', duration:8}));
  let mediaRequests = 0;
  const bridge = await createBridge({stateDir:dir, modDir:join(dir,'mod'), token, upstream:{
    search:async () => ({tracks, total:tracks.length}),
    songUrl:async () => ({url:'https://m1.music.126.net/fixture.mp3', expires:Date.now()+60000}),
    openMedia:async () => {
      const first = ++mediaRequests === 1;
      return Object.assign(Readable.from(first ? [] : [audio]), {
        statusCode:first ? 503 : 200,
        headers:{'content-type':'audio/mpeg', 'content-length':first ? '0' : String(audio.length)},
      });
    },
  }});
  const port = await bridge.listen(0);
  const child = spawn(powershell, ['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',resolve('helper/NativePlayer.ps1'),'-StateDir',dir,'-ParentProcessId',String(process.pid)], {windowsHide:true});
  let output = '', exited = false;
  child.on('exit', () => { exited = true; });
  child.stderr.on('data', data => { output += data; });
  t.after(async () => {
    if (!exited) child.kill();
    await bridge.close();
    await until(() => exited, 'worker exits');
    await rm(dir, {recursive:true, force:true});
  });
  async function api(path, data) {
    const response = await fetch(`http://127.0.0.1:${port}/api/${path}`, {
      method:data ? 'POST' : 'GET', headers:{Authorization:`Bearer ${token}`},
      body:data ? JSON.stringify(data) : undefined,
    });
    const result = await response.json();
    assert.equal(response.status, 200, result.error);
    return result;
  }
  async function statusUntil(predicate, label) {
    const deadline = Date.now()+10000;
    while (Date.now()<deadline && !exited) {
      const status = await api('status');
      if (predicate(status)) return status;
      await delay(50);
    }
    assert.fail(`${label}: ${output}`);
  }
  const control = (action, fields) => api('control', {action, ...fields});

  await statusUntil(status => status.playerConnected, 'worker startup');
  await control('volume', {value:0});
  await api('search?q=fixture');
  await control('play', {source:'search', trackId:'1'});
  await statusUntil(({player}) => /音频上游暂时不可用/.test(player.error), 'HTTP failure reported');
  assert.match(output, /stage=response httpStatus=502/);
  assert.ok(!output.includes(token));
  const queue = await api('queue');
  await delay(800);
  assert.equal(mediaRequests, 1, 'failed download waits for an explicit play command');
  await control('toggle');
  await statusUntil(({player}) => player.playing && player.duration>=7.9 && player.position>.4, 'retry opens and plays MP3');
  assert.equal(mediaRequests, 2, 'one retry opened one new download');
  assert.deepEqual(await api('queue'), queue);

  await control('pause');
  const {player:{position}} = await statusUntil(({player}) => !player.playing, 'pause');
  await control('resume');
  await statusUntil(({player}) => player.playing && player.position>position+.4, 'healthy resume');
  assert.equal(mediaRequests, 2, 'healthy resume reuses the downloaded track');
});

test('native worker exits with its parent and refuses another active owner', {skip:process.platform !== 'win32', timeout:30000}, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dango-native-lifetime-'));
  let rejectClaim = false, reports = 0, claims = 0;
  const server = http.createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    assert.equal(req.headers.authorization, `Bearer ${token}`);
    if (req.url === '/api/player/claim') {
      claims++;
      res.writeHead(rejectClaim ? 409 : 200, {'content-type':'application/json'});
      res.end(JSON.stringify({ok:!rejectClaim}));
    } else {
      if (req.url === '/api/player/report') reports++;
      res.writeHead(200, {'content-type':'application/json'});
      res.end(JSON.stringify({ok:true,desired:{revision:0,seekRevision:0,track:null,mediaUrl:null,playing:false,volume:0,position:0}}));
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  await writeFile(join(dir, 'bridge.json'), JSON.stringify({host:'127.0.0.1',port:server.address().port,token}));
  const parent = spawn(process.execPath, ['-e','setInterval(()=>{},1000)'], {windowsHide:true});
  const workers = [];
  function launch(parentId) {
    const child = spawn(powershell, ['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',resolve('helper/NativePlayer.ps1'),'-StateDir',dir,'-ParentProcessId',String(parentId)], {windowsHide:true});
    const worker = {child,exited:false,code:null,output:''};
    child.stdout.on('data', data => worker.output += data); child.stderr.on('data', data => worker.output += data);
    child.on('exit',code => {worker.exited=true;worker.code=code;});
    workers.push(worker); return worker;
  }
  try {
    const worker = launch(parent.pid);
    await until(() => reports > 0 || worker.exited, 'parented worker reports');
    assert.equal(worker.exited,false,worker.output);
    const duplicate = launch(parent.pid);
    await until(() => duplicate.exited,'duplicate exits');
    assert.equal(duplicate.code,3,duplicate.output);
    assert.equal(claims,1,'duplicate does not compete for a lease');
    parent.kill();
    await until(() => worker.exited,'parent exit shuts down worker',4000);
    assert.equal(worker.code,0,worker.output);
    rejectClaim=true;
    const rejected = launch(process.pid);
    await until(() => rejected.exited,'foreign lease rejected');
    assert.equal(rejected.code,3,rejected.output);
    assert.ok(workers.every(w => !w.output.includes(token)));
  } finally {
    parent.kill(); for (const worker of workers) if (!worker.exited) worker.child.kill();
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    await rm(dir,{recursive:true,force:true});
  }
});

test('native progressive MP3 starts before last chunk and controls remain responsive during stalled download', {skip:process.platform !== 'win32', timeout:40000}, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dango-native-stream-'));
  const audio = await readFile(new URL('./native-player-silence.mp3', import.meta.url));
  const reports = [], waits = new Set(), streams = new Map(), closed = new Set();
  let desired = {revision:0,seekRevision:0,track:null,mediaUrl:null,playing:false,volume:0,position:0};
  let audioRevision = 0, lastChunkAt = null;
  function send(res, value) { if (!res.destroyed) { res.writeHead(200, {'content-type':'application/json'}); res.end(JSON.stringify(value)); } }
  function state(res) { send(res, {ok:true,audioRevision,desired}); }
  function change(patch) { desired={...desired,...patch,revision:desired.revision+1};audioRevision++;for(const wake of [...waits])wake();return Date.now(); }
  const server = http.createServer(async (req,res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.headers.authorization !== `Bearer ${token}` && url.searchParams.get('token') !== token) {res.writeHead(401);res.end('{}');return;}
    if(url.pathname === '/api/media') {
      const id=url.searchParams.get('trackId');streams.set(id,res);req.on('close',()=>closed.add(id));
      res.writeHead(200,{'content-type':'audio/mpeg'});
      res.write(audio.subarray(0,Math.floor(audio.length/4)));return;
    }
    const chunks=[];for await(const chunk of req)chunks.push(chunk);
    const body=JSON.parse(Buffer.concat(chunks).toString()||'{}');
    if(url.pathname === '/api/player/claim')send(res,{ok:true});
    else if(url.pathname === '/api/player/state') {
      if(+url.searchParams.get('after')===audioRevision && url.searchParams.has('wait')) {
        let timer;const wake=()=>{clearTimeout(timer);waits.delete(wake);state(res);};waits.add(wake);timer=setTimeout(wake,8000);res.on('close',()=>{clearTimeout(timer);waits.delete(wake);});
      } else state(res);
    } else if(url.pathname === '/api/player/report') {reports.push({...body,at:Date.now()});send(res,{ok:true});}
    else {res.writeHead(404);res.end('{}');}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  await writeFile(join(dir,'bridge.json'),JSON.stringify({host:'127.0.0.1',port:server.address().port,token}));
  const child=spawn(powershell,['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',resolve('helper/NativePlayer.ps1'),'-StateDir',dir,'-ParentProcessId',String(process.pid)],{windowsHide:true});
  let exited=false,output='';child.on('exit',()=>exited=true);child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>output+=d);
  const latest=()=>reports.at(-1);
  try {
    await until(()=>reports.length||exited,'stream worker startup');assert.equal(exited,false,output);
    const start=change({track:{id:'1',duration:8},mediaUrl:`/api/media?trackId=1&token=${token}`,playing:true,seekRevision:1});
    await until(()=>latest()?.revision===1&&latest().position>.4,'playback while final 75% has not arrived');
    assert.equal(lastChunkAt,null);const firstAdvance=latest().at-start;
    for (const [index,position] of [.7,.2,.9,.3,1].entries()) {
      desired={...desired,position,seekRevision:20+index};audioRevision++;
      for(const wake of [...waits])wake();
      await delay(15);
    }
    await until(()=>latest()?.revision===1&&latest().position>1.1&&!latest().error,'latest rapid seek wins and playback continues');

    const pausedAt=change({playing:false});await until(()=>latest()?.revision===2&&!latest().playing,'pause during download');
    const pauseLatency=latest().at-pausedAt, paused=latest().position;
    await delay(400);assert.ok(Math.abs(latest().position-paused)<.1,JSON.stringify({paused,latest:latest(),reports:reports.slice(-4),output}));
    // Hold a healthy but paused response beyond the old 15-second deadline.
    // A paused listener must retain its stream instead of reporting a network error.
    await delay(16500);
    assert.equal(latest().error,null,'paused MP3 survives a response held beyond 15 seconds');
    assert.ok(!latest().ended);
    change({seekRevision:2,position:5});await until(()=>latest()?.revision===3&&latest().position>=4.9,'seek beyond buffer');
    change({playing:true});await until(()=>latest()?.revision===4&&latest().playing,'resume beyond buffer');
    await delay(500);assert.ok(Math.abs(latest().position-5)<.15,'underflow does not advance content clock');assert.ok(!latest().ended);
    const replaceAt=change({track:{id:'2',duration:8},mediaUrl:`/api/media?trackId=2&token=${token}`,seekRevision:3,position:0});
    await until(()=>latest()?.revision===5&&latest().position>.3&&latest().position<2,'replacement plays fresh buffered PCM');
    const replaceLatency=latest().at-replaceAt;
    await until(()=>closed.has('1'),'cancelled stalled response closes promptly',2000);
    streams.get('2').end(audio.subarray(Math.floor(audio.length/4)));lastChunkAt=Date.now();
    change({seekRevision:4,position:7.6});await until(()=>reports.some(r=>r.revision===6&&r.ended),'completed stream ends correctly');
    change({track:{id:'3',duration:8},mediaUrl:`/api/media?trackId=3&token=${token}`,seekRevision:5,position:0});
    await until(()=>latest()?.revision===7&&latest().position>.2,'third stream opens');streams.get('3').destroy();
    await until(()=>latest()?.revision===7&&!!latest().error,'network interruption is reported');
    assert.ok(pauseLatency<250,`pause latency ${pauseLatency}ms`);assert.ok(replaceLatency<1000,`replace latency ${replaceLatency}ms`);
    console.log(JSON.stringify({firstAdvanceMs:firstAdvance,pauseCommandToReportMs:pauseLatency,replaceToAdvanceMs:replaceLatency,withheldAudioPercent:75}));
    assert.ok(!output.includes(token));
  } finally {
    child.kill();await until(()=>exited,'stream worker exits');for(const res of streams.values())res.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(dir,{recursive:true,force:true});
  }
});

