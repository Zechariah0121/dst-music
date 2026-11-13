import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm, stat, symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {createGameAssets, validateCoverUrl, validateQrUrl} from '../helper/game-assets.mjs';

async function fixture(t, runtime = true) {
  const root = await mkdtemp(join(tmpdir(), 'dango-assets-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const stateDir = join(root, 'state'), modDir = join(root, 'mod');
  const runtimeModDir = runtime ? join(root, typeof runtime === 'string' ? runtime : 'installed/local_netease_music') : undefined;
  if (runtime) {
    await mkdir(runtimeModDir, {recursive: true});
    if (typeof runtime === 'string') await writeFile(join(runtimeModDir, 'music_workshop_identity.json'),
      JSON.stringify({schema:1,id:'zcc-dst-music',channel:'workshop-beta'}));
    else await writeFile(join(runtimeModDir, 'music_bridge_owned.txt'), 'dst-local-music-prototype-v1\n');
  }
  return {root, stateDir, modDir, runtimeModDir, assets: createGameAssets({stateDir, modDir, runtimeModDir, ktechPath:'missing-should-not-run'})};
}

test('only allows NetEase and known QQ image origins and exact QR login payloads', () => {
  assert.equal(validateCoverUrl('https://p1.music.126.net/album.jpg').hostname, 'p1.music.126.net');
  for (const url of ['https://y.gtimg.cn/music/photo_new/a.jpg', 'https://qpic.y.qq.com/music_cover/a/300',
    'https://music-file.y.qq.com/songlist/a.jpg']) assert.equal(validateCoverUrl(url).href, url);
  for (const url of ['http://p1.music.126.net/a', 'https://music.126.net.attacker.com/a', 'https://127.0.0.1/a',
    'https://p1.music.126.net:444/a', 'https://a:b@p1.music.126.net/a', 'http://y.gtimg.cn/music/photo_new/a.jpg',
    'https://y.gtimg.cn/music/a.jpg', 'https://evil.y.gtimg.cn/music/photo_new/a.jpg',
    'https://qpic.y.qq.com/private/a', 'https://other.qq.com/music_cover/a', 'https://other.qpic.cn/music_cover/a',
    'https://qpic.y.qq.com.attacker.com/music_cover/a']) assert.throws(() => validateCoverUrl(url), {code: 'COVER_URL_INVALID'});
  assert.equal(validateQrUrl('fixture', 'https://music.163.com/login?codekey=fixture'), 'https://music.163.com/login?codekey=fixture');
  for (const url of ['https://music.163.com/login?codekey=other', 'https://music.163.com/login?codekey=fixture&url=x', 'https://attacker.com/login?codekey=fixture']) assert.throws(() => validateQrUrl('fixture', url), {code: 'QR_URL_INVALID'});
});

test('QQ cover IDs compile and each redirect still requires an allowed image path', async t => {
  const f = await fixture(t, false);
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  const png = await readFile(resolve('mod/images/music/ui.png'));
  const requested = [];
  globalThis.fetch = async url => {
    requested.push(url.href);
    if (url.hostname === 'music-file.y.qq.com') return new Response(null, {
      status: 302, headers: {location:'https://qpic.y.qq.com/music_cover/fixture/300'},
    });
    return new Response(png, {headers: {'content-type':'image/png'}});
  };
  const url = 'https://music-file.y.qq.com/songlist/fixture.png';
  for (const id of ['qq:000Fixture123', 'qq:playlist:123', 'qq:chart:4', 'qq:liked:56789']) {
    assert.match((await f.assets.cover(id, url)).image, /^[a-f0-9]{64}\.tex$/);
  }
  assert.equal(requested.length, 8);
  assert.equal(requested[1], 'https://qpic.y.qq.com/music_cover/fixture/300');
  for (const id of ['qq:', 'qq:a/b', 'qq:playlist:0', 'qq:chart:-1', 'qq:liked:xyz', 'qq:other:123']) {
    await assert.rejects(f.assets.cover(id, url), {code:'COVER_TRACK_INVALID'});
  }
  let denied = 0;
  globalThis.fetch = async () => {
    denied++;
    return new Response(null, {status:302, headers:{location:'https://music-file.y.qq.com/private/fixture.png'}});
  };
  await assert.rejects(f.assets.cover('qq:unseen', url), {code:'COVER_URL_INVALID'});
  assert.equal(denied, 1);
});

// Synthetic 150×150 indexed, one-bit QR code, matching the upstream PNG format.
const qqQr = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAJYAAACWAQMAAAAGz+OhAAAABlBMVEUAAAD///+l2Z/dAAABP0lEQVR42t1WMW7DMBDjWQGU7fID+' +
  'SVW+qwCDqIgfZiVlyg/kDcbsMXuTdcLinLUQlAkwRPiJ/YOr/jrb+AEQHino28AoNubeEneuMERgyc3E95VTpgPAU9OyJLM/lTTc4O' +
  'cbX0bA+AnWz/u3OCbmR8ikua192U+ryKHd2WcJFkRAESS5GbRowHACBZOnvVqwuGbNowgl8GzGnVVnp167j2wdppM/FgGbcpCejLb+' +
  'MFl0Fu90tFPZnn+NWuZTVkQlgGRSS1ysAiTbnCFDdBkoS3qNDd8hb0/PhCrqwZdzesldHCZZT3jgf1k1n1XWBCZbTqTRaTDGPYIHhn' +
  'S27ab5K26Qi6Rk9ptKBAOQJaPardvepG9Pwqn+V6tOOZ7cRnDGk8GWesAzwp8xr0HlfQmOkQkwWUWPJCNdLxA/sm9+w3ccdqhdRx2' +
  'EgAAAABJRU5ErkJggg==', 'base64');

test('QQ PNG compiles to black and white RGB KTEX and restores synchronized assets from cache', async t => {
  const f = await fixture(t);
  const key = 'private-qq-key-fixture';
  const [first, concurrent] = await Promise.all([f.assets.qrImage(key, qqQr), f.assets.qrImage(key, Buffer.from(qqQr))]);
  assert.deepEqual(concurrent, first);
  assert.match(first.atlas, /^images\/music_cache\/[a-f0-9]{64}\.xml$/);
  const source = join(f.modDir, 'images/music_cache'), runtime = join(f.runtimeModDir, 'images/music_cache');
  const tex = await readFile(join(source, first.image));
  assert.equal(tex.subarray(0, 4).toString('ascii'), 'KTEX');
  assert.equal((tex.readUInt32LE(4) >>> 4) & 31, 5);
  assert.equal(tex.readUInt16LE(8), 512);
  assert.equal(tex.readUInt16LE(10), 512);
  assert.equal(tex.length, 18 + 512*512*3);
  const pixels = tex.subarray(18);
  assert.deepEqual(new Set(pixels), new Set([0,255]));
  for (let row = 0; row < 31; row++) {
    assert.ok(pixels.subarray(row * 1536, (row+1) * 1536).every(value => value === 255));
    assert.ok(pixels.subarray((511-row) * 1536, (512-row) * 1536).every(value => value === 255));
  }
  await rm(runtime, {recursive:true, force:true});
  const cached = createGameAssets({...f, pythonPath:'missing-no-recompile'});
  assert.deepEqual(await cached.qrImage(key, qqQr), first);
  await assert.rejects(cached.qrImage(key, qqQr.subarray(0,8)), {code:'ASSET_IMAGE_CONVERSION_FAILED'});
  const name = first.image.slice(0, -4);
  for (const ext of ['png', 'tex', 'xml']) {
    assert.deepEqual(await readFile(join(source, `${name}.${ext}`)), await readFile(join(runtime, `${name}.${ext}`)));
  }
  const indices = await readdir(join(f.stateDir, 'game-assets'));
  assert.equal(indices.length, 1);
  assert.match(indices[0], /^[a-f0-9]{64}\.json$/);
  assert.deepEqual(JSON.parse(await readFile(join(f.stateDir, 'game-assets', indices[0]), 'utf8')), {name});
});

test('QQ QR input bounds reject malformed data and invalid PNGs without publishing', async t => {
  const f = await fixture(t, false);
  const oversized = Buffer.alloc(1024 * 1024 + 1);
  qqQr.copy(oversized);
  for (const [key, png] of [['', qqQr], ['x'.repeat(513), qqQr], ['key', new Uint8Array(qqQr)],
    ['key', 'https://example.com/qr.png'], ['key', Buffer.from('not a PNG')], ['key', oversized]]) {
    await assert.rejects(f.assets.qrImage(key, png), {code:'QR_IMAGE_INVALID'});
  }
  await assert.rejects(f.assets.qrImage('key', qqQr.subarray(0,8)), {code:'ASSET_IMAGE_CONVERSION_FAILED'});
  const largePng = await readFile(resolve('mod/images/music/ui.png'));
  await assert.rejects(f.assets.qrImage('key', largePng), {code:'ASSET_IMAGE_CONVERSION_FAILED'});
  assert.deepEqual(await readdir(join(f.modDir, 'images/music_cache')), []);
  assert.deepEqual(await readdir(join(f.stateDir, 'game-assets')), []);
});

test('real QR PNG -> KTEX -> XML, marker-owned synchronization, cache and immutable names', async t => {
  const f = await fixture(t);
  const first = await f.assets.qr('fixture-one', 'https://music.163.com/login?codekey=fixture-one');
  assert.match(first.atlas, /^images\/music_cache\/[a-f0-9]{64}\.xml$/);
  const name = first.image.slice(0, -4);
  const source = join(f.modDir, 'images/music_cache');
  const runtime = join(f.runtimeModDir, 'images/music_cache');
  for (const ext of ['png', 'tex', 'xml']) assert.deepEqual(await readFile(join(source, `${name}.${ext}`)), await readFile(join(runtime, `${name}.${ext}`)));
  const tex = await readFile(join(source, first.image));
  assert.equal(tex.subarray(0, 4).toString('ascii'), 'KTEX');
  assert.equal((tex.readUInt32LE(4) >>> 4) & 31, 5);
  assert.equal(tex.length, 18 + 512*512*3);
  assert.match(await readFile(join(source, `${name}.xml`), 'utf8'), new RegExp(`filename="${name}\\.tex"`));
  const mtime = (await stat(join(source, first.image))).mtimeMs;
  const reloaded = createGameAssets({...f, ktechPath: 'missing-should-not-run'});
  assert.deepEqual(await reloaded.qr('fixture-one', 'https://music.163.com/login?codekey=fixture-one'), first);
  assert.equal((await stat(join(source, first.image))).mtimeMs, mtime);
  const second = await f.assets.qr('fixture-two', 'https://music.163.com/login?codekey=fixture-two');
  assert.notEqual(second.atlas, first.atlas);
  const indices = (await readdir(join(f.stateDir, 'game-assets'))).filter(n => n.endsWith('.json'));
  for (const file of indices) assert.doesNotMatch(await readFile(join(f.stateDir, 'game-assets', file), 'utf8'), /fixture-|codekey/);
});

test('runtime without ownership marker is not written', async t => {
  const f = await fixture(t);
  await rm(join(f.runtimeModDir, 'music_bridge_owned.txt'));
  await assert.rejects(f.assets.qr('fixture', 'https://music.163.com/login?codekey=fixture'), {code: 'ASSET_RUNTIME_NOT_OWNED'});
  assert.deepEqual(await readdir(f.runtimeModDir), []);
});

test('runtime images junction cannot create cache outside the owned mod', async t => {
  const f = await fixture(t);
  const outside = join(f.root, 'outside');
  await mkdir(outside);
  await symlink(outside, join(f.runtimeModDir, 'images'), 'junction');
  await assert.rejects(f.assets.qr('junction-fixture', 'https://music.163.com/login?codekey=junction-fixture'), {code: 'ASSET_RUNTIME_NOT_OWNED'});
  assert.deepEqual(await readdir(outside), []);
});

test('Workshop cover compiles real raster, coalesces requests, and restores deleted cache offline', async t => {
  const f = await fixture(t, 'steamapps/workshop/content/322330/123456');
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  const png = await readFile(resolve('mod/images/music/ui.png'));
  let requests = 0;
  globalThis.fetch = async input => { assert.equal(new URL(input).protocol, 'https:'); requests++; return new Response(png, {headers: {'content-type': 'image/jpg'}}); };
  const url = 'https://p1.music.126.net/fixture.png';
  const [one, two] = await Promise.all([f.assets.cover('123', url), f.assets.cover('123', url)]);
  assert.deepEqual(one, two); assert.equal(requests, 1);
  const texture = await readFile(join(f.modDir,'images/music_cache',one.image));
  assert.equal((texture.readUInt32LE(4) >>> 4) & 31, 4);
  assert.equal(texture.length, 18 + 512*512*4);
  assert.deepEqual(await f.assets.cover('123', url.replace('https:', 'http:')), one);
  assert.equal(requests, 1);
  globalThis.fetch = async () => { throw new Error('offline'); };
  const localMtime = (await stat(join(f.modDir,'images/music_cache',one.image))).mtimeMs;
  await rm(join(f.runtimeModDir, 'images/music_cache'), {recursive:true, force:true});
  const cached = createGameAssets({...f, pythonPath:'missing-no-recompile'});
  assert.deepEqual(await cached.cover('123', url), one);
  assert.equal(requests, 1);
  assert.equal((await stat(join(f.modDir,'images/music_cache',one.image))).mtimeMs, localMtime);
  const name = one.image.slice(0, -4);
  for (const ext of ['png','tex','xml']) assert.deepEqual(
    await readFile(join(f.modDir,'images/music_cache',`${name}.${ext}`)),
    await readFile(join(f.runtimeModDir,'images/music_cache',`${name}.${ext}`)));
});

test('redirect destinations are checked and oversized/invalid images never publish XML', async t => {
  const f = await fixture(t, false);
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  let requests = 0;
  globalThis.fetch = async () => { requests++; return new Response(null, {status: 302, headers: {location: 'http://127.0.0.1/private'}}); };
  await assert.rejects(f.assets.cover('1', 'https://p1.music.126.net/a'), {code: 'COVER_URL_INVALID'});
  assert.equal(requests, 1);
  globalThis.fetch = async () => new Response('x', {headers: {'content-type': 'image/jpeg', 'content-length': String(9*1024*1024)}});
  await assert.rejects(f.assets.cover('2', 'https://p1.music.126.net/b'), {code: 'COVER_TOO_LARGE'});
  globalThis.fetch = async () => new Response('not-an-image', {headers: {'content-type': 'image/png'}});
  await assert.rejects(f.assets.cover('3', 'https://p1.music.126.net/c'), {code: 'ASSET_IMAGE_CONVERSION_FAILED'});
  assert.deepEqual(await readdir(join(f.modDir, 'images/music_cache')), []);
});


test('Workshop mods layout publishes QR assets and restores the complete cached pair', async t => {
  const f = await fixture(t, 'game/mods/workshop-654321');
  const result = await f.assets.qr('workshop', 'https://music.163.com/login?codekey=workshop');
  await rm(join(f.runtimeModDir, 'images'), {recursive:true, force:true});
  assert.deepEqual(await createGameAssets({...f, pythonPath:'missing-no-recompile'}).qr(
    'workshop', 'https://music.163.com/login?codekey=workshop'), result);
  const name = result.image.slice(0, -4);
  for (const ext of ['png','tex','xml']) assert.deepEqual(
    await readFile(join(f.modDir,'images/music_cache',`${name}.${ext}`)),
    await readFile(join(f.runtimeModDir,'images/music_cache',`${name}.${ext}`)));
});

test('a shared source/runtime cache still rejects linked cached files', async t => {
  const f = await fixture(t, 'game/mods/workshop-654321');
  const assets = createGameAssets({...f, modDir:f.runtimeModDir});
  const result = await assets.qr('shared', 'https://music.163.com/login?codekey=shared');
  const texture = join(f.runtimeModDir, 'images/music_cache', result.image);
  const outside = join(f.root, 'outside.tex');
  await writeFile(outside, await readFile(texture));
  await rm(texture);
  await symlink(outside, texture, 'file');
  await assert.rejects(assets.qr('shared', 'https://music.163.com/login?codekey=shared'),
    {code:'ASSET_RUNTIME_NOT_OWNED'});
});
