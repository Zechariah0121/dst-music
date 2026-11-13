import test from 'node:test';
import assert from 'node:assert/strict';
import {deflateSync} from 'node:zlib';
import {createQqLyricDecoder, normalizeQqLyrics} from '../helper/qq-lyrics.mjs';

// Synthetic self-written text encoded in QQ's QRC wire format.
const encrypted = 'c90db2e3f6940a43f7471bcb5fa5516ed668524b1f38b70ed14f3f209c635dd46395de183f4c307cbff656eb2d29b7d338b0d346dc5e76a8c827beadfebdb0a9c85d44b083343adf';
const expected = {timing:'word', lines:[{
  start:1, end:2, text:'纸船出发',
  words:[{start:1, end:1.3, text:'纸船'}, {start:1.3, end:2, text:'出发'}],
  translation:'The paper boat leaves.',
}]};

test('QQ QRC uses genuine word intervals and joins the timed translation', () => {
  const translation = deflateSync('[00:01.00]The paper boat leaves.').toString('hex');
  assert.deepEqual(normalizeQqLyrics(encrypted, translation), expected);
  const lrc = normalizeQqLyrics('[00:01.50]A &amp; B', '', 4);
  assert.deepEqual(lrc, {timing:'line', lines:[{start:1.5, end:4, text:'A & B', words:[]}]});
  assert.deepEqual(normalizeQqLyrics('[1000,1000]误差(999,300)尾巴(1200,900)'), {
    timing:'line', lines:[{start:1, end:2, text:'误差尾巴', words:[]}],
  });
  assert.deepEqual(normalizeQqLyrics('[1000,1000]纯音乐，请欣赏(1000,1000)'), {timing:'none', lines:[]});
});

test('QQ lyric worker yields the main thread and bounds pending jobs', async t => {
  const decoder = createQqLyricDecoder({maxPending:1});
  t.after(() => decoder.close());
  const decrypt = decoder.decode(encrypted, '[00:01.00]The paper boat leaves.', 5);
  let finished = false;
  decrypt.then(() => { finished = true; });
  await assert.rejects(decoder.decode(encrypted), /unavailable/);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(finished, false);
  assert.deepEqual(await decrypt, expected);
  const aborted = decoder.decode(encrypted);
  decoder.close();
  await assert.rejects(aborted, /closed/);
});
