// Native editor only. Fixed positioning keeps selection UI out of document layout.
export function commentPosition(rects, viewport, size = 44) {
  const { left, top, width, height } = viewport;
  if (![left, top, width, height].every(Number.isFinite) || width < size + 8 || height < size + 8) return null;
  const visible = rects.filter(r => [r.left, r.top, r.right, r.bottom, r.width, r.height].every(Number.isFinite) && r.width > 0 && r.height > 0 && r.bottom > top + 4 && r.top < top + height - 4 && r.right > left && r.left < left + width);
  if (!visible.length) return null;
  const line = visible[visible.length - 1];
  return { x: left + width - size - 4,
    y: Math.min(top + height - size - 4, Math.max(top + 4, line.top + (line.height - size) / 2)) };
}

export function commentOverlay({ getEditor, capture, activate }) {
  const button = document.createElement('button');
  button.type = 'button'; button.id = 'doc.commentSelection';
  button.className = 'document-comment-action'; button.hidden = true;
  button.setAttribute('aria-label', 'Comment on selected text');
  button.title = 'Comment on selected text (⌥⌘M)';
  button.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M5 3h14a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-8l-6 4v-4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"/><path d="M7 8h10M7 12h7"/></svg>';
  document.body.append(button);
  let anchor = null, dismissed = null, frame = null;
  function update() {
    frame = null;
    const editor = getEditor(), selection = window.getSelection();
    const next = editor && !editor.state.selection.empty ? capture() : null;
    const key = next && JSON.stringify(next);
    if (key !== dismissed) dismissed = null;
    anchor = null; button.hidden = true;
    if (!next || dismissed === key || !selection?.rangeCount || selection.isCollapsed ||
        !editor.view.dom.contains(selection.anchorNode) || !editor.view.dom.contains(selection.focusNode)) return;
    const viewport = window.visualViewport;
    const position = commentPosition([...selection.getRangeAt(0).getClientRects()], {
      left: viewport?.offsetLeft || 0, top: viewport?.offsetTop || 0,
      width: viewport?.width || window.innerWidth, height: viewport?.height || window.innerHeight,
    });
    if (!position) return;
    anchor = next;
    button.style.left = `${position.x}px`; button.style.top = `${position.y}px`; button.hidden = false;
  }
  const schedule = () => { if (frame === null) frame = requestAnimationFrame(update); };
  function begin() {
    // Recapture synchronously before the native composer can change focus.
    update();
    if (!anchor) return;
    const captured = anchor; dismissed = JSON.stringify(captured); button.hidden = true;
    activate(captured);
  }
  button.addEventListener('pointerdown', e => e.preventDefault());
  button.addEventListener('mousedown', e => e.preventDefault());
  button.addEventListener('click', begin);
  document.addEventListener('selectionchange', schedule);
  document.addEventListener('scroll', schedule, true);
  window.addEventListener('resize', schedule);
  window.visualViewport?.addEventListener('resize', schedule);
  window.visualViewport?.addEventListener('scroll', schedule);
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') { dismissed = anchor && JSON.stringify(anchor); button.hidden = true; }
    if (e.metaKey && e.altKey && (e.code === 'KeyM' || e.key.toLowerCase() === 'm') && !button.hidden) { e.preventDefault(); begin(); }
  });
  document.addEventListener('focusout', () => requestAnimationFrame(() => {
    if (!getEditor()?.view.dom.contains(document.activeElement) && document.activeElement !== button) button.hidden = true;
  }));
  new ResizeObserver(schedule).observe(document.documentElement);
  return { update: schedule };
}
