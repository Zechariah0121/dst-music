import {createHash, randomUUID} from 'node:crypto';
import {readFile, writeFile, mkdir, rename, mkdtemp, rm, stat} from 'node:fs/promises';
import {resolve, join, basename} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {runtimeAssetDestination, runtimeAssetFileExists} from './runtime-assets.mjs';

const run = promisify(execFile);
const script = fileURLToPath(new URL('./lyric-glyphs.py', import.meta.url));
const digest = data => createHash('sha256').update(data).digest('hex');
const failure = code => Object.assign(new Error(code), {code});
const version = 'glyph-v4-portable-premult-raw-packed-30logical-60core-2.5-7-gain1.2-2.8-trim2';
// Different character sets can share the same decoded-font cache. Serialize the
// compiler around that cache so decoders never expose a partially written PNG.
const sourceQueues = new Map();
async function compileWithSourceLock(key, compile) {
  const previous = sourceQueues.get(key) || Promise.resolve();
  const task = previous.catch(() => {}).then(compile);
  sourceQueues.set(key, task);
  try { return await task; }
  finally { if (sourceQueues.get(key) === task) sourceQueues.delete(key); }
}
async function exists(path) { try { return (await stat(path)).isFile(); } catch { return false; } }
async function atomicWrite(path, data) {
  const temp = `${path}.${randomUUID()}.tmp`;
  try { await writeFile(temp, data); await rename(temp, path); }
  finally { await rm(temp, {force: true}); }
}
function freeze(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}

/** Generate private game-font glyph masks. No lyrics or font data leave the machine. */
export function createLyricGlyphs({stateDir, modDir, runtimeModDir, fontsPath,
  ktechPath = '',
  pythonPath = process.env.DANGO_PYTHON || 'python'} = {}) {
  if (!stateDir || !modDir) throw failure('LYRIC_GLYPH_CONFIG_INVALID');
  stateDir = resolve(stateDir); modDir = resolve(modDir);
  // The launcher supplies the actual game font bundle for Workshop layouts.
  // Keep the established local install fallback for older local launchers.
  fontsPath = fontsPath || (runtimeModDir && basename(resolve(runtimeModDir)).toLowerCase() === 'local_netease_music'
    ? join(runtimeModDir, '../../data/databundles/fonts.zip') : undefined);
  if (fontsPath) fontsPath = resolve(fontsPath);
  const workDir = join(stateDir, 'lyric-glyphs');
  const cacheDir = join(modDir, 'images/music_cache');
  const pending = new Map();

  const destination = () => runtimeAssetDestination(runtimeModDir);

  async function publish(name, metadata) {
    const dest = await destination();
    if (dest) {
      // XML last is the visible commit marker for both fresh and cached assets.
      for (const ext of ['png', 'tex', 'xml']) {
        const file = `${name}.${ext}`;
        if (!await runtimeAssetFileExists(dest, file)) await atomicWrite(join(dest, file), await readFile(join(cacheDir, file)));
      }
    }
    return freeze({asset: {atlas: `images/music_cache/${name}.xml`, image: `${name}.tex`},
      fonts: metadata.fonts, missing: metadata.missing});
  }

  return {
    async build(characters) {
      if (typeof characters !== 'string' || characters.length > 500_000) throw failure('LYRIC_GLYPH_CHARACTERS_INVALID');
      // Newline/control codes are layout, never atlas glyphs. No text is logged.
      const chars = [...new Set([...characters].filter(c => !/[\u0000-\u001f\u007f]/u.test(c)))].sort((a, b) => a.codePointAt(0) - b.codePointAt(0));
      if (chars.length > 2048) throw failure('LYRIC_GLYPH_CHARACTER_LIMIT');
      let fontInfo;
      try { if (!fontsPath) throw failure('LYRIC_GLYPH_FONT_SOURCE_MISSING'); fontInfo = await stat(fontsPath); } catch { throw failure('LYRIC_GLYPH_FONT_SOURCE_MISSING'); }
      const key = digest(JSON.stringify([version, fontsPath, fontInfo.size, fontInfo.mtimeMs, chars]));
      if (pending.has(key)) return pending.get(key);
      if (pending.size >= 2) throw failure('LYRIC_GLYPH_BUSY');
      const task = (async () => {
        await destination();
        await Promise.all([mkdir(workDir, {recursive: true}), mkdir(cacheDir, {recursive: true})]);
        const index = join(workDir, `${key}.json`);
        try {
          const {name, metadata} = JSON.parse(await readFile(index, 'utf8'));
          if (/^[a-f0-9]{64}$/.test(name) && metadata?.fonts &&
              (await Promise.all(['png','tex','xml'].map(ext => exists(join(cacheDir, `${name}.${ext}`))))).every(Boolean)) return await publish(name, metadata);
        } catch (e) { if (e.code === 'ASSET_RUNTIME_NOT_OWNED') throw e; }
        const temp = await mkdtemp(join(workDir, 'build-'));
        try {
          const request = join(temp, 'request.json'), png = join(temp, 'atlas.png'), result = join(temp, 'result.json');
          await writeFile(request, JSON.stringify(chars));
          try {
            await compileWithSourceLock(join(stateDir, 'font-source'), () =>
              run(pythonPath, [script, fontsPath, ktechPath, join(stateDir, 'font-source'), request, png, result],
                {timeout: 120_000, windowsHide: true, maxBuffer: 64 * 1024}));
          } catch (error) {
            throw failure(String(error.stderr).includes('LYRIC_GLYPH_ATLAS_FULL') ? 'LYRIC_GLYPH_ATLAS_FULL' : 'LYRIC_GLYPH_COMPILE_FAILED');
          }
          const metadata = JSON.parse(await readFile(result, 'utf8'));
          const pngData = await readFile(png);
          // Metadata is included: identical pixels with different advances cannot alias.
          const name = digest(Buffer.concat([Buffer.from(version), Buffer.from(JSON.stringify(metadata)), pngData]));
          const tex = join(temp, `${name}.tex`);
          try {
            // RGBA preserves fine CJK strokes and soft alpha; no block compression.
            await run(pythonPath, [script, '--encode-ktex', png, tex, ktechPath],
              {timeout: 60_000, windowsHide: true, maxBuffer: 64 * 1024});
          } catch { throw failure('LYRIC_GLYPH_TEX_FAILED'); }
          const texData = await readFile(tex);
          if (texData.subarray(0,4).toString('ascii') !== 'KTEX') throw failure('LYRIC_GLYPH_TEX_INVALID');
          const size = metadata.atlasSize;
          const elements = Object.entries(metadata.elements).map(([element, r]) =>
            `<Element name="${element}" u1="${r.x/size}" u2="${(r.x+r.width)/size}" v1="${1-(r.y+r.height)/size}" v2="${1-r.y/size}"/>`).join('');
          const xml = `<Atlas><Texture filename="${name}.tex"/><Elements><Element name="${name}.tex" u1="0" u2="1" v1="0" v2="1"/>${elements}</Elements></Atlas>\n`;
          for (const [ext, data] of [['png', pngData], ['tex', texData], ['xml', xml]]) {
            if (!await exists(join(cacheDir, `${name}.${ext}`))) await atomicWrite(join(cacheDir, `${name}.${ext}`), data);
          }
          await atomicWrite(index, JSON.stringify({name, metadata}));
          return await publish(name, metadata);
        } finally { await rm(temp, {recursive: true, force: true}); }
      })();
      pending.set(key, task);
      try { return await task; } finally { pending.delete(key); }
    },
  };
}
