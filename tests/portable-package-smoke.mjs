// Run only against an extracted candidate, on an ephemeral loopback port.
// Uses synthetic silence and fixture lyrics; no live account or service control.
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, writeFile, rm, cp} from 'node:fs/promises';
import {join, resolve, sep} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import {spawn} from 'node:child_process';
import {Readable} from 'node:stream';
import {setTimeout as delay} from 'node:timers/promises';

const packageRoot=resolve(process.argv[2]||'.');
const workshopSource=process.env.DANGO_WORKSHOP_MOD;
const fontsPath=process.env.DANGO_FONTS;
assert.ok(fontsPath,'Set DANGO_FONTS to the locally installed game fonts.zip');
const {createBridge}=await import(pathToFileURL(join(packageRoot,'helper/server.mjs')));
const sandbox=await mkdtemp(join(tmpdir(),'音乐 包验收 '));
const stateDir=join(sandbox,'state'),modDir=join(sandbox,'mod');
const runtimeModDir=join(sandbox,workshopSource?'steamapps/workshop/content/322330/987654321':'game/mods/local_netease_music');
await mkdir(runtimeModDir,{recursive:true});
if(workshopSource){
 await cp(resolve(workshopSource),runtimeModDir,{recursive:true});
 const identity=JSON.parse(await readFile(join(runtimeModDir,'music_workshop_identity.json'),'utf8'));
 const packageVersion=(await readFile(join(packageRoot,'VERSION'),'utf8')).split(/\r?\n/)[0].trim();
 assert.equal(identity.id,'zcc-dst-music');assert.equal(identity.version,packageVersion);
}else await writeFile(join(runtimeModDir,'music_bridge_owned.txt'),'dst-local-music-prototype-v1\n');
const wave=Buffer.alloc(44+16000*8);
wave.write('RIFF');wave.writeUInt32LE(wave.length-8,4);wave.write('WAVEfmt ',8);wave.writeUInt32LE(16,16);wave.writeUInt16LE(1,20);wave.writeUInt16LE(1,22);wave.writeUInt32LE(8000,24);wave.writeUInt32LE(16000,28);wave.writeUInt16LE(2,32);wave.writeUInt16LE(16,34);wave.write('data',36);wave.writeUInt32LE(wave.length-44,40);
const token='portable_fixture_not_a_real_account_token';
await mkdir(modDir,{recursive:true});
await cp(join(packageRoot,'mod/music_workshop_identity.json'),join(modDir,'music_workshop_identity.json'));
const bridge=await createBridge({stateDir,modDir,runtimeModDir,fontsPath,pythonPath:join(packageRoot,'runtime/python/python.exe'),token,updateFetch:async()=>new Response('[]'),upstream:{
 search:async()=>({tracks:[{id:'1',name:'Portable fixture',artists:'Local test',duration:8}],total:1}),
 songUrl:async()=>({url:'https://m1.music.126.net/fixture.wav',expires:Date.now()+60000}),
 openMedia:async()=>Object.assign(Readable.from([wave]),{statusCode:200,headers:{'content-type':'audio/wav','content-length':String(wave.length)}}),
 lyrics:async()=>({lrc:{lyric:'[00:00]Music 测试\n[00:04]测试完成'}}),
 startLogin:async()=>({key:'portable-fixture',url:'https://music.163.com/login?codekey=portable-fixture'}),
}});
const port=await bridge.listen(0),base=`http://127.0.0.1:${port}`;
async function request(path,data){const r=await fetch(base+path,{method:data?'POST':'GET',headers:{Authorization:`Bearer ${token}`},...(data?{body:JSON.stringify(data)}:{})});const body=await r.json();assert.equal(r.status,200,body.error);return body;}
async function until(fn,label,ms=12000){const start=Date.now();while(Date.now()-start<ms){if(await fn())return;await delay(100);}throw Error('Timed out: '+label);}
const powershell=join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/powershell.exe');
let stdout='',stderr='',exited=false,exitCode;
const child=spawn(powershell,['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',join(packageRoot,'helper/NativePlayer.ps1'),'-StateDir',stateDir,'-ParentProcessId',String(process.pid),'-MaxUnavailableSeconds','3'],{windowsHide:true,stdio:['ignore','pipe','pipe']});
child.stdout.on('data',data=>stdout+=data);child.stderr.on('data',data=>stderr+=data);child.on('exit',code=>{exited=true;exitCode=code;});
try{
 const updates=await request('/api/updates/check',{});
 assert.equal(updates.currentVersion,(await readFile(join(packageRoot,'VERSION'),'utf8')).split(/\r?\n/)[0].trim());
 assert.equal(updates.status,'unpublished');
 await request('/api/settings',{player:{volume:0}});
 await until(async()=>{assert.equal(exited,false,'worker exited');return(await request('/api/status')).playerConnected;},'native claim');
 await request('/api/search?q=fixture');await request('/api/control',{action:'play',source:'search',trackId:'1'});
 await until(async()=>{const p=(await request('/api/status')).player;assert.equal(p.error,null);return p.duration>=8&&p.position>.7;},'native audio progress');
 await request('/api/control',{action:'pause'});await delay(600);const before=(await request('/api/status')).player.position;await delay(600);assert.ok(Math.abs((await request('/api/status')).player.position-before)<.1);
 await request('/api/control',{action:'seek',value:4});await delay(500);assert.ok(Math.abs((await request('/api/status')).player.position-4)<.1);
 await request('/api/login/start',{});const qr=await request('/api/login/artwork?key=portable-fixture');
 const glyphs=await request('/api/lyric-glyphs?trackId=1');
 for(const asset of [qr.asset,glyphs.asset])assert.equal((await readFile(join(modDir,asset.atlas.replace(/\.xml$/,'.tex')))).subarray(0,4).toString(),'KTEX');
 if(workshopSource){
  for(const asset of [qr.asset,glyphs.asset])assert.deepEqual(await readFile(join(runtimeModDir,asset.atlas)),await readFile(join(modDir,asset.atlas)));
  const cache=resolve(runtimeModDir,'images/music_cache');
  assert.ok(cache.startsWith(resolve(sandbox)+sep));
  await rm(cache,{recursive:true,force:true});
  const repairedQr=await request('/api/login/artwork?key=portable-fixture');
  const repairedGlyphs=await request('/api/lyric-glyphs?trackId=1');
  for(const asset of [repairedQr.asset,repairedGlyphs.asset])assert.equal((await readFile(join(runtimeModDir,asset.atlas.replace(/\.xml$/,'.tex')))).subarray(0,4).toString(),'KTEX');
 }
 assert.equal((await request('/api/status')).account,null);
 assert.ok(!stdout.includes(token)&&!stderr.includes(token));
 assert.equal(stderr,'','native diagnostic log must be empty');
 console.log(JSON.stringify({passed:true,packageRoot,ephemeralPort:port,accountUsed:false,syntheticAudio:true,nativePlayback:true,pause:true,seek:true,qr:true,gameFontGlyphs:true,workshopResourceRecovery:!!workshopSource}));
}finally{
 await bridge.close();
 try{await until(()=>exited,'native worker cleanup',8000);}finally{if(!exited)child.kill();}
 await rm(sandbox,{recursive:true,force:true});
}
assert.equal(exitCode,0);
