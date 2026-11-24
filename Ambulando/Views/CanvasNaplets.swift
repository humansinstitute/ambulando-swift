import AmbulandoCore
import SwiftUI
import WebKit

// Interactive canvas naplets, as the web canvas shows them (sol `canvas/page.js`, `chat-embed.js`, `document.js`,
// `html-naplet.js`, `task-tree-page.js`): a window with the item's title and a full-screen button over the live
// content. Conversations show the thread with a reply composer (the normal outbox and drafts), documents render with
// their comment count and an Edit entry (the normal editor, lease and draft), HTML artefacts run in a sandbox, and task
// trees show the real task graph with child and successor creation. Everything reads from and writes through the same
// stores and routes as the rest of the app; nothing here carries its own navigation bar items, so the canvas keeps its
// own title and toolbar. A naplet takes touches once selected; until then taps select it and the canvas pans.

/// The shared window chrome of an interactive naplet.
struct NapletWindow<Body: View, Accessory: View>: View {
    let naplet: CanvasNaplet
    let selected: Bool
    /// Taps reach the content (selected, not moving items).
    let interactive: Bool
    let onSelect: () -> Void
    let onExpand: (() -> Void)?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: NapletCard.icon(naplet.content)).foregroundStyle(Amb.primary)
                Text(naplet.title).font(.amb(.subheadline).weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                accessory()
                if let onExpand {
                    Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open \(naplet.title)").accessibilityIdentifier("naplet.expand")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: BoardNapletWindow.headerHeight)
            .background(Amb.muted.opacity(0.6))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onExpand?() }
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("naplet.\(naplet.title)")
            Divider()
            ZStack {
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if !interactive {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { onExpand?() }
                        .onTapGesture(perform: onSelect)
                }
            }
            .clipped()
        }
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .clipShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(selected ? Amb.primary : Amb.border, lineWidth: selected ? 3 : 1))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

// MARK: Conversation

struct ChatNapletSnapshot: Sendable, Equatable {
    var thread: ThreadRecord?
    var messages: [MessageRecord] = []
    var pending: [OutboxItem] = []
    var people = PeopleDirectory()
    var extras = MessageExtras()
}

/// A conversation on the canvas: its latest messages and a reply composer (drafts, mentions and the durable outbox are
/// the normal chat ones).
struct ChatNapletBody: View {
    @Environment(AppModel.self) private var model
    let threadId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    let interactive: Bool
    @State private var snapshot = LiveQuery<ChatNapletSnapshot>(initial: ChatNapletSnapshot())
    @State private var messageEdit: ChatMessageEdit?

    var body: some View {
        let value = snapshot.value
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(value.messages.suffix(60)) { message in
                        MessageCell(message: message, people: value.people, workspace: workspace, extras: value.extras)
                    }
                    ForEach(value.pending) { OutboxRow(item: $0, people: value.people) }
                    if snapshot.loaded && value.messages.isEmpty {
                        SyncNote(text: model.canRead ? "Loading conversation…" : "Unlock to load this conversation.")
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            if let thread = value.thread, let connection = model.connection {
                Divider()
                if interactive {
                    Composer(target: ChatTarget(connectionId: connection.id, workspaceId: workspace.id, channelId: thread.channelId, threadId: thread.id),
                             workspace: workspace, store: store, placeholder: "Reply to thread…", editing: $messageEdit)
                } else {
                    Text("Select to reply").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("naplet.chat")
        .environment(\.editChatMessage, { message, body in
            if messageEdit == nil { messageEdit = ChatMessageEdit(message: message, body: body) }
            else { model.notice = "Save or cancel the current edit first." }
        })
        .task {
            let w = workspace.id, id = threadId, store = store, connection = model.connection?.id ?? ""
            snapshot.start(store: store, matches: { key in
                key.workspaceId == w && [.messages, .outbox, .members, .agents, .threads, .reactions, .writes].contains(key.table)
                    || (key.table == .outbox && key.workspaceId == nil) || key.table == .profiles
            }) {
                guard let thread = try await store.reader.thread(workspaceId: w, id: id) else { return ChatNapletSnapshot() }
                let target = ChatTarget(connectionId: connection, workspaceId: w, channelId: thread.channelId, threadId: id)
                async let messages = store.reader.threadMessages(workspaceId: w, threadId: id, limit: 120)
                async let pending = store.reader.outbox(target: target)
                async let people = store.reader.people(connectionId: connection, workspaceId: w)
                let rows = try await messages
                MessageDisplayCache.shared.prepare(rows)
                let ids = rows.map(\.id)
                async let reactions = store.reader.reactions(workspaceId: w, targetIds: ids)
                async let writes = store.reader.writes(connectionId: connection, workspaceId: w)
                let wanted = Set(ids)
                let relevant = try await writes.filter { [.messageEdit, .messageDelete, .reactionAdd, .reactionRemove].contains($0.kind) && wanted.contains($0.targetId ?? "") }
                return ChatNapletSnapshot(thread: thread, messages: rows, pending: try await pending, people: try await people,
                                          extras: MessageExtras(reactions: Dictionary(grouping: try await reactions, by: \.targetId),
                                                                writes: Dictionary(grouping: relevant) { $0.targetId ?? "" }))
            }
            if (try? await store.reader.thread(workspaceId: w, id: id)) == nil { model.ensureThread(id, in: workspace) }
        }
        .onChange(of: snapshot.value.thread?.channelId) { _, channel in
            if let channel { model.openThread(threadId, channelId: channel, in: workspace) }
        }
    }
}

// MARK: Document

struct DocNapletSnapshot: Sendable, Equatable {
    var doc: DocRecord?
    var blocks: [RenderBlock] = []
    var hasBody = false
    var editable = false
    var hasDraft = false
    var comments = 0
}

/// A document on the canvas, rendered natively on white, with entries into its document screen (comments, or Edit).
struct DocNapletBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pushRoute) private var pushRoute
    let docId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    let interactive: Bool
    @State private var snapshot = LiveQuery<DocNapletSnapshot>(initial: DocNapletSnapshot())

    var body: some View {
        let value = snapshot.value
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { pushRoute(.doc(workspaceId: workspace.id, docId: docId)) } label: {
                    Label("Comments (\(value.comments))", systemImage: "text.bubble")
                }
                .accessibilityIdentifier("naplet.doc.comments")
                Spacer()
                // The document screen opens with Edit on: the same page editor as every other way into a document.
                Button(value.hasDraft ? "Continue editing" : "Edit") {
                    model.docEditRequest = docId
                    pushRoute(.doc(workspaceId: workspace.id, docId: docId))
                }
                    .disabled(!value.editable && !value.hasDraft)
                    .accessibilityIdentifier("naplet.doc.edit")
            }
            .buttonStyle(.bordered).controlSize(.small).font(.amb(.caption))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .disabled(!interactive)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let doc = value.doc { Text(doc.title).font(.amb(.headline)).foregroundStyle(Amb.foreground) }
                    if value.hasBody {
                        RichBlocksView(blocks: value.blocks, style: .document, workspace: workspace)
                    } else if snapshot.loaded {
                        SyncNote(text: model.canRead ? "Loading document…" : "Unlock to load this document.")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("naplet.document")
        .task {
            let w = workspace.id, id = docId, store = store, connection = model.connection?.id ?? ""
            snapshot.start(store: store, matches: { $0.workspaceId == w && [.docs, .docBodies, .docDrafts, .comments].contains($0.table) }) {
                async let doc = store.reader.doc(workspaceId: w, id: id)
                async let cached = store.reader.docBody(workspaceId: w, docId: id)
                async let draft = store.reader.docDraft(key: DocDraft.key(connectionId: connection, workspaceId: w, docId: id))
                async let comments = store.reader.comments(workspaceId: w, parent: .doc, parentId: id)
                var out = DocNapletSnapshot(doc: try await doc, hasDraft: try await draft != nil, comments: try await comments.count)
                if let body = try await cached {
                    let decoded = DocumentBody(bytes: body.bytes, contentType: body.contentType)
                    out.hasBody = true
                    out.blocks = DocumentRender.blocks(decoded)
                    out.editable = decoded.isEditable
                }
                return out
            }
            model.openDoc(docId, in: workspace)
        }
    }
}

// MARK: HTML

/// sol `CANVAS_HTML_CSP` and its link/form guard: an artefact can run its own script but cannot fetch, frame, submit
/// or navigate, and gets no bridge, signer or `window.nostr`.
enum CanvasHTMLDocument {
    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; media-src data: blob:; frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
    static let guardScript = "<script>(()=>{const stop=e=>{const l=e.target&&e.target.closest&&e.target.closest('a[href],form');if(l){e.preventDefault();e.stopImmediatePropagation();const h=e.type==='click'&&l.getAttribute('href');if(h&&h[0]==='#'&&h.length>1){let t=null;try{t=document.getElementById(decodeURIComponent(h.slice(1)))}catch{}if(t)t.scrollIntoView({block:'start'})}}};addEventListener('click',stop,true);addEventListener('submit',stop,true);window.open=()=>null;})();</script>"

    static func build(_ html: String) -> String {
        let head = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><meta name=\"referrer\" content=\"no-referrer\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>html,body{margin:0;min-height:100%;font:14px system-ui;color:#172235;background:#fff}*{box-sizing:border-box}</style>"
            + guardScript
        return ArtefactHTMLDocument.insertingHeadContent(head, into: html)
    }
}

struct HTMLAnchorTargetSpec: Equatable {
    let threadId: String
    let anchor: HTMLCommentAnchor
    let resolved: Bool
    let replyCount: Int
}

@MainActor
struct SandboxedHTMLView {
    let html: String
    var interactive = true
    var anchorSpecs: [HTMLAnchorTargetSpec] = []
    var focusThreadNonce: (String, Int)? = nil
    var onTargetSelected: ((HTMLCommentAnchor) -> Void)? = nil
    var onAnchorMatches: (([String: Bool]) -> Void)? = nil
    var onBadgeTapped: ((String) -> Void)? = nil

    private var reviewEnabled: Bool {
        onTargetSelected != nil || onAnchorMatches != nil || onBadgeTapped != nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var loaded = false
        var pageReady = false
        var lastSyncedJSON: String = ""
        var lastFocusNonce: Int = 0
        var onTargetSelected: ((HTMLCommentAnchor) -> Void)?
        var onAnchorMatches: (([String: Bool]) -> Void)?
        var onBadgeTapped: ((String) -> Void)?
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The generated document loads once; nothing navigates afterwards.
            if !loaded, action.request.url?.absoluteString == "about:blank" { loaded = true; return .allow }
            return action.targetFrame?.isMainFrame == false && action.request.url?.scheme == "about" ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            if !lastSyncedJSON.isEmpty {
                webView.evaluateJavaScript("window.__ambSyncAnchors&&window.__ambSyncAnchors(\(lastSyncedJSON));")
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ambReview",
                  let body = message.body as? [String: Any],
                  let kind = body["type"] as? String else { return }
            switch kind {
            case "target":
                guard let raw = body["anchor"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: raw),
                      data.count <= 4096,
                      let anchor = HTMLCommentAnchor.parse(raw) else { return }
                onTargetSelected?(anchor)
            case "matches":
                guard let raw = body["matches"] as? [String: Bool], raw.count <= 500 else { return }
                var filtered: [String: Bool] = [:]
                for (k, v) in raw {
                    if let id = UUID(uuidString: k)?.uuidString.lowercased() { filtered[id] = v }
                }
                onAnchorMatches?(filtered)
            case "badge":
                guard let id = (body["threadId"] as? String).flatMap({ UUID(uuidString: $0)?.uuidString.lowercased() }) else { return }
                onBadgeTapped?(id)
            default:
                break
            }
        }

        func sync(specs: [HTMLAnchorTargetSpec], focus: (String, Int)?) {
            let encoded: [[String: Any]] = specs.map { spec in
                [
                    "threadId": spec.threadId,
                    "resolved": spec.resolved,
                    "replyCount": spec.replyCount,
                    "anchor": spec.anchor.toJSONObject(),
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: encoded),
               let json = String(data: data, encoding: .utf8),
               json != lastSyncedJSON {
                lastSyncedJSON = json
                if pageReady {
                    webView?.evaluateJavaScript("window.__ambSyncAnchors&&window.__ambSyncAnchors(\(json));")
                }
            }
            if let focus, focus.1 != lastFocusNonce, pageReady {
                lastFocusNonce = focus.1
                if let data = try? JSONSerialization.data(withJSONObject: [focus.0]),
                   let arr = String(data: data, encoding: .utf8) {
                    webView?.evaluateJavaScript("window.__ambFocusThread&&window.__ambFocusThread((\(arr))[0]);")
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static let reviewOverlayHead = """
    <style>
    .amb-review-highlight{outline:2px solid #2563eb !important;outline-offset:2px !important;border-radius:3px !important;}
    .amb-review-highlight-resolved{outline:2px dashed #64748b !important;outline-offset:2px !important;border-radius:3px !important;}
    .amb-review-focus{outline:3px solid #f59e0b !important;outline-offset:3px !important;}
    .amb-review-badge{position:absolute;z-index:2147483640;background:#2563eb;color:#fff;font:600 11px/1 system-ui,sans-serif;padding:3px 7px;border-radius:999px;border:1.5px solid #fff;box-shadow:0 2px 6px rgba(0,0,0,.22);cursor:pointer;user-select:none;}
    .amb-review-badge-resolved{background:#64748b;}
    .amb-ctx-menu{position:fixed;z-index:2147483645;background:#1e293b;color:#fff;border-radius:8px;padding:4px;box-shadow:0 8px 24px rgba(0,0,0,.28);font:500 12px/1.2 system-ui,sans-serif;}
    .amb-ctx-menu button{background:none;border:none;color:#fff;padding:6px 10px;border-radius:5px;cursor:pointer;display:block;width:100%;text-align:left;}
    .amb-ctx-menu button:hover{background:rgba(255,255,255,.14);}
    </style>
    """

    private static let reviewOverlayScript = """
    <script>(()=>{
    const post=m=>{try{window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ambReview&&window.webkit.messageHandlers.ambReview.postMessage(m);}catch{}};
    let currentSpecs=[];let badgeLayer=null;let ctxMenu=null;
    const norm=s=>String(s||'').replace(/\\s+/g,' ').trim();
    const closeMenu=()=>{if(ctxMenu){ctxMenu.remove();ctxMenu=null;}};
    const ensureLayer=()=>{
      if(badgeLayer&&badgeLayer.isConnected)return badgeLayer;
      badgeLayer=document.createElement('div');
      badgeLayer.setAttribute('data-amb-review-ui','1');
      badgeLayer.style.cssText='position:absolute;top:0;left:0;width:0;height:0;pointer-events:none;z-index:2147483640;';
      document.body&&document.body.appendChild(badgeLayer);
      return badgeLayer;
    };
    const domPathFor=el=>{
      const path=[];let cur=el;
      while(cur&&cur!==document.body&&cur!==document.documentElement){
        const p=cur.parentElement;if(!p)break;
        const idx=Array.prototype.indexOf.call(p.children,cur);
        if(idx<0)break;
        path.unshift(idx);cur=p;
      }
      return path;
    };
    const selectorFor=el=>{
      if(el.id&&/^[A-Za-z_][A-Za-z0-9_-]*$/.test(el.id))return '#'+el.id;
      const parts=[];let cur=el;
      while(cur&&cur!==document.body&&cur!==document.documentElement&&parts.length<8){
        if(cur.id&&/^[A-Za-z_][A-Za-z0-9_-]*$/.test(cur.id)){parts.unshift('#'+cur.id);break;}
        const tag=cur.tagName.toLowerCase();
        const p=cur.parentElement;if(!p){parts.unshift(tag);break;}
        const sibs=Array.prototype.filter.call(p.children,c=>c.tagName===cur.tagName);
        const idx=sibs.indexOf(cur)+1;
        parts.unshift(sibs.length>1?(tag+':nth-of-type('+idx+')'):tag);
        cur=p;
      }
      return parts.join(' > ');
    };
    const attrFingerprintFor=el=>{
      const keys=['data-asset','data-asset-background','alt','aria-label','title','name','type','role','href'];
      const parts=[];
      for(const k of keys){const v=norm(el.getAttribute&&el.getAttribute(k));if(v)parts.push(k+'='+v.slice(0,60));}
      return parts.join('|').slice(0,256);
    };
    const strictMatches=(el,a)=>{
      if(!el||el.closest('[data-amb-review-ui]'))return false;
      const tag=a.tag_name?String(a.tag_name).toLowerCase():null;
      if(tag&&el.tagName.toLowerCase()!==tag)return false;
      const quote=a.text_quote?norm(a.text_quote):'';
      const curText=norm(el.innerText||el.textContent||'');
      const expectedFp=a.attr_fingerprint?norm(a.attr_fingerprint):'';
      const curFp=attrFingerprintFor(el);
      if(quote&&curText!==quote&&!(quote.length>=155&&curText.startsWith(quote)))return false;
      if(expectedFp&&curFp!==expectedFp)return false;
      if(!quote&&!expectedFp&&!a.element_id)return false;
      return true;
    };
    const resolveAnchor=a=>{
      if(!a||a.kind==='document')return null;
      if(a.element_id){const byId=document.getElementById(a.element_id);if(strictMatches(byId,a))return byId;}
      if(a.selector){try{const nodes=document.querySelectorAll(a.selector);if(nodes.length===1&&strictMatches(nodes[0],a))return nodes[0];}catch{}}
      if(Array.isArray(a.dom_path)&&a.dom_path.length>0&&document.body){
        let cur=document.body;
        for(const idx of a.dom_path){if(!cur||!cur.children||idx<0||idx>=cur.children.length){cur=null;break;}cur=cur.children[idx];}
        if(strictMatches(cur,a))return cur;
      }
      return null;
    };
    const render=()=>{
      document.querySelectorAll('.amb-review-highlight,.amb-review-highlight-resolved,.amb-review-focus').forEach(el=>{
        el.classList.remove('amb-review-highlight','amb-review-highlight-resolved','amb-review-focus');
      });
      const layer=ensureLayer();if(layer)layer.innerHTML='';
      const matches={};
      for(const spec of currentSpecs){
        const el=resolveAnchor(spec.anchor);
        matches[spec.threadId]=Boolean(el);
        if(!el)continue;
        el.classList.add(spec.resolved?'amb-review-highlight-resolved':'amb-review-highlight');
        const rect=el.getBoundingClientRect();
        if(layer&&(rect.width>0||rect.height>0)){
          const btn=document.createElement('button');btn.type='button';
          btn.className='amb-review-badge'+(spec.resolved?' amb-review-badge-resolved':'');
          btn.style.pointerEvents='auto';
          btn.style.left=Math.max(4,rect.left+window.scrollX)+'px';
          btn.style.top=Math.max(4,rect.top+window.scrollY-12)+'px';
          btn.textContent=spec.replyCount>0?('💬 '+(spec.replyCount+1)):'💬';
          btn.addEventListener('click',ev=>{ev.preventDefault();ev.stopPropagation();post({type:'badge',threadId:spec.threadId});});
          layer.appendChild(btn);
        }
      }
      post({type:'matches',matches});
    };
    window.__ambSyncAnchors=specs=>{currentSpecs=Array.isArray(specs)?specs:[];render();};
    window.__ambFocusThread=id=>{
      const spec=currentSpecs.find(s=>s.threadId===id);if(!spec)return;
      const el=resolveAnchor(spec.anchor);if(!el)return;
      el.scrollIntoView({behavior:'smooth',block:'center'});
      el.classList.add('amb-review-focus');
      setTimeout(()=>el.classList.remove('amb-review-focus'),1800);
    };
    document.addEventListener('contextmenu',e=>{
      const target=e.target&&e.target.nodeType===1?e.target:e.target&&e.target.parentElement;
      if(!target||target.closest('[data-amb-review-ui]')||target===document.documentElement||target===document.body)return;
      e.preventDefault();closeMenu();
      ctxMenu=document.createElement('div');ctxMenu.className='amb-ctx-menu';ctxMenu.setAttribute('data-amb-review-ui','1');
      ctxMenu.style.left=Math.min(e.clientX,window.innerWidth-150)+'px';
      ctxMenu.style.top=Math.min(e.clientY,window.innerHeight-44)+'px';
      const btn=document.createElement('button');btn.type='button';btn.textContent='Add comment';
      btn.addEventListener('click',ev=>{
        ev.preventDefault();ev.stopPropagation();closeMenu();
        const txt=norm(target.innerText||target.textContent||'').slice(0,160);
        const fp=attrFingerprintFor(target);
        post({type:'target',anchor:{kind:'html_element',element_id:target.id||undefined,selector:selectorFor(target),dom_path:domPathFor(target),tag_name:target.tagName.toLowerCase(),text_quote:txt||undefined,attr_fingerprint:fp||undefined}});
      });
      ctxMenu.appendChild(btn);document.body.appendChild(ctxMenu);
    },true);
    document.addEventListener('click',closeMenu);
    window.addEventListener('resize',()=>{if(currentSpecs.length)render();});
    })();</script>
    """

    func make(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        coordinator.onTargetSelected = onTargetSelected
        coordinator.onAnchorMatches = onAnchorMatches
        coordinator.onBadgeTapped = onBadgeTapped
        if reviewEnabled {
            configuration.userContentController.add(coordinator, name: "ambReview")
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        coordinator.webView = view
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsLinkPreview = false
        let built = CanvasHTMLDocument.build(html)
        let finalHTML = reviewEnabled
            ? ArtefactHTMLDocument.insertingHeadContent(Self.reviewOverlayHead, into: built) + Self.reviewOverlayScript
            : built
        view.loadHTMLString(finalHTML, baseURL: nil)
        return view
    }
}

#if os(iOS)
extension SandboxedHTMLView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {
        view.isUserInteractionEnabled = interactive
        context.coordinator.onTargetSelected = onTargetSelected
        context.coordinator.onAnchorMatches = onAnchorMatches
        context.coordinator.onBadgeTapped = onBadgeTapped
        if reviewEnabled { context.coordinator.sync(specs: anchorSpecs, focus: focusThreadNonce) }
    }
}
#else
extension SandboxedHTMLView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onTargetSelected = onTargetSelected
        context.coordinator.onAnchorMatches = onAnchorMatches
        context.coordinator.onBadgeTapped = onBadgeTapped
        if reviewEnabled { context.coordinator.sync(specs: anchorSpecs, focus: focusThreadNonce) }
    }
}
#endif

/// An HTML artefact running inline in its sandbox (resolved for this viewer by Tower).
struct HTMLNapletBody: View {
    @Environment(AppModel.self) private var model
    let canvasId: String
    let napletId: String
    let workspace: WorkspaceRecord
    let live: Bool
    let interactive: Bool
    @State private var html: String?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Label("Sandboxed HTML · no network or signing", systemImage: "lock.shield")
                .font(.amb(.caption2)).foregroundStyle(Amb.warning)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Amb.warningBackground)
            if let html, live {
                SandboxedHTMLView(html: html, interactive: interactive).accessibilityIdentifier("naplet.html")
            } else if let failure {
                Text(failure).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).padding(10)
            } else if html != nil {
                Text("Zoom in or select to run this artefact.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).padding(10)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: napletId) {
            guard let sync = model.sync, let connection = model.connection, model.canRead else { failure = "Unlock to run this HTML artefact."; return }
            do { html = try await sync.napletHTML(connection, workspace, canvasId: canvasId, napletId: napletId).html }
            catch { failure = (error as? LocalizedError)?.errorDescription ?? "This HTML artefact is not available to you." }
        }
    }
}

// MARK: Task tree

/// A task tree on the canvas (sol Task Tree naplet): the real tasks from a root, children below and successors to the
/// right, with + to add a child or a successor, a node tap to open the task, and New/Existing task to choose the root.
/// The view (root, collapsed branches) is saved in the naplet's layout when this viewer manages the canvas, and kept on
/// this device otherwise.
struct TaskTreeNapletBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pushRoute) private var pushRoute
    let naplet: CanvasNaplet
    let canvasId: String
    let channelId: String
    let channelTitle: String?
    let scopeId: String?
    let canCreate: Bool
    let canManage: Bool
    let workspace: WorkspaceRecord
    let interactive: Bool

    enum Entry: Equatable { case root, child(TaskTreeNode), successor(TaskTreeNode) }

    @State private var view: TaskTreeView?
    @State private var graph = TaskTreeGraph()
    @State private var loading = false
    @State private var loadRevision = UUID()
    @State private var note: String?
    @State private var entry: Entry?
    @State private var title = ""
    @State private var requestId = UUID().uuidString.lowercased()
    @State private var busy = false
    @State private var choosing = false
    @State private var choices: [TaskRecord] = []
    @State private var pinchScale: Double?
    @State private var scrollReset = UUID()
    @State private var zoomSave: Task<Void, Never>?

    static let cell = (width: 300.0, height: 150.0, nodeWidth: 240.0, nodeHeight: 104.0)

    var body: some View {
        let current = view ?? TaskTreeView(savedLayout: naplet.savedLayout, napletId: naplet.id)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("#\(channelTitle ?? "channel")").font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
                if canCreate { Button("New task") { begin(.root) }.accessibilityIdentifier("tree.new") }
                Button("Existing task") { chooseExisting() }.accessibilityIdentifier("tree.existing")
                if current.rootTaskId != nil {
                    Button { reload(current) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh tree")
                }
            }
            .buttonStyle(.bordered).controlSize(.small).font(.amb(.caption))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .disabled(!interactive || busy)
            Text("Solid: subtasks · Dashed: dependencies").font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
            if let note { Text(note).font(.amb(.caption2)).foregroundStyle(Amb.warning).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            if current.rootTaskId == nil {
                VStack(spacing: 6) {
                    Text("Start a tree").font(.amb(.subheadline).weight(.semibold))
                    Text(canCreate ? "Create a base task, or choose an existing task, to lay out its children and next tasks." : "Choose an existing task to show its tree.")
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Button { setScale(current.scale / 1.25, current) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom tree out")
                            Text("\(Int(current.scale * 100))% ").font(.amb(.caption).monospacedDigit()).accessibilityLabel("Tree zoom \(Int(current.scale * 100)) percent")
                            Button { setScale(current.scale * 1.25, current) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom tree in")
                            Button("Reset") { scrollReset = UUID(); setScale(1, current) }.accessibilityLabel("Reset tree zoom")
                            Button("Fit tree") {
                                let size = graphSize
                                scrollReset = UUID()
                                setScale(TaskTreeView.fitScale(width: size.width, height: size.height, availableWidth: proxy.size.width, availableHeight: max(1, proxy.size.height - 48)), current)
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small).frame(minHeight: 44).disabled(!interactive)
                        ScrollView([.horizontal, .vertical]) { graphView(current) }.id(scrollReset)
                            .simultaneousGesture(MagnifyGesture().onChanged { value in
                                guard interactive else { return }
                                if pinchScale == nil { pinchScale = current.scale }
                                setScale((pinchScale ?? current.scale) * value.magnification, current)
                            }.onEnded { _ in pinchScale = nil })
                    }
                    .clipped()
                }
            }
            if let entry { entryBar(entry) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("naplet.tree")
        .task(id: naplet.savedLayout) {
            let saved = TaskTreeView(savedLayout: naplet.savedLayout, napletId: naplet.id)
            if view == nil || canManage { view = saved }
            reload(view ?? saved)
        }
        .sheet(isPresented: $choosing) { existingSheet }
        .onDisappear { zoomSave?.cancel(); zoomSave = nil }
        .task {
            guard let store = model.store else { return }
            let stream = await store.changes.stream()
            for await batch in stream {
                guard !Task.isCancelled else { return }
                guard batch.contains(where: { ($0.workspaceId == nil || $0.workspaceId == workspace.id) && [.tasks, .writes, .access].contains($0.table) }) else { continue }
                let current = view ?? TaskTreeView(savedLayout: naplet.savedLayout, napletId: naplet.id)
                guard let root = current.rootTaskId else { continue }
                let tasks = (try? await store.reader.tasks(workspaceId: workspace.id, includeArchived: true, limit: 2000)) ?? []
                let writes = (try? await store.reader.writes(connectionId: model.connection?.id ?? "", workspaceId: workspace.id)) ?? []
                let nodes = tasks.map { TaskTreeNode($0, stateOverride: TaskRow(task: $0, writes: writes).state) }
                let projected = await Task.detached { TaskTreeGraph.project(nodes, root: root, collapsed: current.collapsed, upstream: current.upstream) }.value
                guard (view ?? current).rootTaskId == root else { continue }
                graph = projected
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                reload(view ?? TaskTreeView(savedLayout: naplet.savedLayout, napletId: naplet.id))
            }
        }
    }

    // MARK: Graph

    private var graphSize: CGSize {
        CGSize(width: max(560, 40 + Double((graph.positions.values.map(\.x).max() ?? 0) + 1) * Self.cell.width),
               height: max(300, 40 + Double((graph.positions.values.map(\.y).max() ?? 0) + 1) * Self.cell.height))
    }

    private func setScale(_ scale: Double, _ current: TaskTreeView) {
        var next = view ?? current
        next.scale = TaskTreeView.boundedScale(scale)
        view = next
        zoomSave?.cancel()
        zoomSave = Task {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            zoomSave = nil
            await save(next)
        }
    }

    private func graphView(_ current: TaskTreeView) -> some View {
        let positions = graph.positions
        let columns = Double((positions.values.map(\.x).max() ?? 0) + 1), rows = Double((positions.values.map(\.y).max() ?? 0) + 1)
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in graph.edges {
                    guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                    var path = Path()
                    if edge.child {
                        let x = 20 + Double(a.x) * Self.cell.width + Self.cell.nodeWidth
                        let y = 20 + Double(a.y) * Self.cell.height + Self.cell.nodeHeight / 2
                        let endX = 20 + Double(b.x) * Self.cell.width
                        let endY = 20 + Double(b.y) * Self.cell.height + Self.cell.nodeHeight / 2
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x + 36, y: y))
                        path.addLine(to: CGPoint(x: x + 36, y: endY))
                        path.addLine(to: CGPoint(x: endX, y: endY))
                    } else {
                        let x = 20 + Double(a.x) * Self.cell.width + Self.cell.nodeWidth
                        let y = 20 + Double(a.y) * Self.cell.height + Self.cell.nodeHeight / 2
                        let endX = 20 + Double(b.x) * Self.cell.width
                        let endY = 20 + Double(b.y) * Self.cell.height + Self.cell.nodeHeight / 2
                        let laneY = 20 + Double(a.y) * Self.cell.height + Self.cell.nodeHeight + 28
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x + 44, y: y))
                        path.addLine(to: CGPoint(x: x + 44, y: laneY))
                        path.addLine(to: CGPoint(x: max(4, endX - 16), y: laneY))
                        path.addLine(to: CGPoint(x: max(4, endX - 16), y: endY))
                        path.addLine(to: CGPoint(x: endX, y: endY))
                    }
                    context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: edge.child ? [] : [5, 4]))
                }
            }
            ForEach(graph.nodes) { node in
                if let p = positions[node.id] { nodeView(node, current).offset(x: 20 + Double(p.x) * Self.cell.width, y: 20 + Double(p.y) * Self.cell.height) }
            }
        }
        .frame(width: max(560, 40 + columns * Self.cell.width), height: max(300, 40 + rows * Self.cell.height), alignment: .topLeading)
        .scaleEffect(current.scale, anchor: .topLeading)
        .frame(width: graphSize.width * current.scale, height: graphSize.height * current.scale, alignment: .topLeading)
    }

    private func nodeView(_ node: TaskTreeNode, _ current: TaskTreeView) -> some View {
        let hasChildren = graph.edges.contains { $0.from == node.id && $0.child } || current.collapsed.contains(node.id)
        return ZStack(alignment: .topLeading) {
            Button { pushRoute(.task(workspaceId: workspace.id, taskId: node.id)) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.title).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(2).multilineTextAlignment(.leading)
                    TaskStatusBadge(state: node.state)
                    if node.channelId != channelId { Text(node.channelTitle.map { "#\($0)" } ?? "Other channel").font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground) }
                }
                .padding(10)
                .frame(width: Self.cell.nodeWidth, height: Self.cell.nodeHeight, alignment: .topLeading)
                .background(Amb.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Amb.taskStatus(node.state), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tree.node.\(node.title)")
            if hasChildren {
                Button { toggle(node, current) } label: { Image(systemName: current.collapsed.contains(node.id) ? "chevron.right.circle" : "chevron.down.circle") }
                    .buttonStyle(.borderless)
                    .offset(x: Self.cell.nodeWidth - 26, y: 6)
                    .accessibilityLabel(current.collapsed.contains(node.id) ? "Expand" : "Collapse")
            }
            if canCreate {
                Button { begin(.child(node)) } label: { Image(systemName: "plus.circle.fill").font(.amb(.title3)) }
                    .buttonStyle(.borderless)
                    .offset(x: Self.cell.nodeWidth / 2 - 12, y: Self.cell.nodeHeight + 6)
                    .accessibilityLabel("Add a sub task to \(node.title)").accessibilityIdentifier("tree.child.\(node.title)")
                Button { begin(.successor(node)) } label: { Image(systemName: "plus.circle.fill").font(.amb(.title3)) }
                    .buttonStyle(.borderless)
                    .offset(x: Self.cell.nodeWidth + 8, y: Self.cell.nodeHeight / 2 - 12)
                    .accessibilityLabel("Add a next task after \(node.title)").accessibilityIdentifier("tree.next.\(node.title)")
            }
        }
    }

    // MARK: Entry

    private func entryLabel(_ entry: Entry) -> String {
        switch entry {
        case .root: "New base task"
        case .child(let n): "Sub task of \(n.title)"
        case .successor(let n): "Next task after \(n.title)"
        }
    }

    private func entryBar(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entryLabel(entry)).font(.amb(.caption2)).foregroundStyle(Amb.mutedForeground)
            HStack(spacing: 6) {
                TextField("Task title", text: $title).textFieldStyle(.roundedBorder).onSubmit { submit(entry) }
                    .accessibilityIdentifier("tree.entry")
                Button("Add") { submit(entry) }.buttonStyle(.borderedProminent).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("tree.add")
                Button { self.entry = nil; title = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Cancel")
            }
        }
        .padding(8)
        .background(.bar)
    }

    private func begin(_ next: Entry) {
        guard interactive, !busy else { return }
        entry = next; title = ""; requestId = UUID().uuidString.lowercased(); note = nil
    }

    private func submit(_ entry: Entry) {
        guard let sync = model.sync, let connection = model.connection, !busy else { return }
        let name = title, request = requestId, channel = channelId, scope = scopeId, w = workspace
        busy = true; note = nil
        Task {
            do {
                let service = TaskTreeService(sync: sync)
                let task: TaskRecord
                switch entry {
                case .root: task = try await service.create(connection, w, channelId: channel, scopeId: scope, title: name, requestId: request)
                case .child(let n): task = try await service.create(connection, w, channelId: channel, scopeId: scope, title: name, parent: n.id, requestId: request)
                case .successor(let n): task = try await service.create(connection, w, channelId: channel, scopeId: scope, title: name, predecessor: n, requestId: request)
                }
                title = ""; requestId = UUID().uuidString.lowercased()
                var current = view ?? TaskTreeView(savedLayout: naplet.savedLayout, napletId: naplet.id)
                if entry == .root {
                    current.rootTaskId = task.id; current.collapsed = []; current.upstream = []
                    self.entry = nil
                    await save(current)
                } else if case .successor = entry {
                    // Quick chains: the next entry continues after the task just added.
                    self.entry = .successor(TaskTreeNode(task))
                }
                busy = false
                reload(view ?? current)
            } catch {
                busy = false
                // The same request id is kept, so retrying the same title finds the task Tower may already have made.
                note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Loading and view state

    private func reload(_ current: TaskTreeView) {
        guard let root = current.rootTaskId else { graph = TaskTreeGraph(); return }
        guard let sync = model.sync, let connection = model.connection, let store = model.store else { return }
        loading = true
        let w = workspace, revision = UUID()
        loadRevision = revision
        Task {
            let cached = (try? await store.reader.tasks(workspaceId: w.id, includeArchived: true, limit: 2000)) ?? []
            let pending = (try? await store.reader.writes(connectionId: connection.id, workspaceId: w.id)) ?? []
            let savedNodes = cached.map { TaskTreeNode($0, stateOverride: TaskRow(task: $0, writes: pending).state) }
            let saved = await Task.detached { TaskTreeGraph.project(savedNodes, root: root, collapsed: current.collapsed, upstream: current.upstream) }.value
            guard loadRevision == revision else { return }
            graph = saved
            guard model.canRead else {
                note = "Offline or locked. Showing saved tasks; the tree may be incomplete."
                loading = false
                return
            }
            do {
                let result = try await TaskTreeService(sync: sync).load(connection, w, root: root, upstream: current.upstream)
                // Projection runs here, off the main actor's layout work for the rest of the board.
                let records = (try? await store.reader.tasks(workspaceId: w.id, includeArchived: true, limit: 2000)) ?? []
                let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                let pending = (try? await store.reader.writes(connectionId: connection.id, workspaceId: w.id)) ?? []
                let nodes = result.tasks.map { node in
                    byId[node.id].map { TaskTreeNode($0, channelTitle: node.channelTitle, stateOverride: TaskRow(task: $0, writes: pending).state) } ?? node
                }
                let projected = await Task.detached { TaskTreeGraph.project(nodes, root: root, collapsed: current.collapsed, upstream: current.upstream) }.value
                guard loadRevision == revision else { return }
                graph = projected
                note = result.unavailable ? "Some related tasks are not available to you." : (result.partial ? "Tree partially loaded." : nil)
            } catch {
                guard loadRevision == revision else { return }
                note = "Showing saved tasks; the tree may be incomplete. " + ((error as? LocalizedError)?.errorDescription ?? "Tasks unavailable. Refresh to retry.")
            }
            loading = false
        }
    }

    private func toggle(_ node: TaskTreeNode, _ current: TaskTreeView) {
        var next = current
        if let i = next.collapsed.firstIndex(of: node.id) { next.collapsed.remove(at: i) } else { next.collapsed.append(node.id) }
        Task { await save(next); reload(next) }
    }

    /// Managers save the view on the canvas (everyone sees it); others keep it on this device, as on the web.
    private func save(_ next: TaskTreeView) async {
        zoomSave?.cancel(); zoomSave = nil
        view = next
        guard canManage else { return }
        let result = await model.editCanvas { editor, c, w in try await editor.saveTaskTreeView(c, w, canvasId: canvasId, naplet: naplet, view: next) }
        if case .failure(let error) = result { note = error.localizedDescription }
    }

    private func chooseExisting() {
        guard let sync = model.sync, let connection = model.connection else { return }
        choosing = true
        let w = workspace, channel = channelId
        Task { choices = (try? await TaskTreeService(sync: sync).channelTasks(connection, w, channelId: channel)) ?? [] }
    }

    private var existingSheet: some View {
        NavigationStack {
            List(choices) { task in
                Button(task.title) {
                    choosing = false
                    var next = view ?? TaskTreeView(savedLayout: naplet.savedLayout, napletId: naplet.id)
                    next.rootTaskId = task.id; next.collapsed = []; next.upstream = []
                    Task { await save(next); reload(next) }
                }
                .accessibilityIdentifier("tree.choose.\(task.title)")
                .appRowTextSize()
            }
            .overlay { if choices.isEmpty { ProgressView() } }
            .navigationTitle("Choose a task")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } } }
        }
        .presentationDetents([.medium, .large])
    }
}
