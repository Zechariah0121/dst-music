// Isolated browser integration fixture. No NetEase traffic or real accounts.
import {createBridge} from '../helper/server.mjs';
import {mkdtemp,mkdir,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Readable} from 'node:stream';
const stateDir=await mkdtemp(join(tmpdir(),'dst-music-ui-'));
await writeFile(join(stateDir,'account.json'),JSON.stringify({cookie:'fixture-only',account:{id:'100',nickname:'测试账号（非真实登录）'}}));
const tracks=Array.from({length:63},(_,i)=>({id:String(i+1),name:i===0?'播放链路测试 · 静音音频':i===1?'切歌与暂停测试 · 静音音频':`分页测试歌曲 ${i+1}`,artists:'自动测试素材',duration:120}));
const audio=Buffer.alloc(44+8000*2*120);audio.write('RIFF',0);audio.writeUInt32LE(audio.length-8,4);audio.write('WAVEfmt ',8);audio.writeUInt32LE(16,16);audio.writeUInt16LE(1,20);audio.writeUInt16LE(1,22);audio.writeUInt32LE(8000,24);audio.writeUInt32LE(16000,28);audio.writeUInt16LE(2,32);audio.writeUInt16LE(16,34);audio.write('data',36);audio.writeUInt32LE(audio.length-44,40);
const upstream={
  playlists:async()=>[{id:'10',name:'联调测试歌单 · 63 首',trackCount:63}],playlist:async()=>tracks,
  songUrl:async(id)=>({url:`https://fixture.music.126.net/${id}.wav`,trial:id==='2',expires:Date.now()+300000}),
  openMedia:async(_url,range)=>{let start=0,end=audio.length-1,statusCode=200;if(range){const match=/^bytes=(\d+)-(\d*)$/.exec(range);if(match){start=+match[1];if(match[2])end=Math.min(+match[2],end);statusCode=206;}}
    const stream=Readable.from([audio.subarray(start,end+1)]);stream.statusCode=statusCode;stream.headers={'content-type':'audio/wav','content-length':String(end-start+1),'accept-ranges':'bytes',...(statusCode===206?{'content-range':`bytes ${start}-${end}/${audio.length}`}:{})};return stream;},
};
const bridge=await createBridge({port:17864,stateDir,modDir:join(stateDir,'mod'),token:'fixture_only_token_not_a_real_secret',upstream});
await bridge.listen();console.log('UI fixture running on 127.0.0.1:17864 (mock account, silent audio)');
