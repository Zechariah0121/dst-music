// Opt in on Windows with DANGO_RUN_AUDIO_TIMING=1. This plays quiet synthetic
// signals through the default output and captures no raw audio to disk.
import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp, rm, writeFile} from 'node:fs/promises';
import http from 'node:http';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {performance} from 'node:perf_hooks';
import {createInterface} from 'node:readline';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';

const token = 'native_output_timing_fixture_only';
const powershell = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const duration = 7;
const windowMs = 20;
const lyricSeconds = [1, 2, 3, 4, 5, 6];
const now = () => performance.now();

function wave(rate, track) {
  const channels = 2;
  const frameSize = channels * 2;
  const samples = rate * duration;
  const bytes = Buffer.alloc(44 + frameSize * samples);
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8);
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(channels, 22);
  bytes.writeUInt32LE(rate, 24); bytes.writeUInt32LE(rate * frameSize, 28); bytes.writeUInt16LE(frameSize, 32);
  bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(bytes.length - 44, 40);
  for (let frame = 0; frame < samples; frame++) {
    const time = frame / rate;
    const marker = 950 + 150 * Math.floor(time);
    const tag = track === 'a' ? 500 : 650;
    const secondTag = track === 'a' ? 2450 : 2750;
    const fade = Math.min(1, time * 200, (duration - time) * 200);
    const sample = Math.round(fade * 1310 * (Math.sin(2 * Math.PI * tag * time) + Math.sin(2 * Math.PI * secondTag * time) + Math.sin(2 * Math.PI * marker * time)));
    for (let channel = 0; channel < channels; channel++) bytes.writeInt16LE(sample, 44 + frameSize * frame + 2 * channel);
  }
  return bytes;
}

function childFor(script, args = [], env = process.env, collectStdout = false) {
  const child = spawn(powershell, ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', fileURLToPath(new URL(script, import.meta.url)), ...args], {windowsHide:true, env});
  let output = '';
  let exited = false;
  let exitCode;
  let launchError;
  child.stderr.on('data', data => { output += data; });
  if (collectStdout) child.stdout.on('data', data => { output += data; });
  child.on('error', error => { launchError = error; });
  child.on('close', code => { exited = true; exitCode = code; });
  // A failed child may close its command pipe before the parent observes exit.
  child.stdin.on('error', () => {});
  return {
    child,
    get output() { return output || launchError?.message || ''; },
    get exited() { return exited; },
    get exitCode() { return exitCode; },
  };
}

async function until(find, label, children, timeoutMs = 6000) {
  const deadline = now() + timeoutMs;
  while (now() < deadline) {
    const result = find();
    if (result) return result;
    const exited = children.find(process => process.exited);
    if (exited) assert.fail(`${label}: child exited (${exited.exitCode})\n${exited.output}`);
    await delay(6);
  }
  assert.fail(`${label}: timed out after ${timeoutMs} ms\n${children.map(process => process.output).join('\n')}`);
}

function createCapture() {
  const process = childFor('./native-output-timing.ps1');
  const tones = [];
  const replies = new Map();
  let format;
  let badTimestamps;
  const lines = createInterface({input:process.child.stdout});
  lines.on('line', line => {
    const [kind, one, two, three] = line.split(' ');
    if (kind === 'ready') format = {rate:+one, channels:+two, bits:+three};
    if (kind === 'tone') tones.push({qpc:+one, mask:+two});
    if (kind === 'clock') replies.set(+one, {qpc:+two, receivedAt:now()});
    if (kind === 'bad-timestamps') badTimestamps = +one;
  });
  return {
    process,
    tones,
    get format() { return format; },
    get badTimestamps() { return badTimestamps; },
    async calibrate() {
      let best;
      for (let id = 0; id < 8; id++) {
        const sentAt = now();
        process.child.stdin.write(`ping ${id}\n`);
        const {qpc, receivedAt} = await until(() => replies.get(id), 'calibrating QPC', [process]);
        const roundTripMs = receivedAt - sentAt;
        if (!best || roundTripMs < best.roundTripMs) best = {roundTripMs, offsetMs:(sentAt + receivedAt) / 2 - qpc};
      }
      return best;
    },
  };
}

function mockBridge(rate, replacementRate) {
  const audio = {a:wave(rate, 'a'), b:wave(replacementRate, 'b')};
  const reports = [];
  const waiters = new Set();
  let desired = {revision:0, seekRevision:0, track:null, mediaUrl:null, playing:false, volume:0.1, position:0};
  function send(res, body, status = 200) {
    if (!res.destroyed) { res.writeHead(status, {'content-type':'application/json'}); res.end(JSON.stringify(body)); }
  }
  const state = res => send(res, {ok:true, audioRevision:desired.revision, desired});
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.headers.authorization !== `Bearer ${token}` && url.searchParams.get('token') !== token) return send(res, {}, 401);
    if (url.pathname === '/api/media' && Object.hasOwn(audio, url.searchParams.get('trackId'))) {
      const bytes = audio[url.searchParams.get('trackId')];
      res.writeHead(200, {'content-type':'audio/wav', 'content-length':bytes.length});
      res.end(bytes);
    } else if (url.pathname === '/api/player/claim') {
      req.resume();
      send(res, {ok:true});
    } else if (url.pathname === '/api/player/state') {
      if (Number(url.searchParams.get('after') ?? -1) !== desired.revision) return state(res);
      const wake = () => { waiters.delete(wake); clearTimeout(timer); state(res); };
      const timer = setTimeout(wake, 8000);
      waiters.add(wake);
      res.on('close', () => { waiters.delete(wake); clearTimeout(timer); });
    } else if (url.pathname === '/api/player/report') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      reports.push({...JSON.parse(Buffer.concat(chunks).toString()), at:now()});
      send(res, {ok:true});
    } else send(res, {}, 404);
  });
  function change(patch) {
    const at = now();
    desired = {...desired, ...patch, revision:desired.revision + 1};
    for (const wake of [...waiters]) wake();
    return {revision:desired.revision, at};
  }
  return {
    reports, server, change,
    track(id, seekRevision) {
      return change({track:{id, duration}, mediaUrl:`/api/media?trackId=${id}&token=${token}`, playing:true, position:0, seekRevision});
    },
  };
}

const ms = value => Math.round(value * 10) / 10;
const skip = process.platform !== 'win32' ? 'Windows render endpoint required'
  : process.env.DANGO_RUN_AUDIO_TIMING !== '1' ? 'set DANGO_RUN_AUDIO_TIMING=1 to play quiet synthetic tones' : false;
const modes = process.env.DANGO_AUDIO_OUTPUT ? [process.env.DANGO_AUDIO_OUTPUT] : ['wasapi', 'waveout'];
let mixedAudioInterference = false;

for (const mode of modes) for (const rate of [44100, 48000]) {
  test(`native ${mode} ${rate} Hz audible playback and lyric clock`, {skip, timeout:45000}, async t => {
    if (mixedAudioInterference) return t.skip('fixture frequencies already present in the endpoint mix');
    const dir = await mkdtemp(join(tmpdir(), 'dango-output-timing-'));
    const replacementRate = rate === 44100 ? 48000 : 44100;
    const bridge = mockBridge(rate, replacementRate);
    const children = [];
    const measures = {mode, sourceRate:rate, replacementRate};
    let capture;
    t.after(async () => {
      try {
        const pending = children.filter(({exited}) => !exited).map(process => {
          const closed = once(process.child, 'close');
          if (process === children[0]) process.child.stdin.end('stop\n'); else process.child.kill();
          const kill = setTimeout(() => process.child.kill(), 1500);
          return closed.finally(() => clearTimeout(kill));
        });
        await Promise.allSettled(pending);
        bridge.server.closeAllConnections();
        if (bridge.server.listening) await new Promise(resolve => bridge.server.close(resolve));
      } finally {
        const lastReport = bridge.reports.at(-1);
        t.diagnostic(JSON.stringify({...measures, matchedWindows:capture?.tones.length, badLoopbackTimestamps:capture?.badTimestamps,
          lastReport:lastReport && {revision:lastReport.revision, position:lastReport.position, playing:lastReport.playing, error:lastReport.error}}));
        await rm(dir, {recursive:true, force:true, maxRetries:5});
      }
    });
    await new Promise(resolve => bridge.server.listen(0, '127.0.0.1', resolve));
    await writeFile(join(dir, 'bridge.json'), JSON.stringify({host:'127.0.0.1', port:bridge.server.address().port, token}));
    capture = createCapture();
    children.push(capture.process);
    measures.mixFormat = await until(() => capture.format, 'opening render loopback', children, 15000);
    const clock = await capture.calibrate();
    measures.clockSyncRoundTripMs = ms(clock.roundTripMs);
    const worker = childFor('../helper/NativePlayer.ps1', ['-StateDir', dir, '-ParentProcessId', String(process.pid)], {...process.env, DANGO_AUDIO_OUTPUT:mode}, true);
    children.push(worker);
    worker.child.stdout.resume();
    const checks = [];
    const check = (pass, label) => { if (!pass) checks.push(label); };
    const {reports} = bridge;
    const wait = (find, label, timeout) => until(() => {
      const error = reports.find(report => report.error);
      if (error) assert.fail(`native playback failed: ${error.error}\n${worker.output}`);
      return find();
    }, label, children, timeout);
    // Loopback QPC comes from the first captured frame, independent of when
    // the polling thread or this test receives the corresponding packet.
    const at = tone => tone.qpc + clock.offsetMs;
    const tag = track => track === 'a' ? 1 | (1 << 9) : 2 | (1 << 10);
    const matching = (track, start, end = Infinity, marker = undefined) => capture.tones.filter(tone =>
      (tone.mask & tag(track)) === tag(track) && at(tone) >= start - windowMs && at(tone) < end &&
      (marker === undefined || (tone.mask & (1 << (marker + 2)))));
    function firstSustained(track, start, marker) {
      const tones = matching(track, start, Infinity, marker);
      return tones.find((tone, index) => index + 1 < tones.length && at(tones[index + 1]) - at(tone) <= windowMs + 3);
    }
    const hear = (track, start, marker) => wait(() => firstSustained(track, start, marker), `hearing track ${track}, marker ${marker ?? 'any'}`);
    const report = (command, find, label) => wait(() => reports.find(r => r.revision === command.revision && find(r)), label, 10000);
    const elapsed = (command, observedAt) => ms(observedAt - command.at);

    await wait(() => reports[0], 'worker starts', 20000);
    measures.prePlaybackToneMatches = capture.tones.length;
    mixedAudioInterference = measures.prePlaybackToneMatches > 0;
    assert.equal(measures.prePlaybackToneMatches, 0, 'fixture frequencies already present in the endpoint mix');
    const full = bridge.track('a', 1);
    const first = await hear('a', full.at, 0);
    measures.startCommandToLoopbackMs = elapsed(full, at(first));
    const started = await report(full, r => r.playing, 'start reported');
    measures.startCommandToReportMs = elapsed(full, started.at);
    const selectedOutput = /native_audio output=(\S+)/.exec(worker.output)?.[1];
    measures.selectedOutput = selectedOutput ?? null;
    const expected = mode === 'auto' ? ['wasapi-shared', 'waveout'] : [mode === 'wasapi' ? 'wasapi-shared' : mode];
    check(expected.includes(selectedOutput), `expected selected output ${expected.join(' or ')}, got ${selectedOutput}`);

    const ended = await report(full, r => r.ended, 'seven-second track ended');
    await delay(120);
    const fullTones = matching('a', full.at);
    const last = fullTones.at(-1);
    measures.fullPlaybackMs = ms(at(last) + windowMs - at(first));
    measures.maxAudibleGapMs = ms(Math.max(0, ...fullTones.slice(1).map((tone, index) => at(tone) - at(fullTones[index]) - windowMs)));
    measures.reportedDurationMs = ms(ended.duration * 1000);
    measures.endReportRelativeToLoopbackMs = ms(ended.at - at(last) - windowMs);
    measures.lyricClockErrorMs = lyricSeconds.map(second => {
      const tone = firstSustained('a', full.at, second);
      if (!tone) return null;
      // Mirror the bridge's clock extrapolation from the latest worker report.
      const latest = reports.findLast(r => r.revision === full.revision && r.playing && r.at <= at(tone));
      return latest ? ms(latest.position * 1000 + at(tone) - latest.at - second * 1000) : null;
    });
    check(Math.abs(measures.fullPlaybackMs - 7000) <= 180, 'seven seconds of actual audio within 180 ms');
    check(measures.maxAudibleGapMs <= 65, 'no gap longer than 65 ms in continuous playback');
    check(Math.abs(measures.reportedDurationMs - 7000) <= 20, 'reported duration is seven seconds');
    check(measures.lyricClockErrorMs.every(error => error !== null && Math.abs(error) <= 150), 'all six lyric markers agree with report-derived clock within 150 ms');

    const restart = bridge.track('a', 2);
    await hear('a', restart.at, 1);
    await delay(180);
    const pause = bridge.change({playing:false});
    const paused = await report(pause, r => !r.playing, 'pause reported');
    await delay(700);
    const pauseEnd = now();
    const pauseTail = matching('a', restart.at, pauseEnd).at(-1);
    measures.pauseCommandToReportMs = elapsed(pause, paused.at);
    measures.pauseCommandToLoopbackSilenceMs = elapsed(pause, at(pauseTail) + windowMs);
    measures.pauseClockDriftMs = ms(1000 * Math.abs(reports.findLast(r => r.revision === pause.revision).position - paused.position));
    check(measures.pauseCommandToLoopbackSilenceMs <= 250, 'pause suppresses fixture audio within 250 ms');
    check(measures.pauseCommandToReportMs <= 250, 'pause reaches the worker report within 250 ms');
    check(measures.pauseClockDriftMs <= 80, 'paused content clock drift stays within 80 ms');

    const resume = bridge.change({playing:true});
    const resumedTone = await hear('a', resume.at, 1);
    const resumed = await report(resume, r => r.playing, 'resume reported');
    measures.resumeCommandToLoopbackMs = elapsed(resume, at(resumedTone));
    measures.resumeCommandToReportMs = elapsed(resume, resumed.at);
    measures.resumeClockJumpMs = ms(1000 * (resumed.position - paused.position));
    check(Math.abs(measures.resumeClockJumpMs) <= 250, 'resume does not count paused time as content');

    const seek = bridge.change({position:4.25, seekRevision:3});
    const soughtTone = await hear('a', seek.at, 4);
    const sought = await report(seek, r => r.playing && r.position >= 4.24, 'seek reported');
    measures.seekCommandToLoopbackMs = elapsed(seek, at(soughtTone));
    measures.seekCommandToReportMs = elapsed(seek, sought.at);
    const fifthSecond = await hear('a', seek.at, 5);
    measures.seekToNextMarkerMs = ms(at(fifthSecond) - at(soughtTone));
    check(Math.abs(measures.seekToNextMarkerMs - 750) <= 100, 'seek starts at 4.25 seconds relative to following five-second marker');

    const switched = bridge.track('b', 4);
    const switchedTone = await hear('b', switched.at, 0);
    const switchedReport = await report(switched, r => r.playing, 'replacement reported');
    await delay(450);
    const lastOldTone = matching('a', seek.at).at(-1);
    measures.switchCommandToLoopbackMs = elapsed(switched, at(switchedTone));
    measures.switchCommandToReportMs = elapsed(switched, switchedReport.at);
    measures.switchCommandToOldToneEndMs = elapsed(switched, at(lastOldTone) + windowMs);
    measures.oldToneAfterNewToneMs = ms(Math.max(0, at(lastOldTone) + windowMs - at(switchedTone)));
    check(measures.switchCommandToOldToneEndMs <= 250, 'old track leaves the endpoint within 250 ms of replacement');
    check(measures.oldToneAfterNewToneMs <= 40, 'old track does not recur after the replacement starts');
    check(clock.roundTripMs < 30, 'clock synchronization round trip is under 30 ms');
    for (const field of ['start', 'resume', 'seek', 'switch']) {
      check(measures[`${field}CommandToLoopbackMs`] <= 1000, `${field} becomes audible within one second`);
      check(measures[`${field}CommandToReportMs`] <= 1000, `${field} reaches the worker report within one second`);
    }
    assert.deepEqual(checks, [], worker.output);
  });
}
