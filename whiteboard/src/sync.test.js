import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BoardSync } from './sync.js';
const response = revision => ({ ok: true, status: 200, json: async () => ({ revision }) });
const scene = value => JSON.stringify({ elements: [value], files: {}, appState: {} });

test('edits made during an active save are subsequently saved at the new revision', async () => {
  let resolve;
  const sent = [];
  const sync = new BoardSync({ revision: 0, initial: scene(0), status() {}, delay: 999999,
    send: async data => { sent.push(data); return sent.length === 1 ? new Promise(done => { resolve = done; }) : response(2); },
  });
  sync.change(scene(1));
  const saving = sync.flush();
  sync.change(scene(2));
  resolve(response(1));
  await saving;
  await sync.flush();
  clearTimeout(sync.timer);
  assert.deepEqual(sent.map(data => data.revision), [0, 1]);
  assert.deepEqual(sent[1].elements, [2]);
  assert.equal(sync.dirty, false);
});

test('failed saves retain edits and can retry', async () => {
  let failed = true;
  const sync = new BoardSync({ revision: 3, initial: scene(0), status() {}, delay: 999999,
    send: async () => { if (failed) throw new Error('offline'); return response(4); },
  });
  sync.change(scene(1));
  await sync.flush();
  assert.equal(sync.dirty, true);
  failed = false;
  await sync.flush();
  clearTimeout(sync.timer);
  assert.equal(sync.dirty, false);
});

test('conflicts stop automatic saves and retain a local copy for export', async () => {
  let calls = 0;
  const sync = new BoardSync({ revision: 0, initial: scene(0), status() {}, delay: 999999,
    send: async () => { calls++; return { status: 409 }; },
  });
  sync.change(scene(1));
  await sync.flush();
  sync.change(scene(2));
  await sync.flush();
  clearTimeout(sync.timer);
  assert.equal(calls, 1);
  assert.equal(sync.latest, scene(2));
  assert.equal(sync.dirty, true);
});

test('remote updates advance a clean client and the next save uses that revision', async () => {
  let sent;
  const sync = new BoardSync({ revision: 1, initial: scene(0), status() {}, delay: 999999,
    send: async data => { sent = data; return response(3); },
  });
  assert.equal(sync.acceptRemote(scene(1), 2), true);
  assert.equal(sync.dirty, false);
  sync.change(scene(2));
  await sync.flush();
  clearTimeout(sync.timer);
  assert.equal(sent.revision, 2);
});

test('remote refresh cannot overwrite unsaved local drawing', () => {
  const sync = new BoardSync({ revision: 1, initial: scene(0), status() {}, delay: 999999, send() {} });
  sync.change(scene(1));
  assert.equal(sync.acceptRemote(scene(2), 2), false);
  assert.equal(sync.latest, scene(1));
  clearTimeout(sync.timer);
});

test('switching waits for an in-flight save and flushes edits made during it', async () => {
  let resolve;
  const sent = [];
  const sync = new BoardSync({ revision: 0, initial: scene(0), status() {}, delay: 999999,
    send: data => { sent.push(data); return sent.length === 1 ? new Promise(done => { resolve = done; }) : Promise.resolve(response(2)); },
  });
  sync.change(scene(1));
  sync.flush();
  sync.change(scene(2));
  let completed = false;
  const switching = sync.saveAll().then(saved => { completed = true; return saved; });
  await Promise.resolve();
  assert.equal(completed, false);
  resolve(response(1));
  assert.equal(await switching, true);
  clearTimeout(sync.timer);
  assert.equal(sent.length, 2);
  assert.deepEqual(sent.map(data => data.revision), [0, 1]);
  assert.equal(sync.dirty, false);
});

test('failed saves block switching and retain the current scene', async () => {
  const sync = new BoardSync({ revision: 0, initial: scene(0), status() {}, delay: 999999,
    send: async () => { throw new Error('offline'); },
  });
  sync.change(scene(1));
  assert.equal(await sync.saveAll(), false);
  clearTimeout(sync.timer);
  assert.equal(sync.latest, scene(1));
  assert.equal(sync.dirty, true);
});
