import test from 'node:test';
import assert from 'node:assert/strict';
import {createQqLogin} from '../helper/qq-login.mjs';

const qrId = 'broker-example';
const topic = 'management.qrcode_login/' + qrId;
const image = Buffer.alloc(33);
Buffer.from('89504e470d0a1a0a', 'hex').copy(image);
image.writeUInt32BE(13, 8);
image.write('IHDR', 12);
image.writeUInt32BE(150, 16);
image.writeUInt32BE(150, 20);
const qr = {code:0, data:{qrcodeID:qrId, qrcode:image.toString('base64')}};
const immediate = () => new Promise(resolve => setImmediate(resolve));
const utf8 = value => Buffer.concat([Buffer.from([0, Buffer.byteLength(value)]), Buffer.from(value)]);
const account = {id:'1234567890', nickname:'手机确认'};
const confirmation = JSON.stringify({cookies:{
  qqmusic_uin:{value:account.id}, qqmusic_key:{value:'test-original'},
}});

function packet(header, ...parts) {
  const body = Buffer.concat(parts);
  const size = body.length < 128 ? [body.length] : [128 | body.length % 128, Math.floor(body.length / 128)];
  return Buffer.concat([Buffer.from([header, ...size]), body]);
}

function publish(type, content = '', messageTopic = topic, qos = false) {
  const properties = Buffer.concat([Buffer.from([0x26]), utf8('type'), utf8(type)]);
  return packet(qos ? 0x32 : 0x30, utf8(messageTopic), qos ? Buffer.from([0, 9]) : Buffer.alloc(0),
    Buffer.from([properties.length]), properties, Buffer.from(content));
}

class MockSocket extends EventTarget {
  protocol = 'mqtt';
  sent = [];
  closed = false;
  send(bytes) { this.sent.push(bytes); }
  close() { this.closed = true; this.dispatchEvent(new Event('close')); }
  open() { this.dispatchEvent(new Event('open')); }
  data(bytes) { this.dispatchEvent(new MessageEvent('message', {data:bytes})); }
}

function setup(call = async () => qr) {
  const paths = [];
  const sockets = [];
  const phases = [];
  const api = createQqLogin({call, webSocketFactory(path) {
    paths.push(path);
    const socket = new MockSocket();
    sockets.push(socket);
    return socket;
  }, report:(...entry) => phases.push(entry)});
  return {api, paths, sockets, phases};
}

function acceptConnection(socket) {
  socket.open();
  assert.equal(socket.sent[0][0], 0x10);
  socket.data(Buffer.from([0x20, 3, 0, 0, 0]));
  assert.equal(socket.sent[1][0], 0x82);
  assert.ok(socket.sent[1].includes(Buffer.from(topic)));
}

const subAck = Buffer.from([0x90, 4, 0, 1, 0, 0]);

test('QQ QR stays hidden through route, fragmented SUBACK, and verifies the confirmed session', async t => {
  const calls = [];
  const f = setup(async (_module, method, params, options) => {
    calls.push(method);
    if (method === 'CreateQRCode') {
      assert.deepEqual(params, {tmeAppID:'qqmusic', ct:19, cv:2201});
      return qr;
    }
    if (method === 'Login') {
      assert.equal(params.qrCodeID, qrId);
      assert.equal(params.token, 'test-original');
      assert.equal(options.cookie, undefined);
      return {code:0, data:{musicid:account.id, musickey:'test-exchanged', loginType:2}};
    }
    if (method === 'GetLoginUserInfo') {
      assert.equal(options.cookie.key, 'test-exchanged');
      return {code:0, data:{musicid:account.id, info:{base:{nickName:account.nickname}}}};
    }
    assert.fail('Unexpected request');
  });
  t.after(() => f.api.close());
  let revealed = false;
  const start = f.api.startLogin();
  start.then(() => { revealed = true; });
  await immediate();
  const initial = f.sockets[0];
  initial.open();
  const serverReference = Buffer.concat([Buffer.from([0x1c]), utf8('route.qq.test:443')]);
  initial.data(packet(0x20, Buffer.from([0, 0x9d, serverReference.length]), serverReference));
  assert.deepEqual(f.paths, ['/ws/handshake', '/ws/handshake/route.qq.test:443']);
  assert.equal(initial.closed, true);
  const active = f.sockets[1];
  acceptConnection(active);
  active.data(subAck.subarray(0, 3));
  await immediate();
  assert.equal(revealed, false);
  active.data(subAck.subarray(3));
  const {key, image:png} = await start;
  assert.notEqual(key, qrId);
  assert.deepEqual(png, image);
  assert.deepEqual(f.api.checkLogin(key), {status:'waiting'});
  active.data(publish('scanned', '', 'wrong-topic'));
  assert.equal(f.api.checkLogin(key).status, 'waiting');
  active.data(publish('scanned', '', topic, true));
  assert.equal(f.api.checkLogin(key).status, 'scanned');
  assert.deepEqual(active.sent.at(-1), Buffer.from([0x40, 2, 0, 9]));
  active.data(publish('cookies', confirmation));
  await immediate();
  assert.deepEqual(f.api.checkLogin(key), {
    status:'success', account, cookie:{uin:account.id, key:'test-exchanged', loginType:2},
  });
  assert.equal(active.closed, true);
  assert.deepEqual(calls, ['CreateQRCode', 'Login', 'GetLoginUserInfo']);
  assert.deepEqual(f.phases.map(([, code]) => code), [0, 0x9d, 0, 0, 0, 0]);
});

test('QQ QR handles subscription rejection, handshake cancellation, and late confirmation', async t => {
  let releaseExchange;
  const f = setup(async (_module, method) => {
    if (method === 'CreateQRCode') return qr;
    if (method === 'Login') return new Promise(resolve => { releaseExchange = resolve; });
    assert.fail('Cancelled exchange must not verify account');
  });
  t.after(() => f.api.close());

  const first = f.api.startLogin();
  const firstRejected = assert.rejects(first, {status:502});
  await immediate();
  acceptConnection(f.sockets[0]);
  f.sockets[0].data(Buffer.from([0x90, 4, 0, 1, 0, 0x80]));
  await firstRejected;
  assert.equal(f.sockets[0].closed, true);

  const second = f.api.startLogin();
  const secondRejected = assert.rejects(second, {status:409});
  await immediate();
  acceptConnection(f.sockets[1]);
  assert.equal(f.api.cancelLogin(), true);
  f.sockets[1].data(subAck);
  await secondRejected;
  assert.equal(f.sockets[1].closed, true);

  const third = f.api.startLogin();
  await immediate();
  acceptConnection(f.sockets[2]);
  f.sockets[2].data(subAck);
  const {key} = await third;
  f.sockets[2].data(publish('cookies', confirmation));
  assert.equal(f.api.checkLogin(key).status, 'scanned');
  assert.equal(f.api.cancelLogin(key), true);
  releaseExchange({code:0, data:{musicid:account.id, musickey:'test-exchanged', loginType:2}});
  await immediate();
  assert.equal(f.api.checkLogin(key).status, 'expired');
});


test('QQ QR 保留平台错误原因，凭据校验最多每个候选重试一次',async t => {
  for(const code of [104604,20279,765432]) {
    const f = setup(async () => ({code,data:{}}));
    t.after(() => f.api.close());
    await assert.rejects(f.api.startLogin(), error => {
      if(code===104604)return error.status===429 && /过于频繁/.test(error.message);
      if(code===20279)return error.status===409 && /设备已达上限/.test(error.message);
      return error.status===502 && /错误码 765432/.test(error.message);
    });
  }
  let verifies = 0;
  const f = setup(async (_module,method) => {
    if(method==='CreateQRCode')return qr;
    if(method==='Login')return {code:0,data:{musicid:account.id,musickey:'test-exchanged',loginType:2}};
    verifies++;
    return {code:104400,data:{}};
  });
  t.after(() => f.api.close());
  const start = f.api.startLogin();
  await immediate();
  acceptConnection(f.sockets[0]);f.sockets[0].data(subAck);
  const {key} = await start;
  f.sockets[0].data(publish('cookies',confirmation));
  for(let attempt=0;attempt<100 && f.api.checkLogin(key).status==='scanned';attempt++) {
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  assert.equal(verifies,4);
  assert.equal(f.api.checkLogin(key).status,'failed');
  assert.match(f.api.checkLogin(key).error,/登录已失效/);
  f.sockets[0].data(publish('cookies',confirmation));
  await immediate();
  assert.equal(verifies,4);
});
