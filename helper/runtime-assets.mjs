import {lstat, mkdir, readFile} from 'node:fs/promises';
import {basename, dirname, join, resolve} from 'node:path';

const failure = () => Object.assign(new Error('ASSET_RUNTIME_NOT_OWNED'), {code: 'ASSET_RUNTIME_NOT_OWNED'});

async function checkDirectory(path) {
  const info = await lstat(path);
  // lstat also identifies Windows junctions. Inspecting each component avoids
  // treating ordinary Windows short-name aliases as directory redirection.
  if (info.isSymbolicLink() || !info.isDirectory()) throw failure();
}

function isWorkshopDirectory(target) {
  const parent = dirname(target);
  if (/^workshop-\d+$/i.test(basename(target)) && basename(parent).toLowerCase() === 'mods') return true;
  return /^\d+$/.test(basename(target)) && basename(parent) === '322330' &&
    basename(dirname(parent)).toLowerCase() === 'content' &&
    basename(dirname(dirname(parent))).toLowerCase() === 'workshop' &&
    basename(dirname(dirname(dirname(parent)))).toLowerCase() === 'steamapps';
}

async function readMarker(target, name) {
  const path = join(target, name), info = await lstat(path);
  if (info.isSymbolicLink() || !info.isFile()) throw failure();
  return readFile(path, 'utf8');
}

/** Only the local owned mod or the beta's identified Steam layouts may receive private assets. */
export async function runtimeAssetDestination(runtimeModDir) {
  if (!runtimeModDir) return null;
  const target = resolve(runtimeModDir);
  try {
    // Inspect every ancestor before reading markers or creating descendants.
    // A normal-looking mod can otherwise be reached through an ancestor junction.
    const ancestors = [target];
    while (dirname(ancestors[0]) !== ancestors[0]) ancestors.unshift(dirname(ancestors[0]));
    for (const path of ancestors) await checkDirectory(path);
    if (basename(target).toLowerCase() === 'local_netease_music') {
      if ((await readMarker(target, 'music_bridge_owned.txt')).trim() !== 'dst-local-music-prototype-v1') throw failure();
    } else {
      if (!isWorkshopDirectory(target)) throw failure();
      const identity = JSON.parse(await readMarker(target, 'music_workshop_identity.json'));
      if (!identity || typeof identity !== 'object' ||
          Object.keys(identity).some(key => !['schema', 'id', 'channel', 'version'].includes(key)) ||
          identity.schema !== 1 || identity.id !== 'zcc-dst-music' || identity.channel !== 'workshop-beta' ||
          (Object.hasOwn(identity, 'version') && typeof identity.version !== 'string')) throw failure();
    }
    let destination = target;
    for (const part of ['images', 'music_cache']) {
      destination = join(destination, part);
      try { await mkdir(destination); }
      catch (error) { if (error.code !== 'EEXIST') throw error; }
      await checkDirectory(destination);
    }
    return destination;
  } catch { throw failure(); }
}

export async function runtimeAssetFileExists(directory, name) {
  if (!/^[a-f0-9]{64}\.(?:png|tex|xml)$/.test(name)) throw failure();
  try {
    const info = await lstat(join(directory, name));
    if (info.isSymbolicLink() || !info.isFile()) throw failure();
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw failure();
  }
}
