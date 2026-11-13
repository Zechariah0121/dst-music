// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Sorihiko/DangoMusic QqLyrics.kt (7d1609d6b259a6b439542058b3f8f0c5969b6e2b).
import {inflateSync} from 'node:zlib';
import {isMainThread, parentPort, Worker, workerData} from 'node:worker_threads';
import {parseLrc} from './lyrics.mjs';

const MAX_BYTES = 2 * 1024 * 1024;
const MAX_SECONDS = 86400;
const IP = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7];
const inverse = new Array(64);
IP.forEach((bit, index) => { inverse[bit - 1] = index + 1; });
const PC1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4];
const PC2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32];
const shifts = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
const expand = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1];
const P = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25];
// QRC's S2 and S4 differ from standard DES.
const boxes = [
  [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
  [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
  [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
  [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14],
  [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
  [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
  [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
  [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
];

function permute(value, width, table) {
  let output = 0n;
  for (const bit of table) output = (output << 1n) | ((value >> BigInt(width - bit)) & 1n);
  return output;
}

function readBlock(bytes, offset) {
  return (BigInt(bytes.readUInt32LE(offset)) << 32n) | BigInt(bytes.readUInt32LE(offset + 4));
}

function schedule(secret, offset, reverse) {
  const bits = permute(readBlock(secret, offset), 64, PC1);
  const mask = 0xfffffffn;
  let left = bits >> 28n, right = bits & mask;
  const keys = shifts.map(value => {
    const shift = BigInt(value);
    left = ((left << shift) | (left >> (28n - shift))) & mask;
    right = ((right << shift) | (right >> (28n - shift))) & mask;
    // QRC moves the right half one bit before the second permutation.
    return permute((left << 28n) | ((right << 1n) & mask), 56, PC2);
  });
  return reverse ? keys.reverse() : keys;
}

const codecKey = Buffer.from('!@#)(*$%123ZXC!@!@#)(NHL', 'ascii');
const schedules = [schedule(codecKey, 16, true), schedule(codecKey, 8, false), schedule(codecKey, 0, true)];
const roundBoxes = boxes.map((box, index) => Array.from({length:64}, (_, value) => {
  const row = ((value & 32) >> 4) | (value & 1);
  return permute(BigInt(box[row * 16 + ((value >> 1) & 15)]) << BigInt(28 - index * 4), 32, P);
}));

function des(block, keys) {
  const initial = permute(block, 64, IP);
  let left = initial >> 32n, right = initial & 0xffffffffn;
  for (const key of keys) {
    const expanded = permute(right, 32, expand) ^ key;
    let mixed = 0n;
    for (let index = 0; index < 8; index++) {
      const value = Number((expanded >> BigInt(42 - index * 6)) & 63n);
      mixed |= roundBoxes[index][value];
    }
    [left, right] = [right, left ^ mixed];
  }
  return permute((right << 32n) | left, 64, inverse);
}

function inflate(bytes) {
  return inflateSync(bytes, {maxOutputLength:MAX_BYTES}).toString('utf8');
}

export function decodeQqLyricText(value) {
  if (typeof value !== 'string' || value.length > MAX_BYTES) return '';
  const source = value.trim();
  if (source.startsWith('<') || source.startsWith('[')) return source;
  if (!source || source.length % 2 !== 0 || !/^[a-f0-9]+$/i.test(source)) return '';
  const bytes = Buffer.from(source, 'hex');
  try { return inflate(bytes); } catch { /* Most payloads use the QRC codec. */ }
  if (bytes.length % 8 !== 0 || bytes.length > 128 * 1024) return '';
  const output = Buffer.alloc(bytes.length);
  for (let offset = 0; offset < bytes.length; offset += 8) {
    let block = readBlock(bytes, offset);
    for (const keys of schedules) block = des(block, keys);
    output.writeUInt32LE(Number(block >> 32n), offset);
    output.writeUInt32LE(Number(block & 0xffffffffn), offset + 4);
  }
  try { return inflate(output); } catch { return ''; }
}

const namedEntities = {amp:'&', quot:'"', apos:"'", lt:'<', gt:'>', nbsp:' '};

export function decodeQqText(text) {
  return typeof text === 'string' ? text.replace(/&(#x[\da-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi, (entity, name) => {
    if (name[0] !== '#') return namedEntities[name.toLowerCase()];
    const code = name[1].toLowerCase() === 'x' ? Number.parseInt(name.slice(2), 16) : Number(name.slice(1));
    return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : entity;
  }) : '';
}

function content(source) {
  const attribute = /LyricContent\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(source);
  return decodeQqText(attribute ? attribute[1] ?? attribute[2] : source);
}

export function parseQrc(source) {
  const lines = [];
  for (const row of content(source).split(/\r?\n/).slice(0, 20000)) {
    const line = /^\[(\d+),(\d+)\](.*)$/.exec(row.trim());
    if (!line) continue;
    const start = Number(line[1]) / 1000;
    const end = start + Number(line[2]) / 1000;
    if (!Number.isFinite(end) || end > MAX_SECONDS || end <= start) continue;
    const words = [];
    let cursor = 0;
    for (const word of line[3].matchAll(/\((\d+),(\d+)\)/g)) {
      const text = line[3].slice(cursor, word.index);
      const wordStart = Number(word[1]) / 1000;
      const wordEnd = wordStart + Number(word[2]) / 1000;
      if (text && wordStart >= start && wordEnd <= end + 0.001 && wordEnd > wordStart) {
        words.push({start:wordStart, end:wordEnd, text});
      }
      cursor = word.index + word[0].length;
    }
    const text = line[3].replace(/\(\d+,\d+\)/g, '').trim();
    if (text && !/^(?:纯音乐(?:[，,\s]*请(?:您)?欣赏)?|instrumental)$/i.test(text)) {
      lines.push({start, end, text, words:words.sort((a, b) => a.start - b.start)});
    }
  }
  return lines.sort((a, b) => a.start - b.start);
}

export function normalizeQqLyrics(lyric, translation, duration = 0) {
  const source = decodeQqLyricText(lyric);
  let lines = parseQrc(source);
  if (!lines.length) lines = parseLrc(content(source), duration);
  const translations = parseLrc(content(decodeQqLyricText(translation)))
    .filter(line => /[\p{L}\p{N}]/u.test(line.text));
  let cursor = 0;
  for (const line of lines) {
    while (cursor + 1 < translations.length &&
           Math.abs(translations[cursor + 1].start - line.start) <= Math.abs(translations[cursor].start - line.start)) cursor++;
    const nearest = translations[cursor];
    if (nearest && nearest.text !== line.text && Math.abs(nearest.start - line.start) <= 1.5) line.translation = nearest.text;
  }
  return {timing:lines.length ? (lines.some(line => line.words.length) ? 'word' : 'line') : 'none', lines};
}

// Even ordinary songs take tens of milliseconds in the QRC codec. A single
// bounded worker keeps that CPU work away from player and transport reports.
export function createQqLyricDecoder({maxPending = 8} = {}) {
  let worker, idleTimer, active;
  let closed = false;
  const pending = [];

  function stop() {
    clearTimeout(idleTimer);
    const current = worker;
    worker = undefined;
    if (current) void current.terminate().catch(() => {});
  }

  function failed() {
    const job = active;
    active = undefined;
    stop();
    job?.reject(new Error('QQ lyric decode failed'));
    run();
  }

  function run() {
    if (active || closed) return;
    if (!pending.length) {
      idleTimer = setTimeout(stop, 20_000);
      idleTimer.unref();
      worker?.unref();
      return;
    }
    clearTimeout(idleTimer);
    active = pending.shift();
    try {
      if (!worker) {
        const current = new Worker(new URL(import.meta.url), {workerData:'qq-lyrics', execArgv:[]});
        worker = current;
        current.on('message', result => {
          if (worker !== current || !active) return;
          const job = active;
          active = undefined;
          if (result) job.resolve(result);
          else job.reject(new Error('QQ lyric decode failed'));
          run();
        });
        current.on('error', () => { if (worker === current) failed(); });
        current.on('exit', () => { if (worker === current) failed(); });
      }
      worker.ref();
      worker.postMessage(active.args);
    } catch { failed(); }
  }

  return {
    decode(lyric, translation, duration) {
      if (closed || pending.length + Number(Boolean(active)) >= maxPending) {
        return Promise.reject(new Error('QQ lyric decoder unavailable'));
      }
      const bounded = value => typeof value === 'string' && value.length <= MAX_BYTES ? value : '';
      return new Promise((resolve, reject) => {
        pending.push({args:[bounded(lyric), bounded(translation), duration], resolve, reject});
        run();
      });
    },
    close() {
      closed = true;
      stop();
      active?.reject(new Error('QQ lyric decoder closed'));
      active = undefined;
      for (const job of pending.splice(0)) job.reject(new Error('QQ lyric decoder closed'));
    },
  };
}

if (!isMainThread && workerData === 'qq-lyrics') {
  parentPort.on('message', args => {
    try { parentPort.postMessage(normalizeQqLyrics(...args)); }
    catch { parentPort.postMessage(null); }
  });
}
