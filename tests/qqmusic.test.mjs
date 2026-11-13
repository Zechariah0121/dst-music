import test from 'node:test';
import assert from 'node:assert/strict';
import {createQq, validateQqMediaUrl} from '../helper/qqmusic.mjs';

const song = (mid, media = mid) => ({songmid:mid, songname:'测试 &amp; 歌', interval:200, media_mid:media,
  singer:[{name:'甲'},{name:'乙'}], album:{mid:'album1'}});
const auth = {uin:'1200000000000000001', key:'test-private', loginType:2};
const reply = data => Response.json({code:0, req_0:{code:0, data}});

test('QQ search joins provider pages for unaligned offsets without inventing identities', async t => {
  const calls = [];
  const api = createQq({fetchImpl:async input => {
    const url = new URL(input);
    calls.push(url);
    const page = Number(url.searchParams.get('p'));
    return Response.json({code:0, data:{song:{totalnum:105,
      list:Array.from({length:page === 3 ? 5 : 50}, (_, index) => song(`MID${(page - 1) * 50 + index}`)),
    }}});
  }});
  t.after(() => api.close());
  const result = await api.search('测试 & 歌', 48, 54);
  assert.equal(result.total, 105);
  assert.equal(result.tracks.length, 54);
  assert.deepEqual(result.tracks.map(track => track.id), Array.from({length:54}, (_, index) => `qq:MID${48 + index}`));
  assert.deepEqual(result.tracks[0], {
    id:'qq:MID48', provider:'qq', nativeId:'MID48', mediaId:'MID48',
    name:'测试 & 歌', artists:'甲 / 乙', duration:200, cover:'https://y.gtimg.cn/music/photo_new/T002R300x300M000album1.jpg',
  });
  assert.deepEqual(calls.map(url => url.searchParams.get('p')), ['1', '2', '3']);
  assert.equal(calls[0].searchParams.get('w'), '测试 & 歌');
});

test('QQ catalog preserves large playlist IDs, public access, and authenticated liked identity', async t => {
  const calls = [];
  const api = createQq({fetchImpl:async (_url, options) => {
    const {req_0, comm} = JSON.parse(options.body, (_key, value, context) =>
      typeof value === 'number' && !Number.isSafeInteger(value) ? context.source : value);
    calls.push(req_0.method);
    if (req_0.method === 'GetRecommendFeed') {
      return new Response('{"code":0,"req_0":{"code":0,"data":{"List":[{"Playlist":{"basic":{"tid":1200000000000000001,"title":"推荐","song_cnt":2}}}]}}}');
    }
    if (req_0.method === 'CgiGetDiss') {
      if (req_0.param.dirid === 201) assert.equal(req_0.param.enc_host_uin, 'encrypted-123');
      else assert.equal(req_0.param.disstid, auth.uin);
      return reply({songlist:[song('SameMID'), song('SameMID')], total_song_num:2});
    }
    if (req_0.method === 'GetPlaylistByUin') {
      assert.equal(comm.uin, auth.uin);
      assert.equal(req_0.param.uin, auth.uin);
      assert.equal(options.headers.Cookie, `qqmusic_uin=${auth.uin}; qqmusic_key=${auth.key}; login_type=1`);
      return reply({v_playlist:[]});
    }
    if (req_0.method === 'GetLoginUserInfo') {
      return reply({str_musicid:auth.uin, info:{base:{nickName:'QQ 测试', encryptUin:'encrypted-123'}}});
    }
    if (req_0.method === 'CgiGetPlaylistFavInfo') return reply({v_list:[], hasmore:0});
    assert.fail('Unexpected request');
  }});
  t.after(() => api.close());
  const recommended = await api.discover('recommend');
  assert.equal(recommended[0].id, 'qq:playlist:' + auth.uin);
  const tracks = await api.playlist(recommended[0].id);
  assert.deepEqual(tracks.map(track => track.id), ['qq:SameMID', 'qq:SameMID']);
  const profile = await api.account(auth);
  assert.deepEqual(profile, {id:auth.uin, nickname:'QQ 测试'});
  const personal = await api.playlists(auth, profile);
  const liked = personal[0].id;
  assert.equal(liked, 'qq:liked:' + auth.uin);
  const before = calls.length;
  await assert.rejects(api.playlist(liked, {...auth, uin:'12'}), {status:401});
  assert.equal(calls.length, before);
  assert.equal((await api.playlist(liked, auth)).length, 2);
});

test('QQ playback rejects mismatched media and CDN, and returns stable entitlement', async t => {
  const phases = [];
  let denied = false, expired = false;
  const api = createQq({now:() => 1000, report:(...entry) => phases.push(entry), fetchImpl:async (_url, options) => {
    const {req_0} = JSON.parse(options.body);
    if (req_0.method === 'GetLoginUserInfo') {
      return Response.json({code:0, req_0:{code:expired ? 104400 : 0, data:{info:{nick:'测试'}}}});
    }
    assert.deepEqual(req_0.param.songmid, ['Wanted', 'Wanted']);
    assert.deepEqual(req_0.param.filename, ['M500TheMedia.mp3', 'M800TheMedia.mp3']);
    if (req_0.method === 'UrlGetVkey') {
      return reply({midurlinfo:[
        {songmid:'OtherSong', purl:'https://isure.stream.qqmusic.qq.com/M500TheMedia.mp3'},
        {songmid:'Wanted', purl:'https://evil.qq.com/M500TheMedia.mp3'},
        {songmid:'Wanted', purl:'M500OtherMedia.mp3'},
      ]});
    }
    if (req_0.method === 'CgiGetVkey') {
      return reply({sip:['https://isure.stream.qqmusic.qq.com/'], midurlinfo:[
        {result:0, songmid:'Wanted', filename:'M500TheMedia.mp3',
          purl:denied ? '' : 'M500TheMedia.mp3?vkey=private-test', freeTrialInfo:{start:0, end:30}},
      ]});
    }
    assert.fail('Unexpected playback request');
  }});
  t.after(() => api.close());
  const track = {id:'qq:Wanted', mediaId:'TheMedia'};
  assert.deepEqual(await api.songUrl(track.id, undefined, track), {
    url:'https://isure.stream.qqmusic.qq.com/M500TheMedia.mp3?vkey=private-test', trial:true, expires:121000,
  });
  denied = true;
  await assert.rejects(api.songUrl(track.id, undefined, track), {status:403});
  expired = true;
  await assert.rejects(api.songUrl(track.id, auth, track), {status:401});
  assert.deepEqual(phases.at(-1), ['session', 104400]);
  for (const url of ['https://127.0.0.1/song.mp3', 'https://isure.stream.qqmusic.qq.com.evil.qq.com/song.mp3',
    'https://u:p@isure.stream.qqmusic.qq.com/song.mp3', 'https://isure.stream.qqmusic.qq.com:8443/song.mp3']) {
    assert.throws(() => validateQqMediaUrl(url), {status:502});
  }
});

test('QQ normalizes its signed MP3 CDN MIME alias without admitting other response types', async t => {
  const calls = [];
  let type = 'application/x-www-form-urlencoded; charset=UTF-8', status = 206;
  const api = createQq({mediaOpener:async (url, range, signal) => {
    calls.push({url, range, signal});
    return {statusCode:status, headers:{'content-type':type, 'content-range':'bytes 120-199/300'}};
  }});
  t.after(() => api.close());
  const url = 'https://isure.stream.qqmusic.qq.com/M500TheMedia.mp3?vkey=test';
  const signal = new AbortController().signal;
  const response = await api.openMedia(url, 'bytes=120-199', signal);
  assert.equal(response.headers['content-type'], 'audio/mpeg');
  assert.equal(response.headers['content-range'], 'bytes 120-199/300');
  assert.deepEqual(calls, [{url, range:'bytes=120-199', signal}]);
  for (const value of ['text/html', 'application/json', 'audio/mpeg', 'application/octet-stream']) {
    type = value;
    assert.equal((await api.openMedia(url)).headers['content-type'], value);
  }
  type = 'application/x-www-form-urlencoded';
  for (const suffix of ['error.html', 'M500TheMedia.mp3/error', 'other.mp3']) {
    assert.equal((await api.openMedia('https://isure.stream.qqmusic.qq.com/' + suffix)).headers['content-type'], type);
  }
  status = 403;
  assert.equal((await api.openMedia(url)).headers['content-type'], type);
  const before = calls.length;
  await assert.rejects(api.openMedia('https://untrusted.example/M500TheMedia.mp3'), {status:502});
  assert.equal(calls.length, before);
});
