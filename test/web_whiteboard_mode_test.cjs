const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('app mode switches the existing web page to one shared editor and back', async () => {
  const source = fs.readFileSync('lib/main.dart', 'utf8');
  const code = source.slice(source.indexOf('function applyWhiteboardMode('), source.indexOf('function escapeHtml(value)'));
  let saves = 0;
  let refreshes = 0;
  let loads = 0;
  let currentSrc;
  const frame = {
    hidden: true,
    getAttribute: () => currentSrc,
    set src(value) { currentSrc = value; loads++; },
    contentWindow: { localShareSave: async () => { saves++; }, localShareRefresh: () => { refreshes++; } },
  };
  const modes = new Map();
  const context = { document: {
    getElementById: id => { assert.equal(id, 'whiteboardFrame'); return frame; },
    body: { classList: { toggle: (mode, value) => modes.set(mode, value) } },
  } };
  vm.createContext(context);
  vm.runInContext(code, context);
  context.applyWhiteboardMode(true);
  assert.equal(frame.hidden, false);
  assert.equal(modes.get('whiteboard-mode'), true);
  assert.equal(currentSrc, '/whiteboard/?shared=1');
  context.applyWhiteboardMode(true);
  assert.equal(loads, 1, 'snapshots must not reload a drawing in progress');
  assert.equal(refreshes, 2);
  context.applyWhiteboardMode(false);
  assert.equal(frame.hidden, true);
  assert.equal(modes.get('whiteboard-mode'), false);
  assert.equal(saves, 1);
});
