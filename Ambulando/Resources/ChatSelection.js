// One DOM Range covers the whole rendered message, including nested blocks and table cells.
(() => {
  const root = document.getElementById('message');
  const send = value => window.webkit?.messageHandlers.chatSelection.postMessage(value);
  let lastHeight = 0;
  const measure = () => {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height !== lastHeight) { lastHeight = height; send({type:'height', height}); }
  };
  new ResizeObserver(measure).observe(root);
  // The host changes only styles on size/theme changes, leaving the DOM Range intact.
  window.chatStyle = style => {
    const page = document.documentElement;
    page.style.fontSize = style.size + 'px';
    page.style.fontWeight = style.weight;
    page.style.color = style.foreground;
    page.style.setProperty('--link', style.link);
    page.style.setProperty('--body-line-height', style.lineHeight + 'px');
    page.classList.toggle('dark', style.dark);
  };
  window.chatImage = (id, data) => {
    for (const image of root.querySelectorAll('img[data-object]')) if (image.dataset.object === id) {
      image.src = data; image.nextElementSibling?.remove();
    }
  };
  window.chatContent = html => {
    const box = document.createElement('div'); box.innerHTML = html;
    // Preserve unchanged selections during append-only streaming and unrelated message revisions.
    const selection = getSelection(); let saved;
    if (selection?.rangeCount && !selection.isCollapsed) {
      const r = selection.getRangeAt(0);
      if (root.contains(r.startContainer) && root.contains(r.endContainer)) {
        const prefix = document.createRange(); prefix.selectNodeContents(root); prefix.setEnd(r.startContainer,r.startOffset);
        const start = prefix.toString().length;
        prefix.setEnd(r.endContainer,r.endOffset); const end = prefix.toString().length;
        if (root.textContent.slice(0,end) === box.textContent.slice(0,end)) saved = {start,end};
      }
    }
    const scrolls = [...root.querySelectorAll('.table-scroll,pre')].map(n=>n.scrollLeft);
    root.replaceChildren(...box.childNodes);
    [...root.querySelectorAll('.table-scroll,pre')].forEach((n,i)=>n.scrollLeft=scrolls[i]||0);
    if (saved) {
      const point = offset => {
        const walk = document.createTreeWalker(root,NodeFilter.SHOW_TEXT); let n;
        while ((n=walk.nextNode())) { if (offset<=n.length) return [n,offset]; offset-=n.length; }
        return [root,root.childNodes.length];
      };
      const r = document.createRange(); r.setStart(...point(saved.start)); r.setEnd(...point(saved.end));
      selection.removeAllRanges(); selection.addRange(r);
    }
  };
  // Copy the *selected fragment*, not the source message. Table cells are TSV and rows are lines.
  // Walk the cloned fragment so partial boundary cells and Unicode offsets remain exact.
  const plain = node => {
    if (node.nodeType === Node.TEXT_NODE) return node.data;
    if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return '';
    if (node.matches?.('[data-no-copy]')) return '';
    if (node.nodeName === 'BR') return '\n';
    if (node.nodeName === 'IMG') return node.getAttribute('alt') || '';
    const children = [...node.childNodes];
    if (node.nodeName === 'TR') return children.filter(n=>/^(TD|TH)$/.test(n.nodeName)).map(n=>plain(n).replace(/\n/g,' ')).join('\t') + '\n';
    let text = children.map(plain).join('');
    if (node.nodeName === 'LI') {
      const parent = node.parentElement;
      const index = parent ? [...parent.children].indexOf(node) : 0;
      const marker = parent?.nodeName === 'OL' ? ((Number(parent.getAttribute('start')) || 1) + index) + '. ' : '• ';
      text = marker + text;
    }
    if (/^(P|H[1-6]|BLOCKQUOTE|PRE|LI|TABLE)$/.test(node.nodeName)) text += '\n';
    return text;
  };
  window.chatClipboard = () => {
    const selection = getSelection();
    if (!selection?.rangeCount || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) return null;
    const fragment = range.cloneContents();
    fragment.querySelectorAll('[data-no-copy]').forEach(n=>n.remove());
    const box = document.createElement('div'); box.append(fragment);
    // A range wholly inside a table may have TR/TD as its fragment roots. Supply semantic ancestors.
    if (!box.querySelector('table') && box.querySelector('tr,td,th')) {
      const table = document.createElement('table');
      if (!box.querySelector('tr')) { const tr = table.insertRow(); tr.append(...box.childNodes); }
      else table.append(...box.childNodes);
      box.append(table);
    }
    return {text:plain(box).replace(/\n{3,}/g,'\n\n').replace(/\n+$/,''), html:box.innerHTML};
  };
  document.addEventListener('copy', event => {
    const data = window.chatClipboard();
    if (!data || !event.clipboardData) return;
    event.clipboardData.setData('text/plain', data.text);
    event.clipboardData.setData('text/html', data.html);
    event.preventDefault();
  });
  root.addEventListener('click', event => {
    const button = event.target.closest('button');
    if (button) {
      send({type:'code', text:button.closest('.code').querySelector('code').textContent});
      button.textContent='Copied'; button.setAttribute('aria-label','Copied code');
      setTimeout(()=>{button.textContent='Copy';button.setAttribute('aria-label','Copy code')},1500);
      return;
    }
    const link = event.target.closest('a');
    if (link) { event.preventDefault(); send({type:'link', href:link.getAttribute('href')}); }
  });
  measure();
})();
