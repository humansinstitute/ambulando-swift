import { BoardComments } from './comments.js';
import { boardComments, followCommentAnchors } from '../board-comments.js';
import { createElement, useCallback, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { CaptureUpdateAction, Excalidraw, restoreElements } from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';
import { BOARD_APP_STATE_DEFAULTS, boardSceneFingerprint } from '../board-scene.js';

const CHANGE_DELAY_MS = 250;
const root = () => document.getElementById('board-root');

// Observable editor state for diagnostics and browser tests (no content).
function reportCounts(elements, files) {
  const node = root();
  if (!node) return;
  node.dataset.boardElementCount = String((elements || []).filter(element => !element.isDeleted).length);
  node.dataset.boardFileCount = String(Object.keys(files || {}).length);
}
function reportZoom(appState) {
  const node = root();
  if (node && Number.isFinite(appState?.zoom?.value)) node.dataset.boardZoom = String(appState.zoom.value);
}
const SAFE_LINK = /^https?:\/\//i;

function sceneElements(scene) {
  return restoreElements(scene?.elements || [], null, { refreshDimensions: false, repairBindings: false });
}

function BoardEditor({ port, theme }) {
  const apiRef = useRef(null);
  const state = useRef({ key: '', readOnly: true, fingerprint: '', sentFiles: new Set(), interacted: false, timer: 0, pending: null, comments: [] });
  const [readOnly, setReadOnly] = useState(true);
  const [discussion, setDiscussion] = useState([]);
  const discussionView = useRef(null);
  const [discussionKey, setDiscussionKey] = useState('');
  const [ready, setReady] = useState(false);
  // Page-owned Save state (label, disabled); hidden for read-only views.
  const [action, setAction] = useState(null);
  // On Excalidraw's phone layout the top-right slot shares the tool row, so Save
  // floats just below the tools instead, left of the side tool column.
  const [phoneAt, setPhoneAt] = useState(null);

  const applyScene = useCallback((scene, { reset }) => {
    const api = apiRef.current;
    if (!api || !scene) return;
    clearTimeout(state.current.timer); state.current.timer = 0; state.current.pending = null;
    state.current.comments = boardComments(scene); setDiscussion(state.current.comments);
    const files = Object.values(scene.files || {});
    if (files.length) api.addFiles(files);
    for (const file of files) state.current.sentFiles.add(file.id);
    api.updateScene({
      elements: sceneElements(scene),
      ...(reset ? { appState: { ...BOARD_APP_STATE_DEFAULTS, ...(scene.appState || {}), zoom: { value: 1 }, scrollX: 0, scrollY: 0 } } : {}),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    // A newly opened board starts at 100%, centred on its content. Fitting to
    // the viewport zooms sparse boards up to Excalidraw's 3000% maximum (an
    // empty board has zero-size bounds). Later loads of the same key keep the
    // viewer's own zoom.
    if (reset) {
      api.history.clear();
      // Empty content has no finite fit bounds. Keep the explicit 100% viewport.
      if (scene.elements?.some(element => !element.isDeleted)) api.scrollToContent?.(undefined, { fitToContent: true, minZoom: 1, maxZoom: 1, animate: false });
    }
    state.current.fingerprint = boardSceneFingerprint(scene);
    state.current.interacted = false;
    reportCounts(api.getSceneElementsIncludingDeleted(), api.getFiles());
  }, []);

  const flush = useCallback(() => {
    const current = state.current;
    current.timer = 0;
    const pending = current.pending; current.pending = null;
    if (!pending || current.readOnly || !current.interacted) return;
    const scene = { type: 'excalidraw', version: 2, elements: pending.elements, appState: pending.appState, files: {}, wingman: { comments: followCommentAnchors(current.comments, pending.elements) } };
    const fingerprint = boardSceneFingerprint({ ...scene, files: pending.files });
    if (fingerprint === current.fingerprint) return;
    current.fingerprint = fingerprint;
    for (const [id, file] of Object.entries(pending.files || {})) {
      if (current.sentFiles.has(id)) continue;
      current.sentFiles.add(id);
      scene.files[id] = { id: file.id, mimeType: file.mimeType, dataURL: file.dataURL, created: file.created, lastRetrieved: file.lastRetrieved };
    }
    port.postMessage({ type: 'change', scene });
  }, [port]);

  useEffect(() => {
    // Messages queue on the port until Excalidraw's API exists.
    if (!ready) return undefined;
    port.onmessage = event => {
      const message = event.data || {};
      if (message.type === 'load') {
        const reset = message.key !== state.current.key;
        if (reset) setDiscussionKey(message.key);
        state.current.key = message.key;
        state.current.readOnly = message.readOnly === true;
        setReadOnly(state.current.readOnly);
        applyScene(message.scene, { reset });
        root().dataset.boardKey = message.key;
        root().dataset.boardReadonly = String(state.current.readOnly);
      } else if (message.type === 'flush') {
        // Save requested: deliver the debounced change first (port order is preserved).
        clearTimeout(state.current.timer);
        flush();
        port.postMessage({ type: 'flushed', token: message.token });
      } else if (message.type === 'action-ui') {
        setAction(message.action && typeof message.action === 'object' ? message.action : null);
      } else if (message.type === 'patch') {
        applyScene(message.scene, { reset: false });
      } else if (message.type === 'comments') {
        state.current.comments = message.comments; setDiscussion(message.comments);
      } else if (message.type === 'clear') {
        state.current.readOnly = true; setReadOnly(true);
        state.current.comments = []; setDiscussion([]); setDiscussionKey(crypto.randomUUID());
        apiRef.current?.resetScene();
        reportCounts([], {});
      }
    };
    port.postMessage({ type: 'ready' });
    return () => { port.onmessage = null; };
  }, [port, applyScene, ready, flush]);

  useEffect(() => {
    // Only user input makes a draft. Excalidraw's own load-time normalisation
    // (font metrics, bindings) must not mark a freshly loaded board unsaved.
    const mark = () => { state.current.interacted = true; };
    const events = ['pointerdown', 'keydown', 'paste', 'drop', 'wheel'];
    // A finished stroke or keystroke is delivered at once (after Excalidraw's
    // render), so navigating away right after drawing cannot lose it.
    const settle = () => requestAnimationFrame(() => requestAnimationFrame(() => { if (state.current.pending) { clearTimeout(state.current.timer); flush(); } }));
    for (const name of events) addEventListener(name, mark, { capture: true });
    addEventListener('pointerup', settle, { capture: true });
    addEventListener('keyup', settle, { capture: true });
    return () => {
      for (const name of events) removeEventListener(name, mark, { capture: true });
      removeEventListener('pointerup', settle, { capture: true });
      removeEventListener('keyup', settle, { capture: true });
    };
  }, [flush]);


  const onChange = useCallback((elements, appState, files) => {
    const current = state.current;
    reportCounts(elements, files);
    reportZoom(appState);
    discussionView.current?.update(elements, appState);
    if (current.readOnly) return;
    current.pending = {
      elements: elements.map(element => ({ ...element })),
      appState: { viewBackgroundColor: appState.viewBackgroundColor, gridSize: appState.gridSize, gridStep: appState.gridStep, gridModeEnabled: appState.gridModeEnabled },
      files,
    };
    if (!current.timer) current.timer = setTimeout(flush, CHANGE_DELAY_MS);
  }, [flush]);

  useEffect(() => {
    if (!ready) return undefined;
    let frame = 0, tries = 0;
    const measure = () => {
      frame = 0;
      const mobile = document.querySelector('.excalidraw')?.classList.contains('excalidraw--mobile');
      const tools = document.querySelector('.App-toolbar--mobile')?.getBoundingClientRect();
      if (mobile && !tools && tries++ < 120) { frame = requestAnimationFrame(measure); return; }
      const side = document.querySelector('.mobile-misc-tools-container')?.getBoundingClientRect();
      const next = mobile ? { top: Math.round((tools?.bottom || 0) + 8), right: Math.round(side?.width ? innerWidth - side.left + 8 : 12) } : null;
      setPhoneAt(current => (current?.top === next?.top && current?.right === next?.right ? current : next));
    };
    const schedule = () => { tries = 0; if (!frame) frame = requestAnimationFrame(measure); };
    schedule();
    addEventListener('resize', schedule);
    // Excalidraw changes its compact layout after its own resize observer runs.
    // Measure that transition too, so fullscreen never retains a second Save.
    const layout = document.querySelector('.excalidraw');
    const observer = new MutationObserver(schedule);
    if (layout) observer.observe(layout, { attributes: true, attributeFilter: ['class'] });
    return () => { observer.disconnect(); cancelAnimationFrame(frame); removeEventListener('resize', schedule); };
  }, [ready]);

  // Save floats over the drawing area: in Excalidraw's own top-right slot on
  // desktop, below the tools on phones, never over a tool. The page re-checks it.
  const saveButton = useCallback(() => (action?.action ? createElement('button', {
    type: 'button',
    className: `wingman-board-action${action.action === 'save' && !action.disabled ? ' primary' : ''}`,
    'data-board-action': action.action,
    title: action.title || action.label,
    disabled: action.disabled,
    onClick: () => port.postMessage({ type: 'action', action: action.action }),
  }, action.label) : null), [action, port]);
  const renderTopRightUI = useCallback(isMobile => (isMobile ? null : saveButton()), [saveButton]);

  return createElement('div', { style: { position: 'relative', width: '100%', height: '100%' }, 'data-board-ready': ready ? 'true' : 'false', 'data-board-readonly': readOnly ? 'true' : 'false' },
    phoneAt && action?.action ? createElement('div', { className: 'wingman-board-action-phone', style: { top: `${phoneAt.top}px`, right: `${phoneAt.right}px` } }, saveButton()) : null,
    createElement(BoardComments, { key: `${discussionKey}:${readOnly}`, api: apiRef.current, ref: discussionView, comments: discussion, readOnly, send: operation => { clearTimeout(state.current.timer); flush(); port.postMessage({ type: 'comment-op', operation }); } }),
    createElement(Excalidraw, {
      excalidrawAPI: api => { apiRef.current = api; setReady(Boolean(api)); },
      onChange,
      theme,
      viewModeEnabled: readOnly,
      // Board content is data: never load third-party embeds or navigate this frame.
      validateEmbeddable: () => false,
      onLinkOpen: (element, event) => {
        event.preventDefault();
        const link = String(element?.link || '');
        if (SAFE_LINK.test(link)) window.open(link, '_blank', 'noopener,noreferrer');
      },
      renderTopRightUI,
      UIOptions: { canvasActions: { loadScene: false, saveToActiveFile: false, clearCanvas: true, export: { saveFileToDisk: true }, toggleTheme: false } },
    }));
}

export function mountBoardEditor(root, port, { theme = 'light' } = {}) {
  root.dataset.boardEditorState = 'ready';
  createRoot(root).render(createElement(BoardEditor, { port, theme }));
}
