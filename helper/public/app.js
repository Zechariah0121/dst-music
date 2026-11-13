'use strict';
const $ = id => document.getElementById(id);
const params = new URLSearchParams(location.hash.slice(1));
const incomingToken = params.get('token');
if (incomingToken) {
  sessionStorage.setItem('dst-music-token', incomingToken);
  history.replaceState(null, '', location.pathname);
}
const token = incomingToken || sessionStorage.getItem('dst-music-token');
const audio = $('audio');
const clientId = crypto.randomUUID();
let enabled = false, disposed = false, revision = -1, appliedTrack = null, appliedSeekRevision = -1;
let desiredPlaying = false, playerError = '', pendingEnded = false, reporting = false;
let selectedPlaylist = null, tracks = [], total = 0, accountId = null, loginGeneration = 0;
let playlistsLoading = false, trackGeneration = 0, applying = false, statusBusy = false;

function notice(message) { $('notice').textContent = message || ''; $('notice').hidden = !message; }
function time(seconds) { const n = Math.max(0, Math.floor(Number(seconds) || 0)); return `${Math.floor(n / 60)}:${String(n % 60).padStart(2, '0')}`; }
async function api(path, body) {
  if (!token) throw new Error('请使用项目里的“启动播放器”重新打开这个页面。');
  // This legacy browser diagnostic page manages NetEase only. The in-game
  // source selector must not relabel a QQ account as a NetEase account here.
  if (['status','playlists','login/start','logout'].includes(path.split('?')[0])) {
    if (body === undefined) path += (path.includes('?') ? '&' : '?') + 'provider=netease';
    else body = {...body,provider:'netease'};
  }
  const response = await fetch(`/api/${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {Authorization: `Bearer ${token}`, ...(body === undefined ? {} : {'Content-Type':'application/json'})},
    ...(body === undefined ? {} : {body:JSON.stringify(body)}),
    signal: AbortSignal.timeout(25000), cache:'no-store'
  });
  const result = await response.json();
  if (!response.ok || result.ok === false) { const error=new Error(result.error || '本机服务暂时不可用。'); error.status=response.status; throw error; }
  return result;
}
async function run(button, task) {
  if (button) button.disabled = true;
  try { await task(); } catch(error) { notice(error.message); }
  finally { if (button) button.disabled = false; }
}
async function control(action, extra = {}) { await api('control', {action,...extra}); }
function updateTrack(player) {
  const track = player.track;
  $('track-name').textContent = track ? `${track.name}${track.trial ? ' · 试听' : ''}` : '还没有正在播放的歌曲';
  $('track-artist').textContent = track ? track.artists : '从歌单里，挑一首喜欢的吧';
  $('toggle').textContent = player.playing ? 'Ⅱ' : '▶';
  $('position').textContent = time(player.position);
  $('duration').textContent = time(player.duration || track?.duration);
  if (document.activeElement !== $('seek')) {
    $('seek').max = String(Math.max(1, player.duration || track?.duration || 1));
    $('seek').value = String(player.position || 0);
  }
  if (document.activeElement !== $('volume')) {
    $('volume').value = String(Math.round((player.volume ?? .7)*100));
    $('volume-value').textContent = `${$('volume').value}%`;
  }
  document.querySelectorAll('.track-row').forEach(row => row.classList.toggle('active', String(track?.id) === row.dataset.id));
}
async function refreshStatus() {
  if (statusBusy || disposed) return;
  statusBusy = true;
  try {
    const state = await api('status');
    $('connection-dot').classList.add('connected');
    $('connection-label').textContent = state.playerConnected ? '后台播放器已连接' : '本机服务已连接';
    $('account-button').textContent = state.account ? `${state.account.nickname} · 退出` : '登录网易云 ↗';
    $('step-login').classList.toggle('done', !!state.account);
    $('step-login').textContent = state.account ? '✓' : '2';
    const nextAccount = state.account ? String(state.account.id) : null;
    if (nextAccount !== accountId) {
      accountId = nextAccount;
      if (accountId) await loadPlaylists();
      else { trackGeneration++; $('library-content').hidden = true; $('empty-library').hidden = false; selectedPlaylist = null; tracks = []; }
    }
    updateTrack(state.player);
    if (state.player.error) notice(state.player.error);
  } catch(error) {
    $('connection-dot').classList.remove('connected');
    $('connection-label').textContent = '本机服务未连接';
    notice(error.message);
  } finally { statusBusy = false; }
}
async function loadPlaylists() {
  if (playlistsLoading) return;
  playlistsLoading = true;
  try {
    const result = await api('playlists');
    $('playlists').replaceChildren();
    $('empty-library').hidden = true; $('library-content').hidden = false;
    if (!result.playlists.length) { $('playlist-name').textContent = '账号里暂时没有可显示的歌单'; return; }
    for (const list of result.playlists) {
      const button = document.createElement('button'); button.className = 'playlist-button'; button.dataset.id = String(list.id);
      const name = document.createElement('strong'); name.textContent = list.name;
      const count = document.createElement('span'); count.textContent = `${list.trackCount} 首歌曲`;
      button.append(name, count); button.addEventListener('click', () => run(button, () => selectPlaylist(list)));
      $('playlists').append(button);
    }
    if (selectedPlaylist) {
      const same = result.playlists.find(p => String(p.id) === String(selectedPlaylist.id));
      if (same) await selectPlaylist(same); else await selectPlaylist(result.playlists[0]);
    } else await selectPlaylist(result.playlists[0]);
  } finally { playlistsLoading = false; }
}
async function selectPlaylist(list) {
  selectedPlaylist = list; tracks = []; total = 0; const gen = ++trackGeneration;
  $('playlist-name').textContent = list.name; $('track-count').textContent = '';
  $('tracks').replaceChildren(); $('load-more').hidden = true;
  document.querySelectorAll('.playlist-button').forEach(b => b.classList.toggle('active', b.dataset.id === String(list.id)));
  await loadTracks(gen);
}
async function loadTracks(gen = trackGeneration) {
  if (!selectedPlaylist) return;
  const listId = selectedPlaylist.id;
  const result = await api(`playlist?id=${encodeURIComponent(listId)}&offset=${tracks.length}&limit=50`);
  if (gen !== trackGeneration) return;
  const previousLength = tracks.length; tracks.push(...result.tracks); total = result.total;
  $('track-count').textContent = `${total} 首`;
  result.tracks.forEach((track,index) => {
    const button = document.createElement('button'); button.className = 'track-row'; button.dataset.id = String(track.id);
    const number = document.createElement('span'); number.className='track-index'; number.textContent = String(previousLength+index+1).padStart(2,'0');
    const info=document.createElement('span'), title=document.createElement('span'), artist=document.createElement('span'), length=document.createElement('span');
    title.className='track-title'; title.textContent=track.name; artist.className='track-subtitle'; artist.textContent=track.artists;
    length.className='track-time'; length.textContent=time(track.duration); info.append(title,artist); button.append(number,info,length);
    button.addEventListener('click', () => run(button, async () => { await control('play',{playlistId:listId,trackId:track.id}); notice(''); }));
    $('tracks').append(button);
  });
  $('load-more').hidden = tracks.length >= total || !result.tracks.length;
}
async function startLogin() {
  const gen = ++loginGeneration;
  if (!$('login-dialog').open) $('login-dialog').showModal();
  $('qr-code').replaceChildren(); $('login-status').textContent = '正在生成二维码…'; $('refresh-qr').hidden = true;
  try {
    const result = await api('login/start', {});
    if (gen !== loginGeneration) return;
    if (typeof qrcode === 'function') {
      const qr = qrcode(0,'M'); qr.addData(result.url); qr.make();
      const box = document.createElement('div'); box.innerHTML = qr.createSvgTag({cellSize:4,margin:8,scalable:true}); $('qr-code').append(box);
    } else {
      $('qr-code').textContent = '二维码组件缺失，请重新下载完整项目。';
      throw new Error('二维码组件缺失。');
    }
    $('login-status').textContent = '等待扫码';
    const pollLogin = async () => {
      if (gen !== loginGeneration || disposed) return;
      try {
        const check = await api(`login/check?key=${encodeURIComponent(result.key)}`);
        if (gen !== loginGeneration) return;
        if (check.status === 'success') { $('login-dialog').close(); notice('登录成功，你的歌单正在路上。'); await refreshStatus(); return; }
        if (check.status === 'expired') { $('login-status').textContent = '二维码已过期，请重新生成。'; $('refresh-qr').hidden = false; return; }
        $('login-status').textContent = check.status === 'scanned' ? '已扫码，请在手机上确认登录。' : '等待扫码';
        setTimeout(pollLogin,2300);
      } catch(error) { if(gen !== loginGeneration) return; $('login-status').textContent=error.message; $('refresh-qr').hidden=false; }
    };
    setTimeout(pollLogin,1800);
  } catch(error) { if(gen !== loginGeneration) return; $('login-status').textContent=error.message; $('refresh-qr').hidden=false; }
}
function makeSilence() {
  const buffer=new ArrayBuffer(844), view=new DataView(buffer); const put=(offset,text)=>[...text].forEach((c,i)=>view.setUint8(offset+i,c.charCodeAt(0)));
  put(0,'RIFF'); view.setUint32(4,836,true); put(8,'WAVE'); put(12,'fmt '); view.setUint32(16,16,true); view.setUint16(20,1,true); view.setUint16(22,1,true); view.setUint32(24,8000,true); view.setUint32(28,16000,true); view.setUint16(32,2,true); view.setUint16(34,16,true); put(36,'data'); view.setUint32(40,800,true);
  return URL.createObjectURL(new Blob([buffer],{type:'audio/wav'}));
}
async function enablePlayer() {
  // Call play synchronously from the click, before any HTTP await, to unlock audio.
  const silentUrl = makeSilence(); audio.src = silentUrl; const unlock = audio.play();
  try {
    await unlock; audio.pause(); audio.removeAttribute('src'); audio.load();
    await api('player/claim',{clientId}); enabled=true; revision=-1; playerError='';
    $('enable-player').textContent='后台播放器已启用 ✓'; $('enable-player').disabled=true;
    $('step-player').classList.add('done'); $('step-player').textContent='✓';
    notice('后台播放器已启用。保留这个页面，回到饥荒后可按 F8 打开音乐面板。');
    await pollPlayer(); await report();
  } finally { URL.revokeObjectURL(silentUrl); }
}
async function pollPlayer() {
  if (!enabled || applying || disposed) return;
  applying=true;
  try {
    const {desired} = await api(`player/state?clientId=${encodeURIComponent(clientId)}`);
    if (desired.revision === revision) return;
    const previousRevision = revision; revision=desired.revision;
    const seekChanged = desired.seekRevision !== appliedSeekRevision;
    appliedSeekRevision = desired.seekRevision;
    const changedTrack=String(desired.track?.id) !== String(appliedTrack) || (!audio.getAttribute('src') && desired.mediaUrl);
    desiredPlaying=desired.playing; audio.volume=desired.volume; playerError=''; pendingEnded=false;
    if (changedTrack) {
      audio.pause(); appliedTrack=desired.track?.id ?? null;
      if (desired.mediaUrl) {
        const url = new URL(desired.mediaUrl,location.origin);
        if (url.origin !== location.origin) throw new Error('播放地址不是本机服务地址。');
        url.searchParams.set('token',token); audio.src=url.href;
      } else { audio.removeAttribute('src'); audio.load(); }
    }
    if (desired.track) {
      const target=Number(desired.position)||0;
      if (changedTrack || previousRevision < 0 || seekChanged) audio.currentTime=target;
      if(desired.playing) await audio.play(); else audio.pause();
    } else audio.pause();
  } catch(error) {
    playerError=error.name === 'NotAllowedError' ? '浏览器需要你点击一次播放按钮，才能继续播放。' : error.message;
    if(error.status===409) { enabled=false; audio.pause(); $('enable-player').disabled=false; $('enable-player').textContent='重新连接播放器 →'; $('step-player').classList.remove('done'); $('step-player').textContent='1'; }
    notice(playerError);
  }
  finally { applying=false; }
}
async function report() {
  if (!enabled || reporting || disposed || revision < 0) return;
  reporting=true;
  const ended = pendingEnded;
  try {
    await api('player/report',{clientId,revision,position:audio.currentTime||0,duration:Number.isFinite(audio.duration)?audio.duration:0,playing:!audio.paused&&!audio.ended,error:playerError,ended});
    if(ended) pendingEnded=false;
  } catch(error) { notice(error.message); }
  finally { reporting=false; }
}
audio.addEventListener('ended',()=>{ if(revision>=0 && desiredPlaying) {pendingEnded=true;report();} });
audio.addEventListener('error',()=>{ if(enabled && appliedTrack) {playerError='音频加载失败。请重试这首歌，或确认该账号可以播放它。';notice(playerError);report();} });
$('enable-player').addEventListener('click',()=>run($('enable-player'),enablePlayer).then(()=>{ if(enabled) $('enable-player').disabled=true; }));
$('account-button').addEventListener('click',()=>run($('account-button'),async()=>{ if(accountId) {await api('logout',{});notice('已退出网易云。');await refreshStatus();} else await startLogin(); }));
$('empty-login').addEventListener('click',startLogin); $('refresh-qr').addEventListener('click',startLogin);
$('close-login').addEventListener('click',()=>$('login-dialog').close()); $('login-dialog').addEventListener('close',()=>{loginGeneration++;});
$('refresh-library').addEventListener('click',()=>run($('refresh-library'),async()=>{await loadPlaylists();notice('');}));
$('load-more').addEventListener('click',()=>run($('load-more'),()=>loadTracks()));
$('previous').addEventListener('click',()=>run(null,()=>control('previous'))); $('next').addEventListener('click',()=>run(null,()=>control('next')));
$('toggle').addEventListener('click',()=>run(null,async()=>{if(enabled&&audio.paused&&audio.src&&desiredPlaying) {await audio.play();playerError='';notice('');} else await control('toggle');}));
$('volume').addEventListener('input',()=>{$('volume-value').textContent=`${$('volume').value}%`;});
$('volume').addEventListener('change',()=>run(null,()=>control('volume',{value:Number($('volume').value)/100})));
$('seek').addEventListener('change',()=>run(null,()=>control('seek',{value:Number($('seek').value)})));
window.addEventListener('pagehide',()=>{disposed=true;audio.pause();});
setInterval(refreshStatus,1800); setInterval(pollPlayer,700); setInterval(report,1000); refreshStatus();
