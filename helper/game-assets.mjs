import {createHash, randomUUID} from 'node:crypto';
import {readFile, writeFile, mkdir, rename, mkdtemp, rm, stat} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {runtimeAssetDestination, runtimeAssetFileExists} from './runtime-assets.mjs';
import {createRequire} from 'node:module';

const run = promisify(execFile);
const qrcode = createRequire(import.meta.url)('./public/vendor/qrcode.js');
const imageScript = fileURLToPath(new URL('./asset-image.py', import.meta.url));
const maxBytes = 8 * 1024 * 1024;
const maxQrBytes = 1024 * 1024;
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const qqCoverPaths = new Map([
  ['y.gtimg.cn', '/music/photo_new/'],
  ['qpic.y.qq.com', '/music_cover/'],
  ['music-file.y.qq.com', '/songlist/'],
]);
const neteaseThumbnailHosts = new Set(['p1.music.126.net','p2.music.126.net','p3.music.126.net','p4.music.126.net']);
const hash = value => createHash('sha256').update(value).digest('hex');
const failure = code => Object.assign(new Error(code), {code});

export function validateCoverUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw failure('COVER_URL_INVALID'); }
  const qqPath = qqCoverPaths.get(url.hostname);
  const allowed = /^(?:[a-z0-9-]+\.)*music\.126\.net$/i.test(url.hostname) ||
    (qqPath && url.pathname.startsWith(qqPath));
  if (url.protocol !== 'https:' || url.username || url.password || url.port || !allowed) throw failure('COVER_URL_INVALID');
  return url;
}

// Providers can return legacy HTTP cover metadata. Validate the upgraded URL
// before connecting. Redirects must already use HTTPS.
function canonicalCoverUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw failure('COVER_URL_INVALID'); }
  if (url.protocol === 'http:' && !url.port) url.protocol = 'https:';
  return validateCoverUrl(url.href);
}

export function validateQrUrl(key, value) {
  let url;
  try { url = new URL(value); } catch { throw failure('QR_URL_INVALID'); }
  if (typeof key !== 'string' || !key || key.length > 512 || url.origin !== 'https://music.163.com' ||
      url.username || url.password || url.pathname !== '/login' || url.searchParams.get('codekey') !== key ||
      [...url.searchParams.keys()].some(k => k !== 'codekey') || url.hash) throw failure('QR_URL_INVALID');
  return url.href;
}

async function download(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);
  try {
    let current = validateCoverUrl(url);
    for (let redirects = 0; redirects <= 3; redirects++) {
      const response = await fetch(current, {redirect: 'manual', signal: controller.signal, headers: {Accept: 'image/jpeg,image/png,image/webp'}});
      if ([301,302,303,307,308].includes(response.status)) {
        await response.body?.cancel();
        current = validateCoverUrl(new URL(response.headers.get('location') || '', current).href);
        continue;
      }
      if (!response.ok || !/^image\/(jpeg|jpg|png|webp)(?:;|$)/i.test(response.headers.get('content-type') || '')) {
        await response.body?.cancel(); throw failure('COVER_DOWNLOAD_FAILED');
      }
      if (Number(response.headers.get('content-length')) > maxBytes) { await response.body?.cancel(); throw failure('COVER_TOO_LARGE'); }
      const chunks = []; let size = 0;
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > maxBytes) { controller.abort(); throw failure('COVER_TOO_LARGE'); }
        chunks.push(chunk);
      }
      return Buffer.concat(chunks);
    }
    throw failure('COVER_REDIRECT_LIMIT');
  } catch (error) {
    // Never return upstream URLs, query strings or native command output to UI.
    throw error.code?.startsWith('COVER_') ? error : failure('COVER_DOWNLOAD_FAILED');
  } finally { clearTimeout(timeout); }
}

async function exists(path) { try { return (await stat(path)).isFile(); } catch { return false; } }
async function atomicWrite(path, contents) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try { await writeFile(temporary, contents); await rename(temporary, path); }
  finally { await rm(temporary, {force: true}); }
}

/** Compile private local PNG/KTEX assets; call after authenticating bridge requests.
 * Only marker-owned installed mods are eligible for cache synchronization.
 */
export function createGameAssets({stateDir, modDir, runtimeModDir,
  ktechPath = '',
  pythonPath = process.env.DANGO_PYTHON || 'python'} = {}) {
  if (!stateDir || !modDir) throw failure('ASSET_CONFIG_INVALID');
  stateDir = resolve(stateDir); modDir = resolve(modDir);
  const cacheDir = join(modDir, 'images', 'music_cache');
  const workingDir = join(stateDir, 'game-assets');
  const pending = new Map();

  const destination = () => runtimeAssetDestination(runtimeModDir);

  async function publish(name) {
    const dest = await destination();
    if (dest) {
      for (const extension of ['png','tex','xml']) {
        const file = `${name}.${extension}`;
        if (!await runtimeAssetFileExists(dest, file)) await atomicWrite(join(dest, file), await readFile(join(cacheDir, file)));
      }
    }
    return {atlas: `images/music_cache/${name}.xml`, image: `${name}.tex`};
  }

  async function build(kind, identity, input) {
    const lookup = hash(`v2-raw:${kind}:${identity}`);
    if (pending.has(lookup)) return pending.get(lookup);
    if (pending.size >= 4) throw failure('ASSET_BUSY');
    const task = (async () => {
      await destination();
      await Promise.all([mkdir(cacheDir, {recursive: true}), mkdir(workingDir, {recursive: true})]);
      const indexFile = join(workingDir, `${lookup}.json`);
      try {
        const {name} = JSON.parse(await readFile(indexFile, 'utf8'));
        if (/^[a-f0-9]{64}$/.test(name) && await exists(join(cacheDir, `${name}.tex`)) && await exists(join(cacheDir, `${name}.xml`)) && await exists(join(cacheDir, `${name}.png`))) return await publish(name);
      } catch (e) { if (e.code === 'ASSET_RUNTIME_NOT_OWNED') throw e; }
      const temp = await mkdtemp(join(workingDir, 'build-'));
      try {
        const source = join(temp, 'input');
        if (kind === 'cover') await writeFile(source, await download(input));
        else if (kind === 'qr') {
          const qr = qrcode(0, 'M'); qr.addData(input, 'Byte'); qr.make();
          const n = qr.getModuleCount();
          await writeFile(source, JSON.stringify(Array.from({length: n}, (_, y) => Array.from({length: n}, (_, x) => qr.isDark(y, x)))));
        }
        const png = join(temp, 'image.png');
        try {
          const args = kind === 'qr-image' ? [imageScript, kind, png] : [imageScript, kind, source, png];
          const conversion = run(pythonPath, args, {timeout: 20_000, windowsHide: true, maxBuffer: 64 * 1024});
          if (kind === 'qr-image') {
            const stdin = conversion.child.stdin;
            // If the compiler exits early, report its command failure below.
            stdin?.on('error', () => {});
            stdin?.end(input);
          }
          await conversion;
        }
        catch { throw failure('ASSET_IMAGE_CONVERSION_FAILED'); }
        const pngData = await readFile(png), name = hash(Buffer.concat([Buffer.from(`${kind}:v2-raw:`), pngData]));
        const tex = join(temp, `${name}.tex`);
        try { await run(pythonPath, [imageScript, 'encode-ktex', png, tex, kind === 'cover' ? 'RGBA' : 'RGB'], {timeout: 20_000, windowsHide: true, maxBuffer: 64 * 1024}); }
        catch { throw failure('ASSET_TEX_CONVERSION_FAILED'); }
        const texData = await readFile(tex);
        if (texData.subarray(0, 4).toString('ascii') !== 'KTEX') throw failure('ASSET_TEX_INVALID');
        const xml = `<Atlas><Texture filename="${name}.tex"/><Elements><Element name="${name}.tex" u1="0" u2="1" v1="0" v2="1"/></Elements></Atlas>\n`;
        // XML is the commit marker: Image:SetTexture only sees a complete pair.
        await atomicWrite(join(cacheDir, `${name}.png`), pngData);
        await atomicWrite(join(cacheDir, `${name}.tex`), texData);
        await atomicWrite(join(cacheDir, `${name}.xml`), xml);
        const descriptor = await publish(name);
        await atomicWrite(indexFile, JSON.stringify({name}));
        return descriptor;
      } finally { await rm(temp, {recursive: true, force: true}); }
    })();
    pending.set(lookup, task);
    try { return await task; } finally { pending.delete(lookup); }
  }
  return {
    cover(trackId, url) {
      if (!/^(?:\d{1,24}|qq:[A-Za-z0-9]{1,64}|qq:(?:playlist|chart|liked):[1-9]\d{0,18})$/.test(String(trackId))) {
        return Promise.reject(failure('COVER_TRACK_INVALID'));
      }
      const value = canonicalCoverUrl(url).href;
      const imageUrl = new URL(value);
      // These NetEase image CDNs provide server-side resizing. Keep the
      // original URL as the cache identity so already-compiled assets remain
      // reusable, while oversized source JPEGs stay within our decoder cap.
      if (neteaseThumbnailHosts.has(imageUrl.hostname)) imageUrl.searchParams.set('param', '512y512');
      return build('cover', `${trackId}:${value}`, imageUrl.href);
    },
    qr(key, url) { const value = validateQrUrl(key, url); return build('qr', value, value); },
    qrImage(key, png) {
      if (typeof key !== 'string' || !key || key.length > 512 || !Buffer.isBuffer(png) ||
          png.length > maxQrBytes || !png.subarray(0, pngSignature.length).equals(pngSignature)) {
        return Promise.reject(failure('QR_IMAGE_INVALID'));
      }
      const input = Buffer.from(png);
      return build('qr-image', `${hash(key)}:${hash(input)}`, input);
    },
  };
}
