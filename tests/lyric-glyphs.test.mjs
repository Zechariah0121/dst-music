import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm, stat, symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {createLyricGlyphs} from '../helper/lyric-glyphs.mjs';
const run = promisify(execFile);
const pythonPath = process.env.DANGO_PYTHON || 'python';

async function fixture(t, workshop = false) {
  const root = await mkdtemp(join(tmpdir(), 'dango-glyphs-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const stateDir = join(root, 'state'), modDir = join(root, 'mod');
  const runtimeModDir = join(root, workshop ? 'steamapps/workshop/content/322330/123456' : 'installed/local_netease_music');
  await mkdir(runtimeModDir, {recursive: true});
  if (workshop) await writeFile(join(runtimeModDir, 'music_workshop_identity.json'),
    JSON.stringify({schema:1,id:'zcc-dst-music',channel:'workshop-beta'}));
  else await writeFile(join(runtimeModDir, 'music_bridge_owned.txt'), 'dst-local-music-prototype-v1\n');
  const fontsPath = "D:/steam/steamapps/common/Don't Starve Together/data/databundles/fonts.zip";
  return {root, stateDir, modDir, runtimeModDir, fontsPath, pythonPath, ktechPath:'missing-should-not-run'};
}

test('input caps codepoints and rejects invalid requests before compilation', async () => {
  const assets = createLyricGlyphs({stateDir: '.state', modDir: 'mod'});
  await assert.rejects(assets.build(null), {code:'LYRIC_GLYPH_CHARACTERS_INVALID'});
  await assert.rejects(assets.build(Array.from({length:2049},(_,i)=>String.fromCodePoint(0x1000+i)).join('')), {code:'LYRIC_GLYPH_CHARACTER_LIMIT'});
});

test('real game fonts: immutable KTEX atlas, masks, cache, coalescing and owned publication', async t => {
  const f = await fixture(t, true), assets = createLyricGlyphs(f);
  const text = 'Remember the light O8 雨落在窗边\u{10ffff}';
  // An intact v1 cache has incompatible layer geometry and must never be reused.
  const chars = [...new Set([...text])].sort((a,b)=>a.codePointAt(0)-b.codePointAt(0));
  const fontInfo = await stat(f.fontsPath);
  const oldKey = createHash('sha256').update(JSON.stringify(['glyph-v1-30px-channel-fill-1.2-2.8',
    resolve(f.fontsPath),fontInfo.size,fontInfo.mtimeMs,chars])).digest('hex');
  const oldName = '0'.repeat(64);
  await mkdir(join(f.stateDir,'lyric-glyphs'),{recursive:true});
  await mkdir(join(f.modDir,'images/music_cache'),{recursive:true});
  await writeFile(join(f.stateDir,'lyric-glyphs',`${oldKey}.json`), JSON.stringify({name:oldName,metadata:{fonts:{}}}));
  for (const ext of ['png','tex','xml']) await writeFile(join(f.modDir,'images/music_cache',`${oldName}.${ext}`),'obsolete');
  const [one, two] = await Promise.all([assets.build(text), assets.build(text)]);
  assert.deepEqual(one, two);
  assert.ok(Object.isFrozen(one.fonts.mono.glyphs.O));
  assert.deepEqual(one.missing, ['\u{10ffff}']);
  assert.match(one.asset.atlas, /^images\/music_cache\/[a-f0-9]{64}\.xml$/);
  assert.notEqual(one.fonts.mono.glyphs.O.advance, one.fonts.smooth.glyphs.O.advance);
  assert.equal(one.fonts.mono.glyphs['雨'].core, one.fonts.smooth.glyphs['雨'].core);
  const name = one.asset.image.slice(0,-4), local = join(f.modDir, 'images/music_cache');
  assert.notEqual(name,oldName);
  for (const ext of ['png','tex','xml']) {
    assert.deepEqual(await readFile(join(local,`${name}.${ext}`)), await readFile(join(f.runtimeModDir,'images/music_cache',`${name}.${ext}`)));
  }
  assert.equal((await readFile(join(local,`${name}.tex`))).subarray(0,4).toString(), 'KTEX');
  assert.match(await readFile(join(local,`${name}.xml`),'utf8'), new RegExp(`name="${name}\\.tex"`));
  const indexes = await readdir(join(f.stateDir,'lyric-glyphs'));
  assert.equal(indexes.length,2);
  const currentIndex = indexes.find(index=>index!==`${oldKey}.json`);
  await run(pythonPath,[resolve('tests/test_lyric_glyphs.py')], {env:{...process.env,
    LYRIC_GLYPH_TEST_INDEX:join(f.stateDir,'lyric-glyphs',currentIndex), LYRIC_GLYPH_TEST_PNG:join(local,`${name}.png`),
    LYRIC_GLYPH_TEST_SOURCE:join(f.stateDir,'font-source'), LYRIC_GLYPH_TEST_TEX:join(local,`${name}.tex`)}});
  const before = (await stat(join(local,`${name}.tex`))).mtimeMs;
  assert.deepEqual(await createLyricGlyphs({...f, ktechPath:'missing', pythonPath:'missing'}).build(text), one);
  assert.equal((await stat(join(local,`${name}.tex`))).mtimeMs,before);
  // A Steam update can remove private Workshop files. Re-publish without Python.
  await rm(join(f.runtimeModDir,'images/music_cache'),{recursive:true,force:true});
  assert.deepEqual(await createLyricGlyphs({...f,pythonPath:'missing-no-recompile'}).build(text),one);
  for (const ext of ['png','tex','xml']) assert.deepEqual(
    await readFile(join(local,`${name}.${ext}`)), await readFile(join(f.runtimeModDir,'images/music_cache',`${name}.${ext}`)));
  assert.equal((await stat(join(local,`${name}.tex`))).mtimeMs,before);
  // Reuse the cached build to test publication guards without recompilation.
  await rm(join(f.runtimeModDir,'images'),{recursive:true,force:true});
  const outside=join(f.root,'outside'); await mkdir(outside);
  await symlink(outside,join(f.runtimeModDir,'images'),'junction');
  await assert.rejects(assets.build(text),{code:'ASSET_RUNTIME_NOT_OWNED'});
  assert.deepEqual(await readdir(outside),[]);
  await rm(join(f.runtimeModDir,'images'),{force:true});
  await rm(join(f.runtimeModDir,'music_workshop_identity.json'));
  await assert.rejects(assets.build(text),{code:'ASSET_RUNTIME_NOT_OWNED'});
});

test('two processes initialize one cold source cache atomically for different character sets', async t => {
  const f = await fixture(t);
  const program = `import {createLyricGlyphs} from ${JSON.stringify(new URL('../helper/lyric-glyphs.mjs', import.meta.url).href)};
    const config=JSON.parse(process.argv[1]);
    const result=await createLyricGlyphs(config).build(process.argv[2]);
    process.stdout.write(JSON.stringify({asset:result.asset,missing:result.missing}));`;
  const outcomes = await Promise.allSettled(['Remember the light 雨', 'Another window 窗'].map(characters =>
    run(process.execPath, ['--input-type=module','-e',program,JSON.stringify(f),characters],
      {timeout:120_000, windowsHide:true, maxBuffer:64*1024})));
  for (const outcome of outcomes) if (outcome.status === 'rejected') throw outcome.reason;
  const outputs = outcomes.map(outcome=>outcome.value);
  const descriptors = outputs.map(output=>JSON.parse(output.stdout));
  assert.notEqual(descriptors[0].asset.image,descriptors[1].asset.image);
  for (const descriptor of descriptors) {
    assert.deepEqual(descriptor.missing,[]);
    const tex = await readFile(join(f.modDir,'images/music_cache',descriptor.asset.image));
    assert.equal(tex.subarray(0,4).toString(),'KTEX');
  }
  const sources = join(f.stateDir,'font-source');
  for (const folder of await readdir(sources)) {
    assert.deepEqual((await readdir(join(sources,folder))).filter(name=>/\.tmp$|^font\.[a-f0-9]{32}\.png$/.test(name)),[]);
    JSON.parse(await readFile(join(sources,folder,'provenance.json'),'utf8'));
  }
  await run(pythonPath,['-c',
    'from pathlib import Path; from PIL import Image; import sys,xml.etree.ElementTree as E; ps=[p for p in Path(sys.argv[1]).glob("*/font.*.png") if "raw-rgba-v2" in p.name or "straight-v3-pillow" in p.name]; assert len(ps)==4; [(E.parse(p.parent/"font.fnt"), Image.open(p).load()) for p in ps]',sources]);
});


test('Workshop font bundle must be supplied explicitly by the launcher', async t => {
  const f = await fixture(t, true);
  await assert.rejects(createLyricGlyphs({...f, fontsPath:undefined}).build('雨'),
    {code:'LYRIC_GLYPH_FONT_SOURCE_MISSING'});
});
