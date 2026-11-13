// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Sorihiko/DangoMusic QqMusicSource.kt, QqCatalog.kt and QqPlayback.kt
// (7d1609d6b259a6b439542058b3f8f0c5969b6e2b).
import {randomInt} from 'node:crypto';
import {qqMediaHostname} from './media-dns.mjs';
import {createMediaOpener} from './netease.mjs';
import {createQqLogin, qqError, validQqCredentials, qqProfile} from './qq-login.mjs';
import {createQqLyricDecoder, decodeQqText} from './qq-lyrics.mjs';

const REFERER = 'https://y.qq.com/';
const CGI = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const WEB = 'https://c.y.qq.com';
const DEFAULT_CDN = 'https://isure.stream.qqmusic.qq.com/';
const MAX_JSON = 12 * 1024 * 1024;
const MID = /^[A-Za-z0-9]{1,64}$/;
const NUMBER_ID = /^[1-9][0-9]{0,18}$/;
const EXPIRED_CODES = new Set([1000, 104400, 104401]);
const pick = (...values) => values.find(value => typeof value === 'string' && value.trim()) || '';
const text = (...values) => decodeQqText(pick(...values)).trim();
const numberId = value => NUMBER_ID.test(String(value ?? '')) ? String(value) : '';
const positive = value => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : 0;
const array = value => Array.isArray(value) ? value : [];
const wireNumber = id => Number.isSafeInteger(Number(id)) ? Number(id) : JSON.rawJSON(id);
const trackMid = id => /^qq:([A-Za-z0-9]{1,64})$/.exec(id)?.[1];
const playlistParts = id => /^qq:(playlist|chart|liked):([1-9][0-9]{0,18})$/.exec(id);

function hash33(value) {
  let hash = 5381;
  for (const char of value) hash = ((hash << 5) + hash + char.charCodeAt(0)) | 0;
  return hash & 0x7fffffff;
}

export function validateQqMediaUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw qqError('QQ 音乐返回无效音频地址'); }
  if (url.protocol === 'http:' && !url.port) url.protocol = 'https:';
  if (url.protocol !== 'https:' || url.username || url.password || url.port || url.hash ||
      !qqMediaHostname(url.hostname)) {
    throw qqError('QQ 音乐音频来源不在许可范围');
  }
  return url;
}

function parseTrack(value) {
  const row = value?.songInfo ?? value;
  const mid = pick(row?.songmid, row?.mid);
  if (!MID.test(mid)) return null;
  const album = pick(row.albummid, row.album?.mid);
  const media = pick(row.strMediaMid, row.media_mid, row.file?.media_mid);
  return {
    id:`qq:${mid}`,
    provider:'qq',
    nativeId:mid,
    mediaId:MID.test(media) ? media : mid,
    ...(numberId(row.songid ?? row.id) ? {sourceSongId:numberId(row.songid ?? row.id)} : {}),
    name:text(row.songname, row.title, row.name) || '未命名歌曲',
    artists:array(row.singer).map(artist => text(artist?.name)).filter(Boolean).join(' / '),
    duration:positive(row.interval),
    ...(MID.test(album) ? {cover:`https://y.gtimg.cn/music/photo_new/T002R300x300M000${album}.jpg`} : {}),
  };
}

function parsePlaylist(row, owner) {
  if (!row || typeof row !== 'object') return null;
  const tid = numberId(row.tid) || numberId(row.id);
  const liked = owner && Number(row.dirId ?? row.dirid) === 201;
  if (!tid && !liked) return null;
  const cover = pick(row.picurl, row.picUrl, row.logo, row.cover?.default_url, row.cover?.medium_url, row.bigpicUrl);
  return {
    id:liked ? `qq:liked:${owner}` : `qq:playlist:${tid}`,
    provider:'qq',
    name:text(row.title, row.dirName, row.name) || (liked ? '我喜欢' : 'QQ 音乐'),
    trackCount:positive(row.song_cnt) || positive(row.songNum ?? row.songnum),
    ...(cover ? {cover} : {}),
  };
}

function uniqueById(rows) {
  return [...new Map(rows.map(row => [row.id, row])).values()];
}

function parseJson(raw) {
  const source = raw.trim();
  const json = source.startsWith('{') ? source : /^[\w$.]+\s*\(([\s\S]*)\)\s*;?$/.exec(source)?.[1];
  if (!json) throw qqError('QQ 音乐返回数据格式无效');
  // QQ playlist and music IDs can exceed Number.MAX_SAFE_INTEGER.
  return JSON.parse(json, (_key, value, context) =>
    typeof value === 'number' && !Number.isSafeInteger(value) && /^\d+$/.test(context?.source) ? context.source : value);
}

export function createQq({fetchImpl = fetch, now = Date.now, webSocketFactory, mediaOpener,
                          report = () => {}, qrLifetimeMs, qrHandshakeMs} = {}) {
  const guid = String(randomInt(1_000_000_000, 10_000_000_000));
  let likedRef;
  const mediaTransport = mediaOpener || createMediaOpener({validateUrl:validateQqMediaUrl, headers:{Referer:REFERER}});
  const lyricDecoder = createQqLyricDecoder();

  async function openMedia(value, range, signal) {
    const url = validateQqMediaUrl(value);
    const response = await mediaTransport(url.href, range, signal);
    // QQ's signed MP3 CDN responses can carry this incorrect MIME type (also
    // on 206 byte ranges). Normalize only that observed alias on our expected
    // MP3 filenames; HTML/JSON and every other provider keep their validation.
    const type = String(response.headers['content-type'] || '').split(';', 1)[0].trim().toLowerCase();
    if ([200, 206].includes(response.statusCode) &&
        /^\/M[58]00[A-Za-z0-9]{1,64}\.mp3$/.test(url.pathname) &&
        type === 'application/x-www-form-urlencoded') {
      response.headers['content-type'] = 'audio/mpeg';
    }
    return response;
  }

  async function request(url, {payload, cookie, signal, contentType = 'application/x-www-form-urlencoded'} = {}) {
    const timeout = AbortSignal.timeout(12000);
    try {
      const auth = validQqCredentials(cookie);
      const response = await fetchImpl(url, {
        method:payload ? 'POST' : 'GET',
        redirect:'error',
        signal:signal ? AbortSignal.any([timeout, signal]) : timeout,
        headers:{
          Referer:REFERER,
          'User-Agent':'Mozilla/5.0',
          ...(payload ? {'Content-Type':contentType} : {}),
          ...(auth ? {Cookie:`qqmusic_uin=${cookie.uin}; qqmusic_key=${cookie.key}; login_type=${cookie.loginType === 1 ? 2 : 1}`} : {}),
        },
        ...(payload ? {body:JSON.stringify(payload)} : {}),
      });
      if (!response.ok || !response.body) throw qqError('QQ 音乐请求失败，请稍后重试');
      let bytes = 0;
      const chunks = [];
      for await (const chunk of response.body) {
        bytes += chunk.length;
        if (bytes > MAX_JSON) throw qqError('QQ 音乐返回数据过大');
        chunks.push(chunk);
      }
      return parseJson(Buffer.concat(chunks).toString('utf8'));
    } catch {
      if (signal?.aborted) throw qqError('QQ 音乐扫码已取消', 409);
      throw qqError('QQ 音乐请求失败，请稍后重试');
    }
  }

  async function call(module, method, param, {cookie, comm = {ct:19, cv:2201}, signal, contentType} = {}) {
    const auth = validQqCredentials(cookie) ?
      {uin:cookie.uin, authst:cookie.key, g_tk:hash33(cookie.key), tmeLoginType:cookie.loginType} : {};
    const root = await request(CGI, {payload:{comm:{...comm, ...auth}, req_0:{module, method, param}}, cookie, signal, contentType});
    const block = root.req_0;
    const data = block?.data;
    const codes = [root.code, block?.code, data?.code ?? 0].map(code => /^-?\d+$/.test(String(code)) ? Number(code) : -1);
    const code = codes.find(value => value !== 0) ?? 0;
    return {code, data};
  }

  async function cgi(module, method, param, cookie) {
    const {code, data} = await call(module, method, param, {cookie});
    if (code !== 0 || !data || typeof data !== 'object') {
      throw EXPIRED_CODES.has(code) && validQqCredentials(cookie) ?
        qqError('QQ 音乐登录已失效，请重新扫码', 401) : qqError('QQ 音乐请求失败，请稍后重试');
    }
    return data;
  }

  async function account(cookie, signal) {
    if (!validQqCredentials(cookie)) throw qqError('请先扫码登录 QQ 音乐', 401);
    const {code, data} = await call('music.UserInfo.userInfoServer', 'GetLoginUserInfo', {}, {cookie, signal});
    if (EXPIRED_CODES.has(code)) throw qqError('QQ 音乐登录已失效，请重新扫码', 401);
    if (code !== 0 || !data || !Object.keys(data).length) throw qqError('QQ 音乐账号暂不可用，请稍后重试');
    const profile = qqProfile(data, cookie.uin);
    if (!profile) throw qqError('QQ 音乐账号校验失败，请重新扫码', 401);
    return profile;
  }

  async function encryptedProfile(cookie) {
    try {
      const profile = await cgi('music.UserInfo.userInfoServer', 'GetLoginUserInfo', {}, cookie);
      for (const row of [profile.info, profile.info?.base, profile]) {
        const id = pick(row?.encrypt_uin, row?.encryptUin, row?.encryptedUin);
        if (/^[A-Za-z0-9_-]{1,128}$/.test(id)) return id;
      }
    } catch { /* The public profile endpoint can resolve older profile data. */ }
    const query = new URLSearchParams({format:'json', cid:'205360838', ct:'20', cv:'4747474', userid:cookie.uin});
    const root = await request('https://c6.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg?' + query);
    const id = root?.data?.creator?.encrypt_uin;
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(id ?? '')) throw qqError('QQ 音乐账号资料暂不可用');
    return id;
  }

  async function playlists(cookie, profile) {
    if (!validQqCredentials(cookie) || profile?.id !== cookie.uin) throw qqError('请先扫码登录 QQ 音乐', 401);
    const created = await cgi('music.musicasset.PlaylistBaseRead', 'GetPlaylistByUin', {uin:cookie.uin}, cookie);
    const likedDirectory = array(created.v_playlist).find(row => Number(row?.dirId ?? row?.dirid) === 201);
    likedRef = {owner:cookie.uin, tid:numberId(likedDirectory?.tid) || numberId(likedDirectory?.id)};
    const own = array(created.v_playlist).map(row => parsePlaylist(row, cookie.uin)).filter(Boolean);
    const likedId = `qq:liked:${cookie.uin}`;
    const liked = own.find(row => row.id === likedId) || {id:likedId, provider:'qq', name:'我喜欢', trackCount:0};
    const lists = [liked, ...own.filter(row => row.id !== likedId)];
    try {
      const encrypted = await encryptedProfile(cookie);
      let offset = 0;
      for (let page = 0; page < 100; page++) {
        const data = await cgi('music.musicasset.PlaylistFavRead', 'CgiGetPlaylistFavInfo',
          {uin:encrypted, offset, size:100}, cookie);
        const items = array(data.v_list);
        lists.push(...items.map(row => parsePlaylist(row)).filter(Boolean));
        offset += items.length;
        if (!items.length || !Number(data.hasmore)) break;
      }
    } catch { /* Preserve the account's own playlists if favorites are unavailable. */ }
    return uniqueById(lists);
  }

  async function playlist(id, cookie) {
    const parts = playlistParts(id);
    if (!parts) throw qqError('QQ 音乐歌单编号无效', 400);
    const [, kind, key] = parts;
    if (kind === 'liked' && (!validQqCredentials(cookie) || cookie.uin !== key)) {
      throw qqError('请先扫码登录 QQ 音乐', 401);
    }
    const tid = kind === 'liked' ? (likedRef?.owner === key ? likedRef.tid : '') : key;
    const likedHost = kind === 'liked' && !tid ? await encryptedProfile(cookie) : '';
    const tracks = [];
    let offset = 0;
    let lastPage;
    for (let page = 0; page < 200; page++) {
      const data = kind === 'chart' ?
        await cgi('music.musicToplist.Toplist', 'GetDetail', {topId:wireNumber(key), offset, num:100}, cookie) :
        await cgi('music.srfDissInfo.DissInfo', 'CgiGetDiss', {
          disstid:tid ? wireNumber(tid) : 0, dirid:likedHost ? 201 : 0, song_begin:offset, song_num:100,
          userinfo:true, tag:true, orderlist:true, ...(likedHost ? {enc_host_uin:likedHost} : {}),
        }, cookie);
      const rows = array(kind === 'chart' ? data.songInfoList : data.songlist);
      const parsed = rows.map(parseTrack);
      if (parsed.some(track => !track)) throw qqError('QQ 音乐部分歌曲资料不可用，未省略或替换歌曲');
      const pageKey = parsed.map(track => track.id).join(',');
      if (pageKey && pageKey === lastPage) throw qqError('QQ 音乐返回重复歌单页，请重试');
      tracks.push(...parsed);
      lastPage = pageKey;
      offset += rows.length;
      const total = positive(kind === 'chart' ? data.data?.totalNum : data.total_song_num);
      if (!rows.length || (total > 0 && offset >= total) ||
          (kind === 'chart' && rows.length < 100) ||
          (kind !== 'chart' && !Number(data.hasmore) && (!total || offset >= total))) return tracks;
    }
    throw qqError('QQ 音乐歌单过大，暂无法完整读取');
  }

  async function discover(section, cookie) {
    if (section === 'recommend') {
      const data = await cgi('music.playlist.PlaylistSquare', 'GetRecommendFeed', {From:0, Size:30}, cookie);
      return uniqueById(array(data.List).map(item => parsePlaylist(item?.Playlist?.basic)).filter(Boolean));
    }
    if (section !== 'charts') throw qqError('QQ 音乐推荐分类无效', 400);
    const data = await cgi('music.musicToplist.Toplist', 'GetAll', {});
    return uniqueById(array(data.group).flatMap(group => array(group?.toplist)).flatMap(row => {
      const id = numberId(row?.topId);
      if (!id) return [];
      const cover = pick(row.frontPicUrl, row.headPicUrl);
      return [{id:`qq:chart:${id}`, provider:'qq', name:text(row.title) || 'QQ 音乐排行榜',
        trackCount:positive(row.totalNum), ...(cover ? {cover} : {})}];
    }));
  }

  async function search(query, offset, limit, cookie) {
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
      throw qqError('QQ 音乐搜索分页无效', 400);
    }
    const pageSize = 50;
    const firstPage = Math.floor(offset / pageSize) + 1;
    const tracks = [];
    let total = 0;
    for (let page = firstPage; (page - 1) * pageSize < offset + limit; page++) {
      const params = new URLSearchParams({format:'json', p:String(page), n:String(pageSize), w:query});
      const root = await request(WEB + '/soso/fcgi-bin/client_search_cp?' + params, {cookie});
      if (Number(root.code) !== 0 || !root.data?.song) throw qqError('QQ 音乐搜索失败，请稍后重试');
      const data = root.data.song;
      const list = array(data.list);
      total = positive(data.totalnum);
      const pageOffset = (page - 1) * pageSize;
      tracks.push(...list.slice(Math.max(0, offset - pageOffset), offset + limit - pageOffset).map(parseTrack).filter(Boolean));
      if (list.length < pageSize || page * pageSize >= total) break;
    }
    return {tracks, total};
  }

  async function lyrics(id, cookie, track) {
    const mid = trackMid(id);
    if (!mid) throw qqError('QQ 音乐歌曲编号无效', 400);
    const duration = track?.id === id ? track.duration : 0;
    try {
      const data = await cgi('music.musichallSong.PlayLyricInfo', 'GetPlayLyricInfo', {
        songMid:mid, type:1, lrc_t:0, qrc_t:0, roma:0, roma_t:0, trans_t:0, trans:1, crypt:1, qrc:1,
      }, cookie);
      const result = await lyricDecoder.decode(data.lyric, data.trans, duration);
      if (result.lines.length) return result;
    } catch { /* Use the line-lyric endpoint when QRC is unavailable. */ }
    const params = new URLSearchParams({format:'json', nobase64:'1', songmid:mid});
    const root = await request(WEB + '/lyric/fcgi-bin/fcg_query_lyric_new.fcg?' + params, {cookie});
    if (Number(root.code ?? 0) !== 0 || Number(root.retcode ?? 0) !== 0) return {timing:'none', lines:[]};
    try { return await lyricDecoder.decode(root.lyric, root.trans, duration); }
    catch { throw qqError('QQ 音乐歌词暂不可用，请稍后重试'); }
  }

  async function playbackReply(phase, module, method, param, cookie, desktop) {
    try {
      const reply = await call(module, method, param, {
        cookie, comm:desktop ? {ct:19, cv:2201} : {ct:24, cv:0}, contentType:'application/json',
      });
      report(phase, reply.code);
      return reply;
    } catch {
      report(phase, -3);
      return {code:-3};
    }
  }

  async function songUrl(id, cookie, track) {
    const mid = trackMid(id);
    if (!mid) throw qqError('QQ 音乐歌曲编号无效', 400);
    let media = track?.id === id && typeof track.mediaId === 'string' && MID.test(track.mediaId) ? track.mediaId : mid;
    if (media === mid) {
      const reply = await playbackReply('metadata', 'music.pf_song_detail_svr', 'get_song_detail_yqq', {song_mid:mid}, cookie, false);
      const info = reply.data?.track_info;
      const resolved = info?.file?.media_mid;
      if (reply.code === 0 && (!info?.mid || info.mid === mid) && typeof resolved === 'string' && MID.test(resolved)) media = resolved;
    }
    const filenames = [`M500${media}.mp3`, `M800${media}.mp3`];
    const params = {guid, uin:validQqCredentials(cookie) ? cookie.uin : '0', ctx:0,
      filename:filenames, songmid:[mid, mid], songtype:[0, 0]};
    const desktop = await playbackReply('desktop', 'music.vkey.GetVkey', 'UrlGetVkey', params, cookie, true);
    const desktopUrl = desktop.code === 0 && parsePlayback(desktop.data, filenames, mid, now());
    if (desktopUrl) return desktopUrl;
    const web = await playbackReply('web', 'vkey.GetVkeyServer', 'CgiGetVkey', {...params, loginflag:1, platform:'20'}, cookie, false);
    const webUrl = web.code === 0 && parsePlayback(web.data, filenames, mid, now());
    if (webUrl) return webUrl;
    if (desktop.code === -3 && web.code === -3) throw qqError('QQ 音乐播放请求失败，请稍后重试');
    if (validQqCredentials(cookie)) {
      const verified = await playbackReply('session', 'music.UserInfo.userInfoServer', 'GetLoginUserInfo', {}, cookie, true);
      if (EXPIRED_CODES.has(verified.code)) throw qqError('QQ 音乐登录已失效，请重新扫码', 401);
    }
    throw qqError('QQ 音乐未返回此曲的播放地址，可能需要登录或受会员、版权、地区限制', 403);
  }

  const login = createQqLogin({call, now, webSocketFactory, report, lifetimeMs:qrLifetimeMs, handshakeMs:qrHandshakeMs});
  return {provider:'qq', ...login, account, playlists, playlist, discover, search, lyrics, songUrl,
    openMedia, validateMediaUrl:validateQqMediaUrl,
    close() { login.close(); lyricDecoder.close(); },
  };
}

function parsePlayback(data, filenames, mid, now) {
  const hosts = array(data?.sip).filter(host => typeof host === 'string');
  for (const row of array(data?.midurlinfo)) {
    if (!row || (row.result !== undefined && Number(row.result) !== 0) ||
        (row.songmid && row.songmid !== mid) ||
        (row.filename && !filenames.includes(row.filename))) continue;
    const path = row.purl;
    if (typeof path !== 'string' || !path || path.length > 4096 || path.startsWith('//') || path.includes('\\')) continue;
    const candidates = /^https?:\/\//i.test(path) ? [path] : [...hosts, DEFAULT_CDN];
    for (const candidate of candidates) {
      try {
        const url = validateQqMediaUrl(candidate === path ? path : new URL(path, validateQqMediaUrl(candidate)));
        if (!filenames.includes(url.pathname.split('/').at(-1))) continue;
        const trial = Boolean(row.freeTrialInfo || Number(row.trial) > 0 || Number(row.tryPlay) > 0);
        return {url:url.href, trial, expires:now + 120_000};
      } catch { /* A malformed or unexpected CDN candidate cannot be forwarded. */ }
    }
  }
  return null;
}
