import test from 'node:test';
import assert from 'node:assert/strict';
import {createUpdateChecker, UPDATE_SOURCE} from '../helper/updates.mjs';

const SIX_HOURS = 6 * 60 * 60 * 1000;
const release = (tag_name, options = {}) => ({tag_name, draft: false, prerelease: false, ...options});
const releases = (...items) => Response.json(items);

test('测试版按数值比较 beta 序号，也接受稳定版', async () => {
  const checker = createUpdateChecker({
    currentVersion: '0.6.0-beta.2',
    minIntervalMs: 0,
    fetchImpl: async () => releases(...items),
  });
  const items = [release('v0.6.0-beta.10', {prerelease: true}), release('0.6.0-beta.2')];
  const beta = await checker.check();
  assert.equal(beta.status, 'available');
  assert.equal(beta.channel, 'beta');
  assert.equal(beta.latest.version, '0.6.0-beta.10');
  assert.equal(beta.latest.url, `${UPDATE_SOURCE.releasesUrl}/tag/v0.6.0-beta.10`);
  items.push(release('0.6.0'));
  assert.equal((await checker.check({force: true})).latest.version, '0.6.0');
  items.splice(0, items.length, release('v0.6.0-beta.2', {prerelease: true}));
  assert.equal((await checker.check({force: true})).status, 'current');
});

test('稳定版忽略预发布、草稿及不合规范的标签', async () => {
  const checker = createUpdateChecker({currentVersion: '0.6.0', fetchImpl: async () => releases(
    release('v0.8.0-beta.2'),
    release('v0.8.0', {prerelease: true}),
    release('v0.7.0', {draft: true}),
    release('v9.9.9\n'),
    release('v0.7.0/../../evil'),
    release('v0.07.0'),
    release('v0.7.0+test'),
    {tag_name: 'v2.0.0'},
    release('v0.5.10'),
    release('0.5.2'),
  )});
  const result = await checker.check();
  assert.equal(result.status, 'current');
  assert.equal(result.channel, 'stable');
  assert.equal(result.latest.version, '0.5.10');
  assert.equal(result.latest.prerelease, false);
});

test('未发布、无法访问和无法识别安装版本有独立状态', async () => {
  for (const response of [releases(), releases(release('1.0.0-beta.1')), releases(release('1.0.0', {draft: true}))]) {
    const checker = createUpdateChecker({currentVersion: '0.6.0', fetchImpl: async () => response, now: () => 123});
    assert.equal(checker.read().status, 'idle');
    assert.deepEqual(await checker.check(), {
      status: 'unpublished', currentVersion: '0.6.0', channel: 'stable', latest: null,
      checkedAt: 123, stale: false, error: null,
    });
  }
  const missing = createUpdateChecker({currentVersion: '0.6.0', fetchImpl: async () => new Response('untrusted', {status: 404})});
  const missingResult = await missing.check();
  assert.equal(missingResult.status, 'error');
  assert.equal(missingResult.checkedAt, null);
  assert.equal(missingResult.error.code, 'not_found');
  assert.doesNotMatch(missingResult.error.message, /untrusted/);

  let calls = 0;
  const invalid = createUpdateChecker({currentVersion: '../1.2.3', fetchImpl: async () => { calls++; }});
  assert.equal((await invalid.check()).error.code, 'invalid_version');
  assert.equal(calls, 0);
});

test('只请求固定官方地址，并仅返回自建链接及限长纯文字', async () => {
  const requests = [];
  const checker = createUpdateChecker({currentVersion: '0.6.0', fetchImpl: async (url, options) => {
    requests.push({url, options});
    return releases(release('v0.6.1', {
      html_url: 'https://external.invalid/release',
      assets: [{browser_download_url: 'https://external.invalid/run.exe'}],
      body: '说明\n<script>alert(1)</script> [细节](https://external.invalid/read)\n<!-- ignore -->\n```js\nalert(2)\n```\nhttps://external.invalid/run.exe\n' + '🎵'.repeat(250),
    }));
  }});
  const result = await checker.check({force: true, url: 'https://external.invalid', repository: 'other/repo'});
  assert.equal(requests.length, 1);
  const [{url, options}] = requests;
  assert.equal(url, 'https://api.github.com/repos/Zechariah0121/dst-music/releases?per_page=20');
  assert.equal(options.method, 'GET');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.redirect, 'manual');
  assert.deepEqual(Object.keys(options.headers).sort(), ['Accept', 'X-GitHub-Api-Version']);
  assert.equal(UPDATE_SOURCE.workshopUrl, 'https://steamcommunity.com/sharedfiles/filedetails/?id=3836261433');
  assert.equal(result.latest.url, 'https://github.com/Zechariah0121/dst-music/releases/tag/v0.6.1');
  assert.equal(Array.from(result.latest.notes).length, 240);
  assert.match(result.latest.notes, /^说明 细节 🎵.*…$/u);
  assert.doesNotMatch(JSON.stringify(result), /external|alert|ignore|browser_download_url/);
  assert.throws(() => { result.latest.version = 'fake'; }, TypeError);
  result.status = 'fake';
  assert.equal(checker.read().status, 'available');
});

test('非 200、重定向和过大的响应只报告受控错误', async () => {
  let cancelled = false;
  const oversized = new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(1025)); },
    cancel() { cancelled = true; },
  }));
  for (const [response, code] of [
    [new Response('{'), 'invalid_response'],
    [Response.json({releases: []}), 'invalid_response'],
    [Response.redirect('https://external.invalid', 302), 'redirect'],
    [new Response('sensitive message', {status: 503}), 'http_error'],
    [new Response('[]', {headers: {'Content-Length': '1025'}}), 'response_too_large'],
    [oversized, 'response_too_large'],
  ]) {
    const checker = createUpdateChecker({currentVersion: '0.6.0', maxResponseBytes: 1024, fetchImpl: async () => response});
    const result = await checker.check();
    assert.equal(result.status, 'error');
    assert.equal(result.error.code, code);
    assert.doesNotMatch(JSON.stringify(result), /external|sensitive/);
  }
  assert.equal(cancelled, true);
});

test('并发检查合并，自动缓存六小时，强制请求有最短间隔', async () => {
  let clock = 1000;
  let calls = 0;
  let respond;
  const pending = new Promise(resolve => { respond = resolve; });
  const checker = createUpdateChecker({currentVersion: '0.6.0', now: () => clock, fetchImpl: async () => {
    calls++;
    return calls === 1 ? pending : releases(release('0.6.1'));
  }});
  const first = checker.check();
  assert.equal(checker.read().status, 'checking');
  assert.strictEqual(checker.check({force: true}), first);
  respond(releases(release('0.6.0')));
  assert.equal((await first).status, 'current');
  clock += 29_999;
  assert.equal((await checker.check({force: true})).status, 'current');
  assert.equal(calls, 1);
  clock++;
  assert.equal((await checker.check({force: true})).status, 'available');
  assert.equal(calls, 2);
  clock += SIX_HOURS - 1;
  assert.equal((await checker.check()).stale, false);
  assert.equal(calls, 2);
  clock++;
  assert.equal(checker.read().stale, true);
  assert.equal((await checker.check()).stale, false);
  assert.equal(calls, 3);
});

test('限频和超时保留之前的结果，并遵守重试时间', async () => {
  let clock = 1000;
  let calls = 0;
  let timeoutSignal;
  const checker = createUpdateChecker({currentVersion: '0.6.0', now: () => clock, timeoutMs: 25, fetchImpl: async (url, {signal}) => {
    calls++;
    if (calls === 2) return new Response('private output', {status: 429, headers: {'Retry-After': '120'}});
    if (calls === 3) {
      timeoutSignal = signal;
      return new Promise(() => {});
    }
    return releases(release(calls === 1 ? '0.6.1' : '0.6.2'));
  }});
  const first = await checker.check();
  clock += 30_000;
  const limited = await checker.check({force: true});
  assert.equal(limited.status, 'error');
  assert.equal(limited.error.code, 'rate_limited');
  assert.equal(limited.error.retryAt, clock + 120_000);
  assert.equal(limited.stale, true);
  assert.equal(limited.checkedAt, first.checkedAt);
  assert.strictEqual(limited.latest, first.latest);
  clock += 119_999;
  await checker.check({force: true});
  assert.equal(calls, 2);
  clock++;
  const timeout = await checker.check();
  assert.equal(timeout.error.code, 'timeout');
  assert.equal(timeoutSignal.aborted, true);
  assert.equal(timeout.checkedAt, first.checkedAt);
  assert.strictEqual(timeout.latest, first.latest);
  clock = timeout.error.retryAt;
  const recovered = await checker.check();
  assert.equal(recovered.status, 'available');
  assert.equal(recovered.latest.version, '0.6.2');
  assert.equal(recovered.stale, false);
});

test('GitHub 主限频 403 尊重 reset，普通 403 仅报告 HTTP 错误', async () => {
  const now = () => 1_000_000;
  const checker = createUpdateChecker({currentVersion: '0.6.0', now, fetchImpl: async () => new Response(null, {
    status: 403, headers: {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1145'},
  })});
  const result = await checker.check();
  assert.equal(result.error.code, 'rate_limited');
  assert.equal(result.error.retryAt, 1_145_000);
  const forbidden = createUpdateChecker({currentVersion: '0.6.0', now, fetchImpl: async () => new Response(null, {status: 403})});
  assert.equal((await forbidden.check()).error.code, 'http_error');
});

test('关闭会中止正在读取的响应，关闭后无法再发出请求', async () => {
  let calls = 0;
  let fetched;
  let cancelled = false;
  const fetchStarted = new Promise(resolve => { fetched = resolve; });
  const checker = createUpdateChecker({currentVersion: '0.6.0', fetchImpl: async (url, {signal}) => {
    calls++;
    fetched(signal);
    return new Response(new ReadableStream({
      pull() { return new Promise(() => {}); },
      cancel() { cancelled = true; },
    }));
  }});
  const check = checker.check();
  const signal = await fetchStarted;
  checker.close();
  assert.equal(signal.aborted, true);
  assert.equal((await check).error.code, 'closed');
  assert.equal(cancelled, true);
  assert.equal((await checker.check({force: true})).error.code, 'closed');
  assert.equal(calls, 1);
  assert.equal(checker.read().checkedAt, null);
});
