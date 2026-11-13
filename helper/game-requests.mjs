import {randomBytes} from 'node:crypto';

const expired = () => Object.assign(new Error('请求已结束或过期，请重试'), {status:410});

export function createGameRequests({send, delayMs=1000, ttlMs=90_000, limit=32, now=Date.now}) {
  const requests = new Map();
  const replay = new Map();
  // Keep a record for late completions even after the public ID is removed.
  // The response key is weak so a dropped operation cannot retain the record.
  const byResponse = new WeakMap();
  let closed = false;

  const pending = id => ({ok:true, pending:true, requestId:id});

  function detach(task) {
    clearTimeout(task.delayTimer);
    task.response?.off('close', task.onClose);
    task.response = undefined;
    task.onClose = undefined;
  }

  function remove(task) {
    requests.delete(task.id);
    replay.delete(task.id);
    clearTimeout(task.expiryTimer);
    detach(task);
  }

  function discardData(task, data) {
    const discard = task.onDiscard;
    task.onDiscard = undefined;
    // Cleanup must not disclose upstream results or interfere with another request.
    try { Promise.resolve(discard?.(data)).catch(() => {}); } catch { /* cleanup failed */ }
  }

  function discard(task) {
    remove(task);
    const result = task.result;
    task.result = undefined;
    task.state = 'discarded';
    if (result) discardData(task, result.response);
  }

  function get(id) {
    const task = requests.get(id) ?? replay.get(id);
    if (task && task.expiresAt <= now()) { discard(task); return undefined; }
    return task;
  }

  function begin(response, {onDiscard}={}) {
    if (closed) throw expired();
    if (byResponse.has(response)) throw new Error('Response already registered');
    if (requests.size >= limit) {
      for (const id of requests.keys()) get(id);
      if (requests.size >= limit) {
        throw Object.assign(new Error('游戏请求过多，请稍后重试'), {status:429});
      }
    }
    const id = randomBytes(16).toString('hex');
    const task = {id, state:'initial', response, onDiscard, expiresAt:now()+ttlMs};
    byResponse.set(response, task);
    requests.set(id, task);
    if (response.destroyed || response.writableEnded) {
      discard(task);
      return {id};
    }
    task.onClose = () => discard(task);
    response.once('close', task.onClose);
    task.expiryTimer = setTimeout(() => discard(task), ttlMs);
    task.expiryTimer.unref();
    task.delayTimer = setTimeout(() => {
      if (response.destroyed || response.writableEnded) { discard(task); return; }
      detach(task);
      task.state = 'pending';
      try { send(response, pending(id), 200); } catch { discard(task); }
    }, delayMs);
    task.delayTimer.unref();
    return {id};
  }

  function complete(response, data, status=200) {
    const task = byResponse.get(response);
    if (!task) return false;
    if (task.state === 'initial' && (response.destroyed || response.writableEnded)) discard(task);
    if (task.state === 'initial' || task.state === 'pending') get(task.id);
    if (task.state === 'initial') {
      remove(task);
      task.state = 'sent';
      try { send(response, data, status); }
      catch (error) { discardData(task, data); throw error; }
      finally { task.onDiscard = undefined; }
    } else if (task.state === 'pending') {
      task.state = 'result';
      task.result = {ok:true, pending:false, response:data, status};
    } else if (task.state === 'discarded') {
      discardData(task, data);
    }
    return true;
  }

  function poll(id) {
    const task = get(id);
    if (!task) throw expired();
    if (task.state !== 'result') return pending(id);
    if (requests.delete(id)) {
      task.onDiscard = undefined;
      if (replay.size >= limit) discard(replay.values().next().value);
      replay.set(id, task);
    }
    return task.result;
  }

  function cancel(id) {
    const task = get(id);
    if (!task) return false;
    discard(task);
    return true;
  }

  function close() {
    closed = true;
    for (const task of requests.values()) discard(task);
    for (const task of replay.values()) discard(task);
  }

  return {begin, complete, poll, cancel, close};
}
