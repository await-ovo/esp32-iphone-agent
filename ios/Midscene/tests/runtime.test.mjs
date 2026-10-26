import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
await build({ entryPoints: [root + '/runtime/device.ts', root + '/runtime/transport.ts', root + '/runtime/progress.ts'],
  outdir: root + '/build/tests', platform: 'node', format: 'esm' });
const { PhoneDevice } = await import('../build/tests/device.js');
const { nativeFetch } = await import('../build/tests/transport.js');

function fixture() {
  const calls = [];
  const device = new PhoneDevice(async (method, params) => {
    calls.push({ method, params });
    if (method === 'size') return { width: 200, height: 400 };
  });
  return { calls, action: (name, params) => device.actionSpace().find(a => a.name === name).call(params) };
}

test('official Input modes stay one native action, including optional focus', async () => {
  for (const mode of ['replace', 'typeOnly', 'clear']) {
    const f = fixture();
    await f.action('Input', { value: 'hello', mode, locate: { center: [60, 100] } });
    assert.deepEqual(f.calls.map(c => c.method), ['actionBegin', 'input', 'actionEnd']);
    assert.deepEqual(f.calls[1].params.target, { x: 60, y: 100 });
    assert.equal(f.calls[1].params.mode, mode);
  }
});

test('ClearInput can operate on the current focus without another tap or checks', async () => {
  const f = fixture();
  await f.action('ClearInput', {});
  assert.deepEqual(f.calls.map(c => c.method), ['actionBegin', 'input', 'actionEnd']);
  assert.equal(f.calls[1].params.target, undefined);
  assert.equal(f.calls[1].params.mode, 'clear');
});

test('official Swipe expands relative pixel movement and repeat', async () => {
  const f = fixture();
  await f.action('Swipe', { direction: 'up', distance: 80, duration: 400, repeat: 2 });
  const swipes = f.calls.filter(c => c.method === 'swipe');
  assert.equal(swipes.length, 2);
  assert.deepEqual(swipes[0].params, { start: { x: 100, y: 200 }, end: { x: 100, y: 120 }, duration: 400 });
  assert.equal(f.calls.filter(c => c.method === 'actionBegin').length, 1);
});

test('device failures end the trace as failed and propagate to Midscene', async () => {
  const calls = [];
  const device = new PhoneDevice(async (method, params) => {
    calls.push({ method, params });
    if (method === 'tap') throw Error('board disconnected');
  });
  await assert.rejects(device.actionSpace().find(a => a.name === 'Tap').call({ locate: { center: [1, 2] } }), /board disconnected/);
  assert.match(calls.at(-1).params.error, /board disconnected/);
});

test('native fetch exposes chunks before the response finishes, preserving bytes', async () => {
  const chunks = [Buffer.from('data: '), Buffer.from('你好\n\n'), null];
  let reads = 0;
  const fetch = nativeFetch(async method => {
    if (method === 'httpStart') return { status: 200, headers: { 'content-type': 'text/event-stream' } };
    if (method === 'httpRead') return chunks[reads++]?.toString('base64') ?? null;
  });
  const response = await fetch('https://example.invalid/v1/chat/completions', { method: 'POST', body: '{}' });
  const reader = response.body.getReader();
  assert.equal(new TextDecoder().decode((await reader.read()).value), 'data: ');
  assert.ok(reads < 3, 'the first chunk is available before EOF');
  assert.equal(new TextDecoder().decode((await reader.read()).value), '你好\n\n');
  assert.equal((await reader.read()).done, true);
});

test('aborting fetch cancels native HTTP even while headers are pending', async () => {
  const signal = new AbortController();
  let release, cancelled = 0;
  const fetch = nativeFetch(async method => {
    if (method === 'httpStart') return await new Promise(resolve => { release = resolve; });
    if (method === 'httpCancel') cancelled++;
  });
  const response = fetch('https://example.invalid', { signal: signal.signal });
  await new Promise(resolve => setImmediate(resolve));
  signal.abort();
  release({ status: 200, headers: {} });
  await assert.rejects(response, /abort/i);
  assert.ok(cancelled >= 1);
});

const { progressData } = await import('../build/tests/progress.js');
test('progress forwards structured actions with compact parameters but without screenshots or model reasoning', () => {
  const event = progressData({ scope: 'aiAct', phase: 'action_running', sequence: 8,
    data: { action: { name: 'Tap', target: 'Settings', param: { timeMs: 500, secret: 'value' }, point: [60, 100] },
      screenshot: { base64: 'image' }, thought: 'internal reasoning', durationMs: 123 } });
  assert.equal(event.phase, 'action_running');
  assert.equal(event.sequence, 8);
  assert.deepEqual(event.action, { name: 'Tap', target: 'Settings', param: { timeMs: 500 }, point: [60, 100] });
  assert.equal(event.durationMs, 123);
  assert.equal('screenshot' in event, false);
  assert.equal('thought' in event, false);
  assert.equal(progressData({ scope: 'other', data: {} }), undefined);
});


test('action replay preserves Input values even when progress describes only the located target', async () => {
  const f = fixture();
  await f.action('Input', { value: '08:00', mode: 'replace', locate: { center: [60, 100], screenshot: 'image' } });
  assert.deepEqual(f.calls[0].params, { name: 'Input', param: {
    value: '08:00', mode: 'replace', locate: { center: [60, 100] },
  } });
});

test('replay bounds text and paths and excludes image and model payloads', async () => {
  const { actionParams } = await import('../build/tests/progress.js');
  const params = actionParams({ value: 'a'.repeat(5000), points: Array(200).fill([1, 2]),
    screenshot: 'image', thought: 'reasoning', locate: { center: [1, 2], image: 'image' } });
  assert.equal(params.value.length, 2001);
  assert.equal(params.points.length, 100);
  assert.deepEqual(params.locate, { center: [1, 2] });
  assert.equal('screenshot' in params, false);
  assert.equal('thought' in params, false);
});
