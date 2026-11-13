// Web API interoperability, independently implemented with Node built-ins.
import { createCipheriv, randomBytes } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import https from 'node:https';
import {publicMediaAddress,proxyFakeAddress,createPublicMediaResolver} from './media-dns.mjs';

const modulus = BigInt('0x00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7');
function aes(value, key) {
  const cipher = createCipheriv('aes-128-cbc', key, Buffer.from('0102030405060708'));
  return Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]).toString('base64');
}
export function encryptWeapi(data) {
  const key = randomBytes(12).toString('hex').slice(0, 16);
  let base = BigInt('0x' + Buffer.from([...key].reverse().join('')).toString('hex'));
  let power = 65537n, encrypted = 1n;
  while (power) { if (power & 1n) encrypted = encrypted * base % modulus; base = base * base % modulus; power >>= 1n; }
  return new URLSearchParams({ params: aes(aes(JSON.stringify(data), Buffer.from('0CoJUm6Qyw8W8jud')), Buffer.from(key)), encSecKey: encrypted.toString(16).padStart(256, '0') });
}
const businessError = (message, status = 422) => Object.assign(new Error(message), { status });
const safeError = () => businessError('网易云请求失败，请稍后重试或重新登录',502);
export function validateMediaUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw businessError('音频地址无效',502); }
  // The URL API can return HTTP CDN links; upgrade only, never downgrade TLS.
  if (url.protocol === 'http:') url.protocol = 'https:';
  if (url.protocol !== 'https:' || !url.hostname.endsWith('.music.126.net') || url.port || url.username || url.password) throw businessError('音频来源不在许可范围',502);
  return url;
}
export function createMediaOpener({ lookupImpl = lookup, getImpl = https.get, dnsFetchImpl = fetch, now = Date.now,
 connectTimeoutMs = 30000, idleTimeoutMs = 60000, validateUrl = validateMediaUrl, headers = {} } = {}) {
 const publicResolve=createPublicMediaResolver({fetchImpl:dnsFetchImpl,now});
 const fixedHeaders=Object.fromEntries(Object.entries(headers).filter(([name])=>name.toLowerCase()!=='range'));
 return async function open(value, range, callerSignal, redirects = 0) {
  const url = validateUrl(value);
  const connection = new AbortController();
  const signal = callerSignal ? AbortSignal.any([callerSignal,connection.signal]) : connection.signal;
  signal.throwIfAborted();
  const timer = setTimeout(() => connection.abort(),connectTimeoutMs);
  timer.unref();
  let response;
  try {
   let addresses = await new Promise((resolve,reject) => {
    const abort = () => reject(businessError('音频连接超时或已关闭',502));
    signal.addEventListener('abort',abort,{once:true});
    lookupImpl(url.hostname,{all:true,family:4}).then(resolve,()=>reject(businessError('音频地址解析失败',502))).finally(() => signal.removeEventListener('abort',abort));
  });
   if(addresses.length&&addresses.every(a=>proxyFakeAddress(a.address)))addresses=await publicResolve(url.hostname,signal);
   if (!addresses.length || addresses.some(a => !publicMediaAddress(a.address))) throw businessError('音频地址解析失败',502);
   signal.throwIfAborted();
   response = await new Promise((resolve, reject) => {
    const req = getImpl(url, { signal, headers: { ...fixedHeaders, ...(range ? { Range: range } : {}) }, lookup: (_host, options, cb) => options.all ? cb(null, [addresses[0]]) : cb(null, addresses[0].address, 4) }, resolve);
    req.on('error', reject);
   });
  } finally { clearTimeout(timer); }
  // Do not impose a total download deadline: buffering and downstream backpressure
  // can keep a healthy audio response open for minutes. Caller disconnect still aborts.
  response.setTimeout(idleTimeoutMs, () => {
    if (!response.isPaused()) response.destroy(businessError('音频传输超时',502));
  });
  if ([301,302,303,307,308].includes(response.statusCode)) {
    response.destroy();
    if (redirects >= 3 || !response.headers.location) throw businessError('音频重定向失败',502);
    return open(new URL(response.headers.location, url).href, range, callerSignal, redirects + 1);
  }
  return response;
 };
}
export const openMedia = createMediaOpener();
export function createNetease({ fetchImpl = fetch } = {}) {
  async function request(path, cookie = '', data) {
    try {
      const response = await fetchImpl('https://music.163.com' + path, {
        method: data ? 'POST' : 'GET', redirect: 'error', signal: AbortSignal.timeout(12000),
        headers: { Referer: 'https://music.163.com/', 'User-Agent': 'Mozilla/5.0', Cookie: `${cookie}${cookie ? '; ' : ''}os=pc; appver=2.10.13`, ...(data ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
        ...(data ? { body: encryptWeapi({ ...data, csrf_token: /(?:^|;\s*)__csrf=([^;]+)/.exec(cookie)?.[1] || '' }) } : {}),
      });
      if (!response.ok) throw safeError();
      let size = 0; const chunks = [];
      for await (const chunk of response.body) { size += chunk.length; if (size > 12 * 1024 * 1024) throw safeError(); chunks.push(chunk); }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (body.code && ![200,800,801,802,803].includes(body.code)) throw safeError();
      return { body, cookies: response.headers.getSetCookie() };
    } catch { throw safeError(); }
  }
  const get = async (path, cookie) => (await request(path, cookie)).body;
  const track = t => ({ id: String(t.id), name: String(t.name || '未命名歌曲'), artists: (t.ar || t.artists || []).map(a => a.name).join(' / '), duration: Number(t.dt ?? t.duration ?? 0) / 1000, ...(t.al?.picUrl || t.album?.picUrl ? { cover: t.al?.picUrl || t.album?.picUrl } : {}) });
  const playlistSummary = p => ({id:String(p.id),name:String(p.name || ''),trackCount:Number(p.trackCount || p.trackNumber || 0),...(p.coverImgUrl || p.picUrl ? {cover:p.coverImgUrl || p.picUrl}: {})});
  return {
    async startLogin() { const { body } = await request('/weapi/login/qrcode/unikey', '', { type: 1 }); if (!body.unikey) throw safeError(); return { key: body.unikey, url: `https://music.163.com/login?codekey=${encodeURIComponent(body.unikey)}` }; },
    async checkLogin(key) {
      const { body, cookies } = await request('/weapi/login/qrcode/client/login', '', { key, type: 1 });
      const status = {800:'expired',801:'waiting',802:'scanned',803:'success'}[body.code];
      if (!status) throw safeError();
      const cookie = cookies.map(c => c.split(';')[0]).filter(c => /^(MUSIC_U|__csrf|MUSIC_A_T|MUSIC_R_T|NMTID)=/.test(c)).join('; ');
      if (status === 'success' && !cookie.includes('MUSIC_U=')) throw safeError();
      return { status, cookie };
    },
    async account(cookie) { const body = await get('/api/nuser/account/get', cookie); const id = body.profile?.userId || body.account?.id; if (!id) throw businessError('登录已失效，请重新扫码',401); return { id: String(id), nickname: String(body.profile?.nickname || '') }; },
    async playlists(cookie, account) {
      const out = [];
      for (let offset = 0; offset < 50000; offset += 1000) {
        const body = await get(`/api/user/playlist?uid=${account.id}&limit=1000&offset=${offset}`, cookie);
        if (!Array.isArray(body.playlist)) throw safeError();
        out.push(...body.playlist.map(playlistSummary));
        if (!body.more || body.playlist.length === 0) return out;
      }
      throw businessError('歌单过多，暂时无法完整读取');
    },
    async playlist(id, cookie) {
      const body = await get(`/api/v6/playlist/detail?id=${id}&n=1000&s=0`, cookie);
      const p = body.playlist;
      if (!p || !Array.isArray(p.trackIds)) throw safeError();
      if (p.trackIds.length > 50000) throw businessError('歌单超过原型读取上限');
      const known = new Map((p.tracks || []).map(t => [String(t.id), track(t)]));
      const ids = p.trackIds.map(t => String(t.id));
      const missing = ids.filter(id => !known.has(id));
      for (let i=0; i<missing.length; i+=200) {
        const data = await get('/api/song/detail?ids=' + encodeURIComponent(JSON.stringify(missing.slice(i,i+200).map(Number))), cookie);
        if (!Array.isArray(data.songs)) throw safeError();
        for (const t of data.songs) known.set(String(t.id), track(t));
      }
      if (ids.some(id => !known.has(id))) throw businessError('部分歌曲资料不可用，未省略或替换歌曲');
      return ids.map(id => known.get(id));
    },
    async discover(section,cookie='') {
      const body=await get(section==='charts'?'/api/toplist':'/api/personalized/playlist?limit=30',cookie);
      const playlists=section==='charts'?body.list:body.result;
      if(!Array.isArray(playlists))throw safeError();
      return playlists.map(playlistSummary);
    },
    async search(query,offset,limit,cookie='') {
      let body;
      try { body=await get(`/api/cloudsearch/pc?s=${encodeURIComponent(query)}&type=1&offset=${offset}&limit=${limit}`,cookie); }
      catch { body=(await request('/weapi/cloudsearch/get/web',cookie,{s:query,type:1,offset,limit,total:true})).body; }
      if(!body.result)throw safeError();
      return{tracks:(body.result.songs || []).map(track),total:Number(body.result.songCount || 0)};
    },
    async lyrics(id,cookie='') {
      let raw;
      try { raw=await get(`/api/song/lyric/v1?id=${id}&cp=false&lv=0&kv=0&tv=0&rv=0&yv=0&ytv=0&yrv=0`,cookie); }
      catch { raw=await get(`/api/song/lyric?id=${id}&lv=-1&kv=-1&tv=-1&yv=-1`,cookie); }
      if(!raw.yrc?.lyric&&!raw.lrc?.lyric&&!raw.nolyric&&!raw.uncollected) {
        const fallback=await get(`/api/song/lyric?id=${id}&lv=-1&kv=-1&tv=-1&yv=-1`,cookie);
        raw={...raw,...fallback};
      }
      return raw;
    },
    async songUrl(id, cookie) {
      const body = await get('/api/song/enhance/player/url?ids=' + encodeURIComponent(`[${id}]`) + '&br=192000', cookie);
      const d = body.data?.find(t => String(t.id) === id);
      if (!d?.url) throw businessError('此曲暂不可播放，可能受会员、版权或地区限制',403);
      return { url: validateMediaUrl(d.url).href, trial: !!d.freeTrialInfo, gainDb:Number.isFinite(Number(d.gain))?Number(d.gain):0,peak:Number.isFinite(Number(d.peak))?Number(d.peak):0, expires: Date.now() + Math.min(Number(d.expi) || 120, 1200) * 1000 };
    },
    openMedia,
  };
}
