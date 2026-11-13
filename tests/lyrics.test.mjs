import test from 'node:test';
import assert from 'node:assert/strict';
import {parseLrc,parseYrc,parseLyrics} from '../helper/lyrics.mjs';
test('YRC保留真实逐字时间、标点与翻译，忽略元数据',()=>{
 const result=parseLyrics({yrc:{lyric:'{"t":0}\n[1000,2000](1000,700,0)纸船(1700,1300,0)出发。'},tlyric:{lyric:'[00:01.10]Paper boat departs.'}});
 assert.equal(result.timing,'word');assert.equal(result.lines[0].text,'纸船出发。');assert.equal(result.lines[0].translation,'Paper boat departs.');
 assert.deepEqual(result.lines[0].words,[{start:1,end:1.7,text:'纸船'},{start:1.7,end:3,text:'出发。'}]);
});
test('LRC多时间戳、小数与offset；绝不伪造逐字时间',()=>{
 const lines=parseLrc('[offset:100]\n[00:01.2][00:04.250]窗外有只猫\n[00:08]它在等风来',12);
 assert.deepEqual(lines.map(l=>l.start),[1.3,4.35,8.1]);assert.equal(lines[0].end,4.35);assert.equal(lines[2].end,12);assert.ok(lines.every(l=>l.words.length===0));
 assert.equal(parseLyrics({lrc:{lyric:'[00:01]这是自写测试句'}}).timing,'line');
});
test('无歌词与纯音乐；无效YRC回退LRC，不泄露原数据',()=>{
 assert.deepEqual(parseLyrics({nolyric:true}),{lines:[],timing:'none'});
 assert.deepEqual(parseLyrics({lrc:{lyric:'[00:00]纯音乐，请欣赏'}}),{lines:[],timing:'none'});
 const result=parseLyrics({yrc:{lyric:'[1000,500](9000,100,0)错位'},lrc:{lyric:'[00:02]有效测试'}});
 assert.equal(result.timing,'line');assert.equal(result.lines[0].text,'有效测试');assert.deepEqual(parseYrc('not-yrc'),[]);
});
test('翻译只按容差匹配，括号文本不丢失；排序且时间不可越界',()=>{
 const result=parseLyrics({yrc:{lyric:'[2000,1000](2000,1000,0)风(轻轻)\n[1000,500](1000,500,0)雨'},tlyric:{lyric:'[00:15]不该匹配'}});
 assert.deepEqual(result.lines.map(l=>l.text),['雨','风(轻轻)']);assert.ok(result.lines.every(l=>!l.translation));
 assert.equal(parseLrc('[99:99]非法秒').length,0);
});
