import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter, once} from 'node:events';
import {createServer} from 'node:http';
import {getActiveResourcesInfo} from 'node:process';
import {setTimeout as delay} from 'node:timers/promises';
import {createGameRequests} from '../helper/game-requests.mjs';

function fixture(t, options={}) {
  const sends = [];
  const requests = createGameRequests({delayMs:10, send:(response, data, status)=>{
    sends.push({response, data, status});
    response.writableEnded = true;
    response.emit('sent');
    response.emit('close');
  }, ...options});
  t.after(() => requests.close());
  return {requests, sends};
}

function register(requests, options) {
  const response = new EventEmitter();
  const {id} = requests.begin(response, options);
  return {response, id};
}

test('fast responses preserve the original HTTP status and release their slot', t => {
  const {requests, sends} = fixture(t, {limit:1});
  const {response, id} = register(requests);
  const data = {ok:false, error:'fixture error'};
  assert.equal(requests.complete(new EventEmitter(), data, 403), false);
  assert.equal(requests.complete(response, data, 403), true);
  assert.deepEqual(sends, [{response,data,status:403}]);
  assert.throws(() => requests.poll(id), {status:410});
  assert.equal(response.listenerCount('close'), 0);
  assert.equal(requests.complete(response, data, 403), true);
  assert.equal(sends.length, 1);
  assert.doesNotThrow(() => register(requests));
});

test('real HTTP slow responses return pending and retain original success and failure envelopes', async t => {
  const requests = createGameRequests({delayMs:10, send:(res,data,status)=>{
    res.writeHead(status, {'content-type':'application/json'});
    res.end(JSON.stringify(data));
  }});
  let finish;
  const server = createServer((_req,res)=>{
    requests.begin(res);
    finish = (data,status) => requests.complete(res,data,status);
  });
  server.listen(0,'127.0.0.1');
  await once(server,'listening');
  t.after(async () => {
    requests.close();
    server.closeAllConnections();
    await new Promise(resolve=>server.close(resolve));
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  for (const [data,status] of [[{ok:true,tracks:['fixture']},200],[{ok:false,error:'fixture'},502]]) {
    const initial = await fetch(base);
    assert.equal(initial.status, 200);
    const envelope = await initial.json();
    assert.equal(envelope.ok, true);
    assert.equal(envelope.pending, true);
    assert.match(envelope.requestId, /^[a-f0-9]{32}$/);
    assert.deepEqual(requests.poll(envelope.requestId), envelope);
    assert.equal(finish(data,status), true);
    const expected = {ok:true,pending:false,response:data,status};
    assert.deepEqual(requests.poll(envelope.requestId), expected);
    assert.deepEqual(requests.poll(envelope.requestId), expected);
  }
});

test('disconnect before pending or cancellation after pending discards late data exactly once', async t => {
  const {requests, sends} = fixture(t);
  const dropped = [];
  const first = register(requests,{onDiscard:data=>dropped.push(data)});
  first.response.emit('close');
  assert.throws(() => requests.poll(first.id), {status:410});
  assert.equal(requests.complete(first.response, {key:'late-closed'}), true);
  assert.equal(requests.complete(first.response, {key:'ignored'}), true);
  const closing = register(requests,{onDiscard:data=>dropped.push(data)});
  closing.response.destroyed = true;
  assert.equal(requests.complete(closing.response, {key:'closed-before-event'}), true);
  assert.throws(() => requests.poll(closing.id), {status:410});
  const second = register(requests,{onDiscard:data=>dropped.push(data)});
  await Promise.all([once(second.response,'sent'),delay(20)]);
  assert.deepEqual(sends, [{response:second.response, data:{ok:true,pending:true,requestId:second.id}, status:200}]);
  assert.equal(requests.cancel(second.id), true);
  assert.equal(requests.cancel(second.id), false);
  assert.equal(requests.complete(second.response, {key:'late-canceled'}), true);
  assert.deepEqual(dropped,[{key:'late-closed'},{key:'closed-before-event'},{key:'late-canceled'}]);
});

test('unclaimed results are discarded by cancel or TTL and claimed results remain safe to retry', async t => {
  let now=0;
  const {requests} = fixture(t, {now:()=>now, ttlMs:1000});
  const dropped=[];
  const onDiscard = data=>dropped.push(data);
  const tasks = Array.from({length:3}, () => register(requests,{onDiscard}));
  await Promise.all([...tasks.map(task=>once(task.response,'sent')),delay(20)]);
  for (const task of tasks) requests.complete(task.response, {key:task.id});
  const [canceled, expired, claimed] = tasks;
  requests.cancel(canceled.id);
  assert.deepEqual(requests.poll(claimed.id).response, {key:claimed.id});
  assert.deepEqual(requests.poll(claimed.id).response, {key:claimed.id});
  now=1000;
  assert.throws(() => requests.poll(expired.id), {status:410});
  assert.throws(() => requests.poll(claimed.id), {status:410});
  assert.deepEqual(dropped,[{key:canceled.id},{key:expired.id}]);
});

test('claiming a result frees capacity and bounds the retry cache', async t => {
  const {requests} = fixture(t, {limit:1});
  const first = register(requests);
  await Promise.all([once(first.response,'sent'),delay(20)]);
  requests.complete(first.response, {value:1});
  assert.throws(() => register(requests), {status:429});
  assert.deepEqual(requests.poll(first.id).response, {value:1});
  const second = register(requests);
  await Promise.all([once(second.response,'sent'),delay(20)]);
  requests.complete(second.response, {value:2});
  assert.deepEqual(requests.poll(first.id).response, {value:1});
  assert.deepEqual(requests.poll(second.id).response, {value:2});
  assert.throws(() => requests.poll(first.id), {status:410});
});

test('capacity, idle TTL and close release records and remove listeners and refed timers', async t => {
  const baseline = getActiveResourcesInfo().filter(kind=>kind==='Timeout').length;
  const {requests, sends} = fixture(t, {limit:2, delayMs:200, ttlMs:40});
  const dropped=[];
  const onDiscard = data=>dropped.push(data);
  const first=register(requests,{onDiscard}), second=register(requests,{onDiscard});
  assert.throws(() => register(requests), {status:429});
  assert.equal(getActiveResourcesInfo().filter(kind=>kind==='Timeout').length,baseline);
  await delay(60);
  assert.equal(first.response.listenerCount('close'), 0);
  assert.equal(second.response.listenerCount('close'), 0);
  const third=register(requests,{onDiscard});
  requests.close();
  requests.close();
  assert.equal(third.response.listenerCount('close'), 0);
  assert.throws(() => requests.poll(third.id), {status:410});
  assert.throws(() => register(requests), {status:410});
  requests.complete(first.response,{key:'expired'});
  requests.complete(third.response,{key:'closed'});
  assert.deepEqual(dropped,[{key:'expired'},{key:'closed'}]);
  assert.deepEqual(sends,[]);
});
