const repository = 'Zechariah0121/dst-music';
const workshopId = '3836261433';

export const UPDATE_SOURCE = Object.freeze({
  repository,
  workshopId,
  workshopUrl: `https://steamcommunity.com/sharedfiles/filedetails/?id=${workshopId}`,
  releasesUrl: `https://github.com/${repository}/releases`,
  apiUrl: `https://api.github.com/repos/${repository}/releases?per_page=20`,
});

const CACHE_TTL_MS = 6 * 60 * 60 * 1000;
const CHECK_INTERVAL_MS = 30 * 1000;
const RATE_LIMIT_BACKOFF_MS = 60 * 1000;
const TIMEOUT_MS = 5 * 1000;
const MAX_RESPONSE_BYTES = 512 * 1024;
const MAX_NOTES_CHARACTERS = 240;
const VERSION_PATTERN = /^v?((0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})(?:-beta\.(0|[1-9]\d{0,8}))?)$/;

function parseVersion(tag) {
  if (typeof tag !== 'string' || tag.length > 45) return null;
  const match = VERSION_PATTERN.exec(tag);
  if (!match || match[0] !== tag) return null;
  const [, version, major, minor, patch, beta] = match;
  return {version, parts: [Number(major), Number(minor), Number(patch), beta === undefined ? Infinity : Number(beta)], beta: beta !== undefined};
}

function compareVersions(left, right) {
  for (let i = 0; i < left.parts.length; i++) {
    if (left.parts[i] !== right.parts[i]) return left.parts[i] - right.parts[i];
  }
  return 0;
}

function plainNotes(body) {
  if (typeof body !== 'string') return '';
  const text = body.slice(0, 4096)
    .replace(/```[\s\S]*?(?:```|$)/g, ' ')
    .replace(/<(script|style)\b[^<>]*>[\s\S]*?(?:<\/\1\s*>|$)/gi, ' ')
    .replace(/<!--[^]*?(?:-->|$)/g, ' ')
    .replace(/<[^<>]*(?:>|$)/g, ' ')
    .replace(/!?\[([^\]\n]*)\]\([^\n)]*\)/g, '$1')
    .replace(/\b(?:https?:\/\/|javascript:|data:|file:\/\/|www\.)[^\s]+/gi, ' ')
    .replace(/[`<>\p{Cc}\p{Cf}]/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim();
  const characters = Array.from(text);
  return characters.length <= MAX_NOTES_CHARACTERS
    ? text
    : `${characters.slice(0, MAX_NOTES_CHARACTERS - 1).join('')}…`;
}

function selectLatest(releases, installed) {
  let latest = null;
  for (const release of releases) {
    if (release?.draft !== false || typeof release.prerelease !== 'boolean') continue;
    const parsed = parseVersion(release.tag_name);
    if (!parsed) continue;
    const prerelease = parsed.beta || release.prerelease;
    if (!installed.beta && prerelease) continue;
    if (latest) {
      const comparison = compareVersions(parsed, latest.parsed);
      if (comparison < 0 || (comparison === 0 && (!latest.prerelease || prerelease))) continue;
    }
    latest = {parsed, prerelease, tag: release.tag_name, body: release.body};
  }
  if (!latest) return {status: 'unpublished', latest: null};
  return {
    status: compareVersions(latest.parsed, installed) > 0 ? 'available' : 'current',
    latest: Object.freeze({
      version: latest.parsed.version,
      tag: latest.tag,
      prerelease: latest.prerelease,
      url: `${UPDATE_SOURCE.releasesUrl}/tag/${encodeURIComponent(latest.tag)}`,
      notes: plainNotes(latest.body),
    }),
  };
}

class UpdateCheckError extends Error {
  constructor(code, message, retryAt = null) {
    super(message);
    this.code = code;
    this.retryAt = retryAt;
  }
}

function rateLimitRetryAt(headers, now) {
  const retry = headers.get('retry-after')?.trim();
  const retryAt = retry && /^\d+$/.test(retry) ? now + Number(retry) * 1000 : Date.parse(retry);
  const reset = headers.get('x-ratelimit-reset')?.trim();
  const resetAt = headers.get('x-ratelimit-remaining') === '0' && /^\d+$/.test(reset)
    ? Number(reset) * 1000
    : NaN;
  const times = [retryAt, resetAt].filter(time => Number.isSafeInteger(time) && time >= now);
  return times.length ? Math.max(...times) : now + RATE_LIMIT_BACKOFF_MS;
}

async function readReleases(response, signal, maxResponseBytes) {
  const tooLarge = () => new UpdateCheckError('response_too_large', 'GitHub 发布列表超过大小限制。');
  if (Number(response.headers.get('content-length')) > maxResponseBytes) {
    void response.body?.cancel().catch(() => {});
    throw tooLarge();
  }
  if (!response.body) throw new UpdateCheckError('invalid_response', 'GitHub 返回了无效的发布列表。');

  const reader = response.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener('abort', cancel, {once: true});
  const decoder = new TextDecoder();
  let bytes = 0;
  let json = '';
  try {
    for (;;) {
      signal.throwIfAborted();
      const {done, value} = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maxResponseBytes) throw tooLarge();
      json += decoder.decode(value, {stream: true});
    }
    signal.throwIfAborted();
    const releases = JSON.parse(json + decoder.decode());
    if (Array.isArray(releases)) return releases;
  } catch (error) {
    cancel();
    if (!(error instanceof SyntaxError)) throw error;
  } finally {
    signal.removeEventListener('abort', cancel);
    reader.releaseLock();
  }
  throw new UpdateCheckError('invalid_response', 'GitHub 返回了无效的发布列表。');
}

export function createUpdateChecker({
  currentVersion,
  fetchImpl = fetch,
  now = Date.now,
  ttlMs = CACHE_TTL_MS,
  minIntervalMs = CHECK_INTERVAL_MS,
  timeoutMs = TIMEOUT_MS,
  maxResponseBytes = MAX_RESPONSE_BYTES,
} = {}) {
  const installed = parseVersion(currentVersion);
  const invalidVersion = Object.freeze({code: 'invalid_version', message: '无法识别当前安装的版本。', retryAt: null});
  const closedError = Object.freeze({code: 'closed', message: '版本检查已关闭。', retryAt: null});
  let lastResult = null;
  let lastError = null;
  let nextAttemptAt = -Infinity;
  let active = null;
  let closed = false;

  function read() {
    const error = closed ? closedError : installed ? lastError : invalidVersion;
    let status = lastResult?.status ?? 'idle';
    if (active && !closed) status = 'checking';
    else if (error) status = 'error';
    return {
      status,
      currentVersion: installed?.version ?? null,
      channel: installed ? (installed.beta ? 'beta' : 'stable') : null,
      latest: lastResult?.latest ?? null,
      checkedAt: lastResult?.checkedAt ?? null,
      stale: !!lastResult && (!!error || now() - lastResult.checkedAt >= ttlMs),
      error,
    };
  }

  async function fetchReleases(signal) {
    signal.throwIfAborted();
    const response = await fetchImpl(UPDATE_SOURCE.apiUrl, {
      method: 'GET',
      headers: {Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'},
      credentials: 'omit',
      redirect: 'manual',
      signal,
    });
    if (!signal.aborted && !response.redirected && response.status === 200) {
      return readReleases(response, signal, maxResponseBytes);
    }
    void response.body?.cancel().catch(() => {});
    signal.throwIfAborted();
    if (response.redirected || (response.status >= 300 && response.status < 400)) {
      throw new UpdateCheckError('redirect', 'GitHub 发布列表重定向，已停止检查。');
    }
    if (response.status === 404) throw new UpdateCheckError('not_found', 'GitHub 发布页暂不可公开访问。');
    if (response.status === 429 || (response.status === 403 && (response.headers.has('retry-after') || response.headers.get('x-ratelimit-remaining') === '0'))) {
      throw new UpdateCheckError('rate_limited', 'GitHub 暂时限制了检查频率，请稍后再试。', rateLimitRetryAt(response.headers, now()));
    }
    throw new UpdateCheckError('http_error', 'GitHub 发布列表暂不可用。');
  }

  async function run(controller) {
    const {signal} = controller;
    const timeout = setTimeout(() => controller.abort(new UpdateCheckError('timeout', '连接 GitHub 检查更新超时。')), timeoutMs);
    let onAbort;
    const aborted = new Promise((resolve, reject) => {
      onAbort = () => reject(signal.reason);
      if (signal.aborted) onAbort();
      else signal.addEventListener('abort', onAbort, {once: true});
    });
    try {
      const releases = await Promise.race([fetchReleases(signal), aborted]);
      signal.throwIfAborted();
      lastResult = {...selectLatest(releases, installed), checkedAt: now()};
      lastError = null;
    } catch (cause) {
      if (!closed) {
        const error = cause instanceof UpdateCheckError ? cause : new UpdateCheckError('network_error', '无法连接 GitHub 检查更新，请稍后再试。');
        const retryAt = Math.max(now() + minIntervalMs, error.retryAt ?? 0);
        nextAttemptAt = retryAt;
        lastError = Object.freeze({code: error.code, message: error.message, retryAt});
      }
    } finally {
      clearTimeout(timeout);
      signal.removeEventListener('abort', onAbort);
      active = null;
    }
    return read();
  }

  function check({force = false} = {}) {
    if (closed || !installed) return Promise.resolve(read());
    if (active) return active.promise;
    const time = now();
    if (time < nextAttemptAt || (!force && !lastError && lastResult && time - lastResult.checkedAt < ttlMs)) {
      return Promise.resolve(read());
    }
    nextAttemptAt = time + minIntervalMs;
    const controller = new AbortController();
    const promise = Promise.resolve().then(() => run(controller));
    active = {controller, promise};
    return promise;
  }

  function close() {
    closed = true;
    active?.controller.abort(closedError);
  }

  return {read, check, close};
}
