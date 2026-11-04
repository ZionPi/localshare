import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Excalidraw, MainMenu, exportToBlob, serializeAsJSON } from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';
import './style.css';
import { BoardSync } from './sync.js';

const labels = {
  loading: '正在读取白板…', pending: '有更改，等待保存', saving: '正在保存到手机…',
  saved: '已保存到手机 · 卡片已更新', error: '保存失败，将自动重试',
  warning: '白板已保存，卡片更新失败',
  conflict: '其他页面已修改白板。请先导出备份，再重新载入。',
};
const embedded = new URLSearchParams(location.search).has('app');
const shared = new URLSearchParams(location.search).has('shared');
function download(blob, name) {
  if (window.LocalShare) {
    const reader = new FileReader();
    reader.onload = () => window.LocalShare.postMessage(JSON.stringify({ type: 'download', name, dataURL: reader.result }));
    reader.readAsDataURL(blob);
    return;
  }
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
function BoardEditor({ boardId, boardName, onReady }) {
  const [initial, setInitial] = useState(null);
  const [state, setState] = useState('loading');
  const [message, setMessage] = useState('');
  const [loadError, setLoadError] = useState(false);
  const [exporting, setExporting] = useState(false);
  const sync = useRef(null);
  const needsPreview = useRef(false);
  const applyingRemote = useRef(false);
  const api = useRef(null);
  useEffect(() => {
    let active = true;
    const boardUrl = '/api/whiteboards/' + encodeURIComponent(boardId);
    fetch(boardUrl, { cache: 'no-store', signal: AbortSignal.timeout(15000) }).then(async response => {
      if (!response.ok) throw new Error('读取失败，请确认手机服务仍在运行');
      const data = await response.json();
      if (!active) return;
      needsPreview.current = !data.previewDataURL && !shared;
      sync.current = new BoardSync({
        revision: data.revision,
        initial: null,
        send: async payload => {
          const preview = await exportToBlob({ elements: payload.elements, files: payload.files,
            appState: { ...payload.appState, exportBackground: true }, mimeType: 'image/png', maxWidthOrHeight: 1600 });
          payload.previewDataURL = await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = () => reject(new Error('生成白板卡片失败'));
            reader.readAsDataURL(preview);
          });
          return fetch(boardUrl, {
            method: 'PUT', signal: AbortSignal.timeout(20000), headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
          });
        },
        status: (value, detail = '') => { setState(value); setMessage(detail); },
      });
      setInitial({ elements: data.elements, appState: data.appState, files: data.files, scrollToContent: true });
      setState('saved');
      onReady(true);
    }).catch(error => {
      if (active) { setLoadError(true); setMessage(error.message); }
    });
    const save = () => { if (document.visibilityState === 'hidden') sync.current?.flush(); };
    const beforeUnload = event => {
      if (sync.current?.dirty) {
        sync.current.flush();
        event.preventDefault();
        event.returnValue = '';
      }
    };
    let refreshing = false;
    const refresh = async () => {
      const current = sync.current;
      if (!active || refreshing || !current || !api.current || current.running || current.dirty || current.conflict) return;
      refreshing = true;
      try {
        const response = await fetch(boardUrl + '?revision=' + current.revision, {
          cache: 'no-store', signal: AbortSignal.timeout(10000),
        });
        if (response.status === 204) return;
        if (!response.ok) throw new Error('读取白板更新失败');
        const board = await response.json();
        if (!active || !current.acceptRemote(serializeAsJSON(board.elements, board.appState, board.files, 'local'), board.revision)) return;
        applyingRemote.current = true;
        api.current.addFiles(Object.values(board.files || {}));
        api.current.updateScene({ elements: board.elements, appState: board.appState });
        requestAnimationFrame(() => {
          if (api.current) {
            const scene = serializeAsJSON(api.current.getSceneElementsIncludingDeleted(), api.current.getAppState(), api.current.getFiles(), 'local');
            current.saved = current.latest = scene;
          }
          applyingRemote.current = false;
        });
        setMessage('已同步另一端的白板修改');
      } catch (_) {
        if (active && !current.dirty) setMessage('暂时无法同步另一端，将自动重试');
      } finally { refreshing = false; }
    };
    const poll = setInterval(refresh, 1000);
    window.localShareRefresh = refresh;
    const retry = () => { sync.current?.flush(); refresh(); };
    document.addEventListener('visibilitychange', save);
    window.addEventListener('online', retry);
    window.addEventListener('beforeunload', beforeUnload);
    return () => {
      active = false;
      clearInterval(poll);
      delete window.localShareRefresh;
      document.removeEventListener('visibilitychange', save);
      window.removeEventListener('online', retry);
      window.removeEventListener('beforeunload', beforeUnload);
      clearTimeout(sync.current?.timer);
      if (window.localShareBoardId === boardId) {
        delete window.localShareSave;
        delete window.localShareBoardId;
      }
    };
  }, []);
  const change = (elements, appState, files) => {
    if (!sync.current || applyingRemote.current) return;
    const scene = serializeAsJSON(elements, appState, files, 'local');
    if (sync.current.saved === null) {
      sync.current.saved = scene;
      sync.current.latest = scene;
      if (needsPreview.current) {
        needsPreview.current = false;
        sync.current.saved = '';
        sync.current.change(scene);
      }
    } else {
      sync.current.change(scene);
    }
  };
  window.localShareBoardId = boardId;
  window.localShareSave = async () => {
    const saved = sync.current ? await sync.current.saveAll() : false;
    return { saved, conflict: sync.current?.conflict || false };
  };
  const exportScene = () => {
    if (!api.current) return;
    download(new Blob([serializeAsJSON(api.current.getSceneElements(), api.current.getAppState(), api.current.getFiles(), 'local')], { type: 'application/json' }), boardName + '.excalidraw');
    setMessage(embedded ? '正在保存源文件，请查看下载提示' : '已开始下载源文件，请查看浏览器下载记录');
  };
  const exportImage = async () => {
    if (!api.current || exporting) return;
    setExporting(true);
    setMessage('');
    try {
      const blob = await exportToBlob({
        elements: api.current.getSceneElements(), files: api.current.getFiles(),
        appState: { ...api.current.getAppState(), exportBackground: true },
        mimeType: 'image/png', maxWidthOrHeight: 4096,
      });
      download(blob, boardName + '.png');
      setMessage(embedded ? '正在保存 PNG，请查看下载提示' : '已开始下载 PNG，请查看浏览器下载记录');
    } catch (_) { setMessage('导出失败，请确认画布上有内容后重试'); }
    finally { setExporting(false); }
  };
  return <div className={embedded ? "app embedded" : "app"}>
    <header className="topbar">
      {!embedded && !shared && <a className="back" href="/">← 本地分享</a>}
      <strong className="board-title">{boardName}</strong>
      <span className={'status ' + state} role="status" title={message}>{loadError ? '读取失败' : labels[state]}</span>
      <div className="actions">
        {(loadError || state === 'conflict') && <button onClick={() => location.reload()}>重新载入</button>}
        {(state === 'error' || state === 'warning') && <button onClick={() => { if (state === "warning") sync.current.saved = null; sync.current?.flush(); }}>重试保存</button>}
        <button disabled={!initial} onClick={exportScene}>导出源文件</button>
        <button disabled={!initial || exporting} onClick={exportImage}>{exporting ? '正在导出…' : '导出 PNG'}</button>
      </div>
    </header>
    {message && <div className="notice" role="alert">{message}</div>}
    <main className="canvas">
      {initial ? <Excalidraw
        initialData={initial} onChange={change} excalidrawAPI={value => { api.current = value; }}
        langCode="zh-CN" name={boardName} autoFocus
        UIOptions={{ canvasActions: { saveToActiveFile: false, export: false, saveAsImage: false } }}
      >
        <MainMenu>
          <MainMenu.DefaultItems.LoadScene />
          <MainMenu.DefaultItems.ClearCanvas />
          <MainMenu.DefaultItems.ToggleTheme />
          <MainMenu.DefaultItems.ChangeCanvasBackground />
        </MainMenu>
      </Excalidraw> : <div className="empty">{loadError ? message : '正在打开白板…'}</div>}
    </main>
  </div>;
}
async function requestJson(url, method = 'GET', data) {
  const response = await fetch(url, { method, cache: 'no-store', signal: AbortSignal.timeout(15000),
    ...(data ? { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) } : {}),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '操作失败，请重试');
  return result;
}

function App() {
  const [catalog, setCatalog] = useState(null);
  const [shown, setShown] = useState(null);
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [form, setForm] = useState(null);
  const [name, setName] = useState('');
  const shownRef = useRef(null);
  const locked = useRef(false);
  const catalogRef = useRef(null);
  const updateCatalog = data => { catalogRef.current = data; setCatalog(data); };
  const saveCurrent = async () => {
    if (!shownRef.current) return;
    if (window.localShareBoardId !== shownRef.current || !window.localShareSave) throw new Error('白板正在加载，请稍候再切换');
    const result = await window.localShareSave();
    if (!result.saved) throw new Error('当前白板尚未保存，暂不切换。请先重试保存或导出备份。');
  };
  const display = id => {
    if (shownRef.current === id) return;
    setReady(false);
    shownRef.current = id;
    setShown(id);
  };
  useEffect(() => {
    let active = true;
    let fetching = false;
    const refresh = async () => {
      if (fetching || locked.current) return;
      fetching = true;
      try {
        const data = await requestJson('/api/whiteboards');
        if (!active || locked.current) return;
        updateCatalog(data);
        if (data.activeId !== shownRef.current) {
          locked.current = true;
          try {
            await saveCurrent();
            if (active) {
              display(data.activeId);
              setForm(null);
              setNotice(shownRef.current ? '已切换白板' : '');
            }
          } finally { locked.current = false; }
        }
      } catch (error) { if (active) setNotice(error.message); }
      finally { fetching = false; }
    };
    refresh();
    const timer = setInterval(refresh, 1000);
    return () => { active = false; clearInterval(timer); };
  }, []);
  const act = async (action, target) => {
    if (locked.current) return;
    locked.current = true;
    setBusy(true);
    setNotice('正在保存当前白板…');
    try {
      await saveCurrent();
      let data;
      const selectionRevision = catalogRef.current.selectionRevision;
      if (action === 'switch') {
        data = await requestJson('/api/whiteboards/' + encodeURIComponent(target) + '/activate', 'POST', { selectionRevision });
      } else if (action === 'new') {
        data = await requestJson('/api/whiteboards', 'POST', { name, selectionRevision });
      } else {
        data = await requestJson('/api/whiteboards/' + encodeURIComponent(shownRef.current), 'PATCH', { name });
      }
      updateCatalog(data);
      display(data.activeId);
      setForm(null);
      setNotice(data.warning || (action === 'new' ? '已新建白板' : action === 'rename' ? '已重命名白板' : '已切换白板'));
    } catch (error) { setNotice(error.message); }
    finally { locked.current = false; setBusy(false); }
  };
  const current = catalog?.boards.find(board => board.id === shown);
  return <div className="workspace">
    <section className="board-picker">
      {embedded ? <>
        <label htmlFor="boardSelect">白板</label>
        <select id="boardSelect" aria-label="选择白板" value={shown || ''} disabled={busy || !ready} onChange={event => act('switch', event.target.value)}>
          {(catalog?.boards || []).map(board => <option key={board.id} value={board.id}>{board.name}</option>)}
        </select>
        <button disabled={busy || !ready} onClick={() => { setForm('new'); setName('画布 ' + (catalog.boards.length + 1)); }}>新建</button>
        <button disabled={busy || !ready} onClick={() => { setForm('rename'); setName(current?.name || ''); }}>重命名</button>
      </> : <><strong>{current?.name || '白板'}</strong><span className="follow-hint">跟随 App 当前白板</span></>}
    </section>
    {form && <form className="board-form" onSubmit={event => { event.preventDefault(); act(form); }}>
      <label htmlFor="boardName">{form === 'new' ? '新建白板' : '重命名'}</label>
      <input id="boardName" aria-label="白板名称" value={name} maxLength={80} autoFocus disabled={busy} onChange={event => setName(event.target.value)} />
      <button type="submit" disabled={busy || !name.trim()}>确定</button>
      <button type="button" disabled={busy} onClick={() => setForm(null)}>取消</button>
    </form>}
    {notice && <div className="workspace-notice" role="status">{notice}</div>}
    {shown ? <BoardEditor key={shown} boardId={shown} boardName={current?.name || '画布'} onReady={setReady} /> : <div className="empty">正在读取白板列表…</div>}
  </div>;
}
createRoot(document.getElementById('root')).render(<App />);
