import {randomBytes} from 'node:crypto';
import {lstat, mkdir, open, readFile, rename, unlink} from 'node:fs/promises';
import {basename, dirname, join, resolve} from 'node:path';
import {performance} from 'node:perf_hooks';

const failure = () => new Error('GAME_CONNECTION_NOT_OWNED');
const filename = 'dangomusic_connection.lua';

async function directory(path) {
  const info = await lstat(path);
  if (info.isSymbolicLink() || !info.isDirectory()) throw failure();
}

async function regularFile(path) {
  const info = await lstat(path);
  if (info.isSymbolicLink() || !info.isFile()) throw failure();
}

async function marker(target, name) {
  const path = join(target, name);
  await regularFile(path);
  return readFile(path, 'utf8');
}

function workshop(target) {
  const parent = dirname(target);
  return (/^workshop-\d+$/i.test(basename(target)) && basename(parent).toLowerCase() === 'mods') ||
    (/^\d+$/.test(basename(target)) && basename(parent) === '322330' &&
      basename(dirname(parent)).toLowerCase() === 'content' &&
      basename(dirname(dirname(parent))).toLowerCase() === 'workshop' &&
      basename(dirname(dirname(dirname(parent)))).toLowerCase() === 'steamapps');
}

async function ownedTarget(target, runtime) {
  // 每次检查都重新验证现存根目录；卸载后不创建或复活模组目录。
  const ancestors = [target];
  while (dirname(ancestors[0]) !== ancestors[0]) ancestors.unshift(dirname(ancestors[0]));
  for (const path of ancestors) await directory(path);
  if (basename(target).toLowerCase() === 'local_netease_music') {
    if ((await marker(target, 'music_bridge_owned.txt')).trim() !== 'dst-local-music-prototype-v1') throw failure();
  } else {
    // 包内 modDir 由启动参数明确指定，允许目录名不同；安装目录保持既有工坊布局约束。
    if (runtime && !workshop(target)) throw failure();
    const identity = JSON.parse(await marker(target, 'music_workshop_identity.json'));
    if (!identity || typeof identity !== 'object' ||
        Object.keys(identity).some(key => !['schema', 'id', 'channel', 'version'].includes(key)) ||
        identity.schema !== 1 || identity.id !== 'zcc-dst-music' || identity.channel !== 'workshop-beta' ||
        (Object.hasOwn(identity, 'version') && typeof identity.version !== 'string')) throw failure();
  }
}

async function optionalConnection(path) {
  try {
    await regularFile(path);
    return await readFile(path, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

/** 只维护本次启动明确连接的一个模组；不发现目录、不提供读取令牌的网络接口。 */
export function createGameConnection({modDir, runtimeModDir, port, token, intervalMs = 5000, now = () => performance.now()}) {
  if (!modDir || !Number.isInteger(port) || port < 1 || port > 65535 ||
      typeof token !== 'string' || !/^[a-zA-Z0-9_-]{24,128}$/.test(token) ||
      !Number.isFinite(intervalMs) || intervalMs < 250) throw new Error('GAME_CONNECTION_OPTIONS_INVALID');
  const target = resolve(runtimeModDir || modDir), runtime = Boolean(runtimeModDir);
  const scripts = join(target, 'scripts'), path = join(scripts, filename);
  const content = `return {host="127.0.0.1",port=${port},token="${token}"}\n`;
  let stopped = false, started = false, timer, pending, lastCheck = -Infinity;

  async function repair() {
    let temporary, temporaryOwned = false;
    try {
      await ownedTarget(target, runtime);
      if (stopped) return false;
      try { await mkdir(scripts); } catch (error) { if (error.code !== 'EEXIST') throw error; }
      await directory(scripts);
      if (await optionalConnection(path) === content || stopped) return false;
      // 临时文件独占创建；重验身份后原子替换，避免读到半截 Lua 或跟随已存在的链接。
      await ownedTarget(target, runtime);
      await directory(scripts);
      if (stopped) return false;
      temporary = join(scripts, `.${filename}.${randomBytes(12).toString('hex')}.tmp`);
      const handle = await open(temporary, 'wx', 0o600);
      temporaryOwned = true;
      try { await handle.writeFile(content); } finally { await handle.close(); }
      await ownedTarget(target, runtime);
      await directory(scripts);
      await optionalConnection(path);
      if (stopped) return false;
      await rename(temporary, path);
      temporary = undefined;
      return true;
    } catch {
      // Steam 更新、卸载或临时拒绝访问都由下次检查重试；不传播异步异常或记录令牌。
      return false;
    } finally {
      if (temporary && temporaryOwned) await unlink(temporary).catch(() => {});
    }
  }

  function check() {
    if (stopped) return Promise.resolve(false);
    if (pending) return pending;
    const time = now();
    if (time - lastCheck < intervalMs) return Promise.resolve(false);
    lastCheck = time;
    pending = repair().finally(() => { pending = undefined; });
    return pending;
  }

  function schedule() {
    if (stopped) return;
    timer = setTimeout(() => {
      timer = undefined;
      // 捕获包含可注入时钟在内的错误，保证定时器没有未处理拒绝。
      Promise.resolve().then(check).catch(() => false).finally(schedule);
    }, intervalMs);
    timer.unref?.();
  }

  return {
    check,
    async start() {
      if (started || stopped) return false;
      started = true;
      try { return await check(); } finally { schedule(); }
    },
    async close() {
      stopped = true;
      clearTimeout(timer);
      // 等待当前写入收尾；close 返回后不能再产生连接文件。
      await pending;
    },
  };
}
