// Native host for sol's Excalidraw board editor (`sol/src/canvas/board-editor/editor.js`, reused unchanged).
// The editor owns no network or storage and speaks to its host over a MessagePort. Here the host is the native
// app: this shim gives the editor a port whose messages go to `webkit.messageHandlers.board` (as JSON) and whose
// incoming messages come from `window.ambulandoBoard.deliver(json)`, called by the app. No signer, key or
// `window.nostr` exists in this page, and the app refuses every navigation away from it.
import { mountBoardEditor } from './sol/board-editor/editor.js';

window.EXCALIDRAW_ASSET_PATH = new URL('./excalidraw-assets/', location.href).href;

// `crypto.randomUUID` needs a secure context; give the editor the same RFC 4122 v4 ids from getRandomValues.
if (typeof crypto.randomUUID !== 'function') {
  crypto.randomUUID = () => {
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  };
}

const root = document.getElementById('board-root');
const native = window.webkit?.messageHandlers?.board;

// A MessagePort queues messages until `onmessage` is set; so does this one.
const queued = [];
let receiver = null;
const port = {
  postMessage(message) { native?.postMessage(JSON.stringify(message)); },
  get onmessage() { return receiver; },
  set onmessage(fn) {
    receiver = fn;
    while (receiver && queued.length) receiver({ data: queued.shift() });
  },
};

Object.defineProperty(window, 'ambulandoBoard', {
  value: Object.freeze({
    deliver(json) {
      const data = JSON.parse(json);
      if (receiver) receiver({ data }); else queued.push(data);
      return true;
    },
  }),
});

const theme = new URLSearchParams(location.search).get('theme') === 'dark' ? 'dark' : 'light';
try {
  mountBoardEditor(root, port, { theme });
} catch (error) {
  root.dataset.boardEditorState = 'error';
  root.textContent = 'The board editor could not be loaded.';
  port.postMessage({ type: 'error', message: String(error?.message || error) });
}
