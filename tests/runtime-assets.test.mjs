import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readdir, rm, symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runtimeAssetDestination, runtimeAssetFileExists} from '../helper/runtime-assets.mjs';

const identity = {schema:1, id:'zcc-dst-music', channel:'workshop-beta'};
const releaseIdentity = {...identity, version:'0.5.1-beta.1'};
const layouts = ['game/mods/workshop-123456', 'steamapps/workshop/content/322330/123456'];
async function fixture(t, layout = layouts[0], marker = identity) {
  const root = await mkdtemp(join(tmpdir(), 'dango-runtime-assets-'));
  t.after(() => rm(root, {recursive:true, force:true}));
  const target = join(root, layout);
  await mkdir(target, {recursive:true});
  if (marker !== null) await writeFile(join(target, 'music_workshop_identity.json'), JSON.stringify(marker));
  return {root, target};
}

test('only the two identified beta Workshop layouts can receive a cache', async t => {
  assert.equal(await runtimeAssetDestination(undefined), null);
  for (const layout of layouts) {
    for (const marker of [identity, releaseIdentity]) {
      const {target} = await fixture(t, layout, marker);
      assert.equal(await runtimeAssetDestination(target), join(target, 'images/music_cache'));
    }
  }
  for (const layout of ['arbitrary/123456', 'game/mods/workshop-wrong', 'game/workshop-123456',
    'steamapps/workshop/content/322331/123456', 'workshop/content/322330/123456']) {
    const {target} = await fixture(t, layout);
    await assert.rejects(runtimeAssetDestination(target), {code:'ASSET_RUNTIME_NOT_OWNED'});
    assert.deepEqual(await readdir(target), ['music_workshop_identity.json']);
  }
});

test('missing, malformed and mismatched beta identities fail before creating descendants', async t => {
  for (const marker of [null, {}, {...releaseIdentity, schema:'1'}, {...releaseIdentity, id:'other'},
    {...releaseIdentity, channel:'stable'}, {...releaseIdentity, extra:true},
    {...releaseIdentity, version:1}, {...releaseIdentity, version:null}]) {
    const {target} = await fixture(t, layouts[0], marker);
    await assert.rejects(runtimeAssetDestination(target), {code:'ASSET_RUNTIME_NOT_OWNED'});
    assert.deepEqual(await readdir(target), marker === null ? [] : ['music_workshop_identity.json']);
  }
  const {target} = await fixture(t);
  await writeFile(join(target, 'music_workshop_identity.json'), '{');
  await assert.rejects(runtimeAssetDestination(target), {code:'ASSET_RUNTIME_NOT_OWNED'});
});

test('ancestor, mod root and cache junctions cannot redirect Workshop writes', async t => {
  for (const layout of layouts) {
    const {root, target} = await fixture(t, layout);
    const alias = join(root, 'alias');
    await symlink(join(root, layout.split('/')[0]), alias, 'junction');
    await assert.rejects(runtimeAssetDestination(join(alias, ...layout.split('/').slice(1))), {code:'ASSET_RUNTIME_NOT_OWNED'});
    const linkedRoot = join(root, 'game/mods/workshop-789');
    await mkdir(join(root, 'game/mods'), {recursive:true});
    await symlink(target, linkedRoot, 'junction');
    await assert.rejects(runtimeAssetDestination(linkedRoot), {code:'ASSET_RUNTIME_NOT_OWNED'});
    const outside = join(root, 'outside');
    await mkdir(outside);
    await symlink(outside, join(target, 'images'), 'junction');
    await assert.rejects(runtimeAssetDestination(target), {code:'ASSET_RUNTIME_NOT_OWNED'});
    assert.deepEqual(await readdir(outside), []);
    await rm(join(target, 'images'), {force:true});
    await mkdir(join(target, 'images'));
    await symlink(outside, join(target, 'images/music_cache'), 'junction');
    await assert.rejects(runtimeAssetDestination(target), {code:'ASSET_RUNTIME_NOT_OWNED'});
    assert.deepEqual(await readdir(outside), []);
  }
});

test('cache files must be regular files and identity cannot be a link', async t => {
  const {root, target} = await fixture(t);
  const destination = await runtimeAssetDestination(target), name = `${'a'.repeat(64)}.xml`;
  assert.equal(await runtimeAssetFileExists(destination, name), false);
  await mkdir(join(destination, name));
  await assert.rejects(runtimeAssetFileExists(destination, name), {code:'ASSET_RUNTIME_NOT_OWNED'});
  await rm(join(destination, name), {recursive:true});
  await writeFile(join(root, 'outside.xml'), 'private');
  await symlink(join(root, 'outside.xml'), join(destination, name), 'file');
  await assert.rejects(runtimeAssetFileExists(destination, name), {code:'ASSET_RUNTIME_NOT_OWNED'});
  await rm(join(target, 'music_workshop_identity.json'));
  await writeFile(join(root, 'identity.json'), JSON.stringify(identity));
  await symlink(join(root, 'identity.json'), join(target, 'music_workshop_identity.json'), 'file');
  await assert.rejects(runtimeAssetDestination(target), {code:'ASSET_RUNTIME_NOT_OWNED'});
});
