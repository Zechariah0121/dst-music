import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, writeFile, readdir, rm, stat, symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {createGameConnection} from '../helper/game-connection.mjs';

const identity = {schema: 1, id: 'zcc-dst-music', channel: 'workshop-beta', version: 'test'};
const token = 'test_connection_token_012345678901';
const content = `return {host="127.0.0.1",port=17863,token="${token}"}\n`;
const layouts = ['game/mods/workshop-123456', 'steamapps/workshop/content/322330/123456', 'game/mods/local_netease_music'];

async function fixture(t, layout = layouts[0], options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'dango-game-connection-'));
  const target = join(root, layout), path = join(target, 'scripts/dangomusic_connection.lua');
  await mkdir(target, {recursive: true});
  async function identify() {
    await writeFile(join(target, layout.endsWith('local_netease_music') ? 'music_bridge_owned.txt' : 'music_workshop_identity.json'),
      layout.endsWith('local_netease_music') ? 'dst-local-music-prototype-v1\n' : JSON.stringify(identity));
  }
  await identify();
  let time = 10000;
  const config = {modDir: join(root, 'package/mod'), runtimeModDir: target, port: 17863, token, intervalMs: 250,
    now: () => time, ...options};
  const connection = createGameConnection(config);
  t.after(async () => { await connection.close(); await rm(root, {recursive: true, force: true}); });
  return {root, target, path, connection, identify, advance: () => { time += 250; }, config};
}

test('已识别的三种安装布局会生成连接，内容相同不重写且检查有节流', async t => {
  for (const layout of layouts) {
    const f = await fixture(t, layout);
    assert.equal(await f.connection.start(), true);
    assert.equal(await readFile(f.path, 'utf8'), content);
    const before = await stat(f.path);
    f.advance();
    assert.equal(await f.connection.check(), false);
    assert.equal((await stat(f.path)).mtimeMs, before.mtimeMs);
    await rm(f.path);
    assert.equal(await f.connection.check(), false);
    await assert.rejects(readFile(f.path), {code: 'ENOENT'});
    f.advance();
    assert.equal(await f.connection.check(), true);
    assert.equal(await readFile(f.path, 'utf8'), content);
    assert.deepEqual(await readdir(join(f.target, 'scripts')), ['dangomusic_connection.lua']);
    await assert.rejects(readFile(join(f.root, 'package/mod/scripts/dangomusic_connection.lua')), {code: 'ENOENT'});
  }
});

test('更新删除或替换 scripts 后恢复当前令牌和端口', async t => {
  const f = await fixture(t);
  await f.connection.start();
  await rm(join(f.target, 'scripts'), {recursive: true});
  f.advance();
  assert.equal(await f.connection.check(), true);
  await writeFile(f.path, 'return {port=1,token="obsolete"}\n');
  f.advance();
  assert.equal(await f.connection.check(), true);
  assert.equal(await readFile(f.path, 'utf8'), content);
});

test('只有包内明确指定的 modDir 可使用任意目录名，仍须验证本项目身份', async t => {
  const f = await fixture(t, 'package/mod');
  assert.equal(await f.connection.start(), false);
  const connection = createGameConnection({...f.config, modDir: f.target, runtimeModDir: undefined});
  t.after(() => connection.close());
  assert.equal(await connection.start(), true);
  assert.equal(await readFile(f.path, 'utf8'), content);
});

test('缺失、错误或额外字段的身份不会创建 scripts', async t => {
  for (const marker of [null, '{', '{}', {...identity, schema: '1'}, {...identity, id: 'other'},
    {...identity, channel: 'stable'}, {...identity, extra: true}, {...identity, version: null}]) {
    const f = await fixture(t);
    const path = join(f.target, 'music_workshop_identity.json');
    if (marker === null) await rm(path);
    else await writeFile(path, typeof marker === 'string' ? marker : JSON.stringify(marker));
    assert.equal(await f.connection.start(), false);
    assert.deepEqual(await readdir(f.target), marker === null ? [] : ['music_workshop_identity.json']);
  }
  const f = await fixture(t, layouts[2]);
  await writeFile(join(f.target, 'music_bridge_owned.txt'), 'another-mod');
  assert.equal(await f.connection.start(), false);
  await assert.rejects(readFile(f.path), {code: 'ENOENT'});
});

test('每次恢复前重新验身份，不复活卸载目录，支持有效更新后再恢复', async t => {
  const f = await fixture(t);
  await f.connection.start();
  await rm(f.target, {recursive: true});
  f.advance();
  assert.equal(await f.connection.check(), false);
  await assert.rejects(stat(f.target), {code: 'ENOENT'});
  await mkdir(f.target);
  f.advance();
  assert.equal(await f.connection.check(), false);
  assert.deepEqual(await readdir(f.target), []);
  await f.identify();
  f.advance();
  assert.equal(await f.connection.check(), true);
  assert.equal(await readFile(f.path, 'utf8'), content);
});

test('祖先、根目录和 scripts 的重解析链接都不能重定向写入', async t => {
  for (const part of ['ancestor', 'root', 'scripts']) {
    const f = await fixture(t);
    const outside = join(f.root, 'outside');
    await mkdir(outside);
    if (part === 'scripts') {
      await symlink(outside, join(f.target, 'scripts'), 'junction');
      assert.equal(await f.connection.start(), false);
    } else {
      const alias = join(f.root, 'alias');
      await symlink(part === 'root' ? f.target : join(f.root, 'game'), alias, 'junction');
      const connection = createGameConnection({...f.config, modDir: part === 'root' ? alias : join(alias, 'mods/workshop-123456'), runtimeModDir: undefined});
      t.after(() => connection.close());
      assert.equal(await connection.start(), false);
    }
    assert.deepEqual(await readdir(outside), []);
    await assert.rejects(readFile(f.path), {code: 'ENOENT'});
  }
});

test('身份、连接文件的符号链接和连接目录不能被覆盖', async t => {
  for (const part of ['marker', 'connection', 'directory']) {
    const f = await fixture(t);
    const outside = join(f.root, 'outside.txt');
    await writeFile(outside, part === 'marker' ? JSON.stringify(identity) : 'private');
    if (part === 'marker') {
      const marker = join(f.target, 'music_workshop_identity.json');
      await rm(marker);
      await symlink(outside, marker, 'file');
    } else {
      await mkdir(join(f.target, 'scripts'));
      if (part === 'connection') await symlink(outside, f.path, 'file');
      else await mkdir(f.path);
    }
    assert.equal(await f.connection.start(), false);
    assert.equal(await readFile(outside, 'utf8'), part === 'marker' ? JSON.stringify(identity) : 'private');
  }
});

test('并发检查合并为一次写入，关闭会等待在途检查并阻止后续恢复', async t => {
  const f = await fixture(t);
  const first = f.connection.check(), second = f.connection.check();
  assert.equal(first, second);
  assert.equal(await first, true);
  await rm(f.path);
  f.advance();
  const repair = f.connection.check();
  await f.connection.close();
  assert.equal(await repair, false);
  assert.equal(await f.connection.check(), false);
  assert.equal(await f.connection.start(), false);
  await assert.rejects(readFile(f.path), {code: 'ENOENT'});
});

test('定时恢复能跨过一次失败且关闭后不再写入', async t => {
  const f = await fixture(t, layouts[0], {now: Date.now});
  await f.connection.start();
  await rm(join(f.target, 'music_workshop_identity.json'));
  await rm(f.path);
  await delay(300);
  await assert.rejects(readFile(f.path), {code: 'ENOENT'});
  await f.identify();
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline) {
    try { if (await readFile(f.path, 'utf8') === content) break; } catch {}
    await delay(25);
  }
  assert.equal(await readFile(f.path, 'utf8'), content);
  await f.connection.close();
  await rm(f.path);
  await delay(300);
  await assert.rejects(readFile(f.path), {code: 'ENOENT'});
});

test('无效端口、令牌和轮询周期在任何写入前拒绝', async t => {
  const f = await fixture(t);
  for (const options of [{port: 0}, {port: 65536}, {token: 'secret"injection'}, {intervalMs: 0}]) {
    assert.throws(() => createGameConnection({...f.config, ...options}), /GAME_CONNECTION_OPTIONS_INVALID/);
  }
  assert.deepEqual(await readdir(f.target), ['music_workshop_identity.json']);
});
