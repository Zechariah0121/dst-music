// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Sorihiko/DangoMusic NativeLogin.kt, QqAppChannel.kt and QqAppSession.kt
// (7d1609d6b259a6b439542058b3f8f0c5969b6e2b).
import {createHash, randomBytes, randomInt, randomUUID} from 'node:crypto';
import https from 'node:https';
import {setTimeout as delay} from 'node:timers/promises';
import {decodeQqText} from './qq-lyrics.mjs';

const LOGIN = 'music.login.LoginServer';
const PROFILE = 'music.UserInfo.userInfoServer';
const MQTT_HOST = 'mu.y.qq.com';
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const PNG_HEADER = Buffer.from('89504e470d0a1a0a', 'hex');
const MAX_PACKET = 1024 * 1024;
const EXPIRED = new Set([1000, 104400, 104401]);

export function qqError(message, status = 502) {
  return Object.assign(new Error(message), {status});
}

export function validQqCredentials(value) {
  return value && typeof value.uin === 'string' && /^[1-9][0-9]{0,18}$/.test(value.uin) &&
    typeof value.key === 'string' && /^[\x21-\x3a\x3c-\x7e]{1,2048}$/.test(value.key) &&
    Number.isSafeInteger(value.loginType) && value.loginType >= 1 && value.loginType <= 99;
}

function credential(uin, key, type) {
  const value = {uin:String(uin ?? ''), key, loginType:Number(type ?? (key?.startsWith?.('W_X') ? 1 : 2))};
  return validQqCredentials(value) ? value : null;
}

export function qqProfile(data, uin) {
  const identity = data?.musicid || data?.str_musicid;
  if (identity && String(identity) !== uin) return null;
  const profiles = [data?.info, data?.userInfo, data?.userinfo, data?.profile, data?.base];
  const rows = [data, ...profiles.flatMap(row => [row, row?.base])];
  for (const row of rows) {
    const value = decodeQqText(row?.nick || row?.nickname || row?.nickName).trim();
    if (value) return {id:uin, nickname:value.slice(0, 256)};
  }
  return {id:uin, nickname:'QQ 音乐账号'};
}

function loginError(code) {
  if (EXPIRED.has(code)) return qqError('QQ 音乐登录已失效，请重新扫码', 401);
  if (code === 20279) return qqError('QQ 音乐登录设备已达上限，请在客户端管理登录设备后重试', 409);
  if (code === 104604) return qqError('QQ 音乐扫码请求过于频繁，请稍后重试', 429);
  return qqError(Number.isSafeInteger(code) && code !== 0 ? `QQ 音乐拒绝了本次登录（错误码 ${code}），请稍后重试` : 'QQ 音乐登录校验未返回有效账号，请稍后重试');
}

function variable(value) {
  const digits = [];
  do {
    const digit = value % 128;
    value = Math.floor(value / 128);
    digits.push(digit + (value ? 128 : 0));
  } while (value);
  return Buffer.from(digits);
}

function uint16(value) {
  return Buffer.from([value >> 8, value & 255]);
}

function utf8(value) {
  const bytes = Buffer.from(value, 'utf8');
  return Buffer.concat([uint16(bytes.length), bytes]);
}

function userProperties(pairs) {
  return Buffer.concat(pairs.flatMap(([name, value]) => [Buffer.from([0x26]), utf8(name), utf8(value)]));
}

class Cursor {
  constructor(bytes) {
    this.bytes = bytes;
    this.offset = 0;
  }

  get remaining() { return this.bytes.length - this.offset; }

  take(length) {
    if (length > this.remaining) throw new Error('Invalid MQTT packet');
    const start = this.offset;
    this.offset += length;
    return this.bytes.subarray(start, this.offset);
  }

  byte() { return this.take(1)[0]; }
  uint16() { return this.take(2).readUInt16BE(); }
  string() { return this.take(this.uint16()).toString('utf8'); }

  variable() {
    let value = 0;
    for (let shift = 0; shift <= 21; shift += 7) {
      const digit = this.byte();
      value += (digit & 127) * 2 ** shift;
      if (digit < 128) return value;
    }
    throw new Error('Invalid MQTT packet length');
  }

  properties() {
    const bytes = this.take(this.variable());
    const props = new Cursor(bytes);
    const values = Object.create(null);
    while (props.remaining) {
      const kind = props.byte();
      switch (kind) {
        case 0x26: values[props.string()] = props.string(); break;
        case 0x1c: values.server = props.string(); break;
        case 0x13: values.keepalive = props.uint16(); break;
        case 0x01: case 0x17: case 0x19: case 0x24: case 0x25: case 0x28: case 0x29: case 0x2a: props.take(1); break;
        case 0x21: case 0x22: case 0x23: props.take(2); break;
        case 0x02: case 0x11: case 0x18: case 0x27: props.take(4); break;
        case 0x0b: props.variable(); break;
        case 0x03: case 0x08: case 0x09: case 0x12: case 0x15: case 0x16: case 0x1a: case 0x1f: props.take(props.uint16()); break;
        default: throw new Error('Unknown MQTT property');
      }
    }
    return values;
  }
}

function createSocket(path) {
  const events = new EventTarget();
  const key = randomBytes(16).toString('base64');
  const accept = createHash('sha1').update(key + WS_GUID).digest('base64');
  const request = https.request({
    hostname:MQTT_HOST, path, maxHeaderSize:16384,
    headers:{
      Connection:'Upgrade', Upgrade:'websocket', 'Sec-WebSocket-Key':key, 'Sec-WebSocket-Version':'13',
      'Sec-WebSocket-Protocol':'mqtt', Origin:'https://y.qq.com', Referer:'https://y.qq.com/', 'User-Agent':'Mozilla/5.0',
    },
  });
  let socket, closed = false;
  let pending = Buffer.alloc(0);
  let fragments = [], fragmentedLength = 0;

  function close() {
    if (closed) return;
    closed = true;
    if (socket) socket.destroy();
    else request.destroy();
  }

  function fail() {
    if (closed) return;
    close();
    events.dispatchEvent(new Event('error'));
  }

  function frame(opcode, payload) {
    if (closed || !socket) throw new Error('QQ WebSocket closed');
    if (payload.length > 65535) throw new Error('QQ WebSocket frame too large');
    const size = payload.length < 126 ? Buffer.from([128 + payload.length]) : Buffer.concat([Buffer.from([254]), uint16(payload.length)]);
    const mask = randomBytes(4);
    const masked = Buffer.from(payload);
    for (let index = 0; index < masked.length; index++) masked[index] ^= mask[index % 4];
    socket.write(Buffer.concat([Buffer.from([128 | opcode]), size, mask, masked]));
  }

  function receive(chunk) {
    try {
      if (pending.length + chunk.length > MAX_PACKET + 10) throw new Error('QQ WebSocket frame too large');
      pending = Buffer.concat([pending, chunk]);
      while (!closed && pending.length >= 2) {
        const first = pending[0], second = pending[1];
        if (first & 0x70 || second & 0x80) throw new Error('Invalid QQ WebSocket frame');
        const opcode = first & 15;
        const fin = Boolean(first & 128);
        let length = second;
        let offset = 2;
        if (second === 126) {
          if (pending.length < 4) return;
          length = pending.readUInt16BE(2);
          offset = 4;
        } else if (second === 127) {
          if (pending.length < 10) return;
          const wide = pending.readBigUInt64BE(2);
          if (wide > BigInt(MAX_PACKET)) throw new Error('QQ WebSocket frame too large');
          length = Number(wide);
          offset = 10;
        }
        if (opcode >= 8 && (!fin || length > 125)) throw new Error('Invalid QQ WebSocket control frame');
        if (pending.length < offset + length) return;
        const payload = pending.subarray(offset, offset + length);
        pending = pending.subarray(offset + length);
        if (opcode === 8) { fail(); return; }
        if (opcode === 9) { frame(10, payload); continue; }
        if (opcode === 10) continue;
        if (opcode === 2 && !fragments.length && fin) {
          events.dispatchEvent(new MessageEvent('message', {data:payload}));
          continue;
        }
        if ((opcode === 2 && fragments.length) || (opcode === 0 && !fragments.length) || ![0, 2].includes(opcode)) {
          throw new Error('Unexpected QQ WebSocket frame');
        }
        fragments.push(payload);
        fragmentedLength += payload.length;
        if (fragmentedLength > MAX_PACKET || fragments.length > 4096) throw new Error('QQ WebSocket message too large');
        if (fin) {
          const data = Buffer.concat(fragments, fragmentedLength);
          fragments = [];
          fragmentedLength = 0;
          events.dispatchEvent(new MessageEvent('message', {data}));
        }
      }
    } catch { fail(); }
  }

  request.on('error', fail);
  request.on('response', response => { response.destroy(); fail(); });
  request.on('upgrade', (response, upgraded, head) => {
    if (closed) { upgraded.destroy(); return; }
    socket = upgraded;
    socket.on('error', fail);
    socket.on('close', fail);
    if (response.statusCode !== 101 || response.headers.upgrade?.toLowerCase() !== 'websocket' ||
        response.headers['sec-websocket-accept'] !== accept || response.headers['sec-websocket-protocol'] !== 'mqtt' ||
        response.headers['sec-websocket-extensions']) { fail(); return; }
    socket.on('data', receive);
    events.dispatchEvent(new Event('open'));
    if (head.length) receive(head);
  });
  request.end();
  return {protocol:'mqtt', addEventListener:events.addEventListener.bind(events), send:payload => frame(2, payload), close};
}

function connectChannel(qrId, {signal, webSocketFactory, handshakeMs, onEvent, onFailure, report}) {
  const topic = 'management.qrcode_login/' + qrId;
  let socket, pingTimer;
  let stopped = false, subscribed = false;
  let attempts = 0;
  const ready = Promise.withResolvers();
  const handshakeTimer = setTimeout(() => fail('QQ 音乐扫码连接超时，请重试'), handshakeMs);
  handshakeTimer.unref();
  signal.addEventListener('abort', cancelled, {once:true});

  function close() {
    if (stopped) return;
    stopped = true;
    clearInterval(pingTimer);
    clearTimeout(handshakeTimer);
    signal.removeEventListener('abort', cancelled);
    try { socket?.close(); } catch { /* The connection may already be closed. */ }
  }

  function cancelled() {
    close();
    ready.reject(qqError('QQ 音乐扫码已取消', 409));
  }

  function fail(message = 'QQ 音乐扫码连接中断，请重新扫码') {
    if (stopped) return;
    close();
    const error = qqError(message);
    if (subscribed) onFailure(error);
    else ready.reject(error);
  }

  function send(header, ...parts) {
    if (stopped) return;
    const body = Buffer.concat(parts);
    socket.send(Buffer.concat([Buffer.from([header]), variable(body.length), body]));
  }

  function open(path) {
    attempts++;
    const active = webSocketFactory(path);
    socket = active;
    active.binaryType = 'arraybuffer';
    let pending = Buffer.alloc(0);
    let step = 'connect';
    let keepalive = 20000;

    active.addEventListener('open', () => {
      if (stopped || socket !== active) return;
      try {
        if (active.protocol !== 'mqtt') throw new Error('Unexpected WebSocket protocol');
        const properties = Buffer.concat([
          Buffer.from([0x15]), utf8('pass'),
          userProperties([['tmeAppID', 'qqmusic'], ['business', 'management'], ['hashTag', qrId],
            ['clientTag', 'management.user'], ['userID', qrId]]),
        ]);
        send(0x10, utf8('MQTT'), Buffer.from([5, 2]), uint16(45), variable(properties.length), properties,
          utf8(`${Date.now()}${randomInt(1000, 10000)}`));
      } catch { fail(); }
    });
    active.addEventListener('error', () => { if (socket === active) fail(); });
    active.addEventListener('close', () => { if (socket === active) fail(); });
    active.addEventListener('message', ({data}) => {
      if (stopped || socket !== active) return;
      try {
        if (!(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) throw new Error('Invalid WebSocket message');
        const bytes = ArrayBuffer.isView(data) ? Buffer.from(data.buffer, data.byteOffset, data.byteLength) : Buffer.from(data);
        if (pending.length + bytes.length > MAX_PACKET) throw new Error('MQTT packet too large');
        pending = Buffer.concat([pending, bytes]);
        while (!stopped && socket === active && pending.length >= 2) {
          let offset = 1, length = 0;
          while (offset < pending.length && offset <= 4) {
            const digit = pending[offset++];
            length += (digit & 127) * 128 ** (offset - 2);
            if (digit < 128) break;
            if (offset === 5) throw new Error('Invalid MQTT packet length');
          }
          if (length > MAX_PACKET) throw new Error('MQTT packet too large');
          if (pending[offset - 1] >= 128 || pending.length < offset + length) break;
          const header = pending[0];
          const packet = new Cursor(pending.subarray(offset, offset + length));
          pending = pending.subarray(offset + length);
          receive(header, packet);
        }
      } catch { fail(); }
    });

    function receive(header, packet) {
      if (step === 'connect') {
        if (header !== 0x20 || packet.byte() !== 0) throw new Error('Expected MQTT connect acknowledgement');
        const reason = packet.byte();
        const properties = packet.properties();
        report('qr-connect', reason);
        if (reason === 0x9c || reason === 0x9d) {
          if (attempts >= 4 || !/^[A-Za-z0-9_.:-]{1,128}$/.test(properties.server ?? '') ||
              properties.server === '.' || properties.server === '..') throw new Error('Invalid MQTT route');
          socket = null;
          active.close();
          open('/ws/handshake/' + properties.server);
          return;
        }
        if (reason !== 0) throw new Error('MQTT connection rejected');
        if (properties.keepalive > 0) keepalive = Math.max(1000, Math.min(20000, properties.keepalive * 500));
        const props = userProperties([['authorization', 'tmelogin'], ['pubsub', 'unicast']]);
        step = 'subscribe';
        send(0x82, uint16(1), variable(props.length), props, utf8(topic), Buffer.from([0]));
        return;
      }
      if (step === 'subscribe') {
        if (header !== 0x90 || packet.uint16() !== 1) throw new Error('Expected MQTT subscription acknowledgement');
        packet.properties();
        const reason = packet.byte();
        report('qr-subscribe', reason);
        if (reason >= 128) throw new Error('MQTT subscription rejected');
        step = 'subscribed';
        subscribed = true;
        clearTimeout(handshakeTimer);
        pingTimer = setInterval(() => { try { send(0xc0); } catch { fail(); } }, keepalive);
        pingTimer.unref();
        ready.resolve();
        return;
      }
      if (header === 0xd0) return;
      if (header >> 4 !== 3) throw new Error('Unexpected MQTT packet');
      const incomingTopic = packet.string();
      const qos = (header >> 1) & 3;
      if (qos > 1) throw new Error('Unexpected MQTT quality of service');
      const id = qos === 1 ? packet.uint16() : 0;
      const props = packet.properties();
      if (qos === 1) send(0x40, uint16(id));
      if (incomingTopic === topic) onEvent(props.type, packet.take(packet.remaining));
    }
  }

  try { if (signal.aborted) cancelled(); else open('/ws/handshake'); } catch { fail(); }
  return {ready:ready.promise, close};
}

function qrImage(value) {
  if (typeof value !== 'string') throw qqError('QQ 音乐没有返回有效二维码');
  const encoded = value.replace(/^data:image\/png;base64,/i, '');
  if (encoded.length > Math.ceil(MAX_PACKET / 3) * 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
    throw qqError('QQ 音乐没有返回有效二维码');
  }
  const image = Buffer.from(encoded, 'base64');
  if (image.length < 33 || image.length > MAX_PACKET || !image.subarray(0, 8).equals(PNG_HEADER) ||
      image.readUInt32BE(8) !== 13 || image.toString('ascii', 12, 16) !== 'IHDR' ||
      [image.readUInt32BE(16), image.readUInt32BE(20)].some(dimension => dimension < 32 || dimension > 1024)) {
    throw qqError('QQ 音乐没有返回有效二维码');
  }
  return image;
}

export function createQqLogin({call, now = Date.now, webSocketFactory = createSocket, report = () => {},
                               lifetimeMs = 180_000, handshakeMs = 30_000}) {
  let current;
  let closed = false;

  function cancelLogin(key) {
    if (!current || (key !== undefined && key !== current.key)) return false;
    const session = current;
    current = undefined;
    clearTimeout(session.timer);
    session.controller.abort();
    session.channel?.close();
    return true;
  }

  function complete(session, status, fields = {}) {
    if (current !== session || session.controller.signal.aborted || ['success','failed','expired','canceled'].includes(session.result.status)) return;
    session.result = {status, ...fields};
    session.channel?.close();
  }

  async function confirm(session, bytes, qrId) {
    let payload;
    try { payload = JSON.parse(bytes.toString('utf8')); } catch { throw qqError('QQ 音乐手机确认数据无效'); }
    const original = credential(payload?.cookies?.qqmusic_uin?.value, payload?.cookies?.qqmusic_key?.value);
    if (!original) throw qqError('QQ 音乐手机确认未提供有效凭据');
    const signal = session.controller.signal;
    signal.throwIfAborted();
    const id = Number(original.uin);
    const exchange = await call(LOGIN, 'Login', {
      musicid:Number.isSafeInteger(id) ? id : JSON.rawJSON(original.uin),
      qrCodeID:qrId, token:original.key, loginType:6, needCookie:1,
    }, {comm:{ct:19, cv:2201, tmeLoginType:6}, signal});
    report('qr-exchange', exchange.code);
    signal.throwIfAborted();
    const data = exchange.data;
    const converted = exchange.code === 0 && credential(data?.musicid || data?.str_musicid, data?.musickey, data?.loginType);
    const candidates = converted?.uin === original.uin ? [converted, original] : [original];
    let lastCode;
    for (const cookie of candidates) {
      let verified = await call(PROFILE, 'GetLoginUserInfo', {}, {cookie, signal});
      report('qr-verify', verified.code);
      if (EXPIRED.has(verified.code)) {
        await delay(350, undefined, {signal});
        verified = await call(PROFILE, 'GetLoginUserInfo', {}, {cookie, signal});
        report('qr-verify', verified.code);
      }
      signal.throwIfAborted();
      lastCode = verified.code;
      if (verified.code !== 0 || !verified.data || !Object.keys(verified.data).length) continue;
      const account = qqProfile(verified.data, cookie.uin);
      if (account) return {cookie, account};
    }
    throw loginError(exchange.code !== 0 && !EXPIRED.has(exchange.code) ? exchange.code : lastCode);
  }

  async function startLogin() {
    if (closed) throw qqError('QQ 音乐扫码服务已关闭', 409);
    cancelLogin();
    const session = {key:randomUUID(), controller:new AbortController(), result:{status:'waiting'}};
    current = session;
    const signal = session.controller.signal;
    try {
      const {code, data} = await call(LOGIN, 'CreateQRCode', {tmeAppID:'qqmusic', ct:19, cv:2201},
        {comm:{ct:23, cv:0}, signal});
      report('qr-create', code);
      signal.throwIfAborted();
      if (code !== 0) throw loginError(code);
      const qrId = data?.qrcodeID;
      if (typeof qrId !== 'string' || !/^[A-Za-z0-9_-]{1,256}$/.test(qrId)) {
        throw qqError('QQ 音乐没有返回有效二维码');
      }
      const image = qrImage(data.qrcode);
      session.expiresAt = now() + lifetimeMs;
      session.timer = setTimeout(() => {
        if (current !== session) return;
        if (['success', 'failed', 'canceled'].includes(session.result.status)) {
          cancelLogin(session.key);
          return;
        }
        session.result = {status:'expired'};
        session.controller.abort();
        session.channel?.close();
      }, lifetimeMs);
      session.timer.unref();
      session.channel = connectChannel(qrId, {
        signal, webSocketFactory, handshakeMs, report,
        onFailure:error => { if (!session.confirming) complete(session, 'failed', {error:error.message}); },
        onEvent(type, bytes) {
          if (current !== session || session.confirming || !['waiting', 'scanned'].includes(session.result.status)) return;
          if (type === 'scanned') session.result = {status:'scanned'};
          if (type === 'timeout') complete(session, 'expired');
          if (type === 'canceled') complete(session, 'canceled', {error:'已在手机上取消 QQ 音乐登录'});
          if (type === 'loginFailed') complete(session, 'failed', {error:'QQ 音乐拒绝了本次登录，请重新扫码'});
          if (type !== 'cookies') return;
          session.result = {status:'scanned'};
          session.confirming = true;
          session.channel?.close();
          confirm(session, bytes, qrId).then(
            auth => complete(session, 'success', auth),
            error => complete(session, 'failed', {error:error.status ? error.message : 'QQ 音乐登录校验失败，请重新扫码'}),
          );
        },
      });
      await session.channel.ready;
      signal.throwIfAborted();
      return {key:session.key, image};
    } catch (error) {
      cancelLogin(session.key);
      throw error.status ? error : qqError('QQ 音乐扫码已取消', 409);
    }
  }

  function checkLogin(key) {
    if (!current || current.key !== key) return {status:'expired'};
    if (current.expiresAt < now()) {
      cancelLogin(key);
      return {status:'expired'};
    }
    return current.result;
  }

  return {
    startLogin, checkLogin, cancelLogin,
    close() { closed = true; cancelLogin(); },
  };
}
