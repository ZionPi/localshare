const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('lib/main.dart', 'utf8');
const start = source.indexOf('async function uploadFiles(');
const end = source.indexOf('async function deleteCard(', start);
const formatStart = source.indexOf('function formatBytes(');
const formatEnd = source.indexOf('\nfunction ', formatStart + 1);

test('file drops append to the appropriate editor and text drops remain native', () => {
  const listeners = () => {
    const handlers = {};
    const classes = new Set();
    return {handlers, classes, addEventListener: (name, fn) => handlers[name] = fn,
      classList: {add: c => classes.add(c), remove: c => classes.delete(c)}};
  };
  const composerInput = listeners();
  const chatInput = listeners();
  const context = vm.createContext({composerInput, chatInput, pendingFiles: ['existing'],
    chatPendingFiles: [], renderPickedFiles() {}, renderChatPickedFiles() {}});
  const dropStart = source.indexOf('function enableFileDrop(');
  const dropEnd = source.indexOf("chatFileInput.addEventListener('change'", dropStart);
  vm.runInContext(source.slice(dropStart, dropEnd), context);
  let prevented = false;
  const event = {dataTransfer: {types: ['Files'], files: ['one', 'two']},
    preventDefault() {prevented = true;}};
  composerInput.handlers.dragover(event);
  assert.equal(prevented, true);
  assert.equal(composerInput.classes.has('file-drag-over'), true);
  composerInput.handlers.drop(event);
  assert.deepEqual(Array.from(context.pendingFiles), ['existing', 'one', 'two']);
  assert.equal(composerInput.classes.has('file-drag-over'), false);
  chatInput.handlers.drop(event);
  assert.deepEqual(Array.from(context.chatPendingFiles), ['one', 'two']);
  prevented = false;
  composerInput.handlers.drop({dataTransfer: {types: ['text/plain']}, preventDefault() {prevented = true;}});
  assert.equal(prevented, false);
});

function setup() {
  const file = {name: 'backup.zip', type: 'application/zip', size: 600 * 1024 * 1024};
  const button = {disabled: false, textContent: '制卡'};
  const entries = [];
  const toasts = [];
  const requests = [];
  const label = {textContent: ''};
  const bar = {value: 0, removeAttribute() {this.value = null;}};
  const classes = new Set();
  const panel = {
    hidden: true,
    classList: {add: c => classes.add(c), remove: c => classes.delete(c)},
    querySelector: selector => selector === 'progress' ? bar : label,
  };
  class FakeXHR {
    constructor() {this.upload = {}; requests.push(this);}
    open(method, url) {this.method = method; this.url = url;}
    send(form) {this.form = form;}
    progress(loaded, total, lengthComputable = true) {
      this.upload.onprogress({loaded, total, lengthComputable});
    }
    complete(status = 200, payload = {ok: true}) {
      this.status = status;
      this.responseText = JSON.stringify(payload);
      this.onload();
    }
  }
  const context = vm.createContext({
    pendingFiles: [file], composerInput: {value: 'ZIP'}, fileInput: {value: 'chosen'},
    document: {getElementById: id => id === 'createBtn' ? button : panel},
    FormData: class {append(...args) {entries.push(args);}},
    XMLHttpRequest: FakeXHR, setInterval, clearInterval,
    showToast: message => toasts.push(message),
    renderPickedFiles() {}, async refreshCards() {},
  });
  vm.runInContext(source.slice(formatStart, formatEnd) + '\n' + source.slice(start, end), context);
  return {context, file, button, entries, toasts, requests, label, bar, panel, classes};
}

test('600 MiB ZIP is sent directly, with declared size, and success clears input', async () => {
  const state = setup();
  const sending = state.context.createCard();
  const xhr = state.requests[0];
  assert.equal(xhr.url, '/api/cards/upload');
  assert.equal(JSON.parse(state.entries[0][1]).attachments[0].size, state.file.size);
  assert.equal(state.entries[1][1], state.file);
  xhr.complete();
  await sending;
  assert.equal(state.context.pendingFiles.length, 0);
  assert.equal(state.button.disabled, false);
  assert.match(state.label.textContent, /已保存到手机/);
  assert.deepEqual(state.toasts, ['卡片已保存']);
});

test('HTTP error keeps selected ZIP and text and shows server error', async () => {
  const state = setup();
  const sending = state.context.createCard();
  state.requests[0].complete(400, {error: '空间不足'});
  await sending;
  assert.equal(state.context.pendingFiles[0], state.file);
  assert.equal(state.context.composerInput.value, 'ZIP');
  assert.equal(state.context.fileInput.value, 'chosen');
  assert.equal(state.button.disabled, false);
  assert.equal(state.button.textContent, '制卡');
  assert.equal(state.label.textContent, '空间不足');
  assert.equal(state.classes.has('failed'), true);
  assert.deepEqual(state.toasts, ['空间不足']);
});

test('shows bytes and 50%, then waits for server confirmation after upload reaches 100%', async () => {
  const state = setup();
  const sending = state.context.createCard();
  const xhr = state.requests[0];
  xhr.progress(300 * 1024 * 1024, 600 * 1024 * 1024);
  assert.equal(state.panel.hidden, false);
  assert.equal(state.bar.value, 50);
  assert.match(state.label.textContent, /50%.*300.0 MB \/ 600.0 MB/);
  xhr.progress(600 * 1024 * 1024, 600 * 1024 * 1024);
  assert.match(state.label.textContent, /传输完成，正在保存到手机/);
  assert.equal(state.button.disabled, true);
  assert.equal(state.context.pendingFiles.length, 1);
  assert.deepEqual(state.toasts, []);
  xhr.complete();
  await sending;
  assert.equal(state.button.disabled, false);
});

test('unknown transfer length remains indeterminate; network failure preserves input', async () => {
  const state = setup();
  const sending = state.context.createCard();
  const xhr = state.requests[0];
  xhr.progress(1024, 0, false);
  assert.equal(state.bar.value, null);
  assert.match(state.label.textContent, /正在上传…/);
  xhr.onerror();
  await sending;
  assert.match(state.label.textContent, /网络连接中断/);
  assert.equal(state.context.pendingFiles.length, 1);
  assert.equal(state.button.disabled, false);
});

test('HTTP 200 without save confirmation does not report success', async () => {
  const state = setup();
  const sending = state.context.createCard();
  state.requests[0].complete(200, {});
  await sending;
  assert.equal(state.context.pendingFiles.length, 1);
  assert.match(state.label.textContent, /未确认保存成功/);
  assert.equal(state.classes.has('failed'), true);
});
