import Foundation

/// A local web page for the browser in sample-data mode: it uses `window.nostr` like a Nostr web app and shows what came
/// back. It is served from memory at a reserved `.invalid` host, so nothing goes to the network.
extension FixtureEnvironment {
    var browserSample: (url: URL, html: String) {
        (URL(string: "https://browser.sample.invalid/")!, Self.browserSampleHTML)
    }

    static let browserSampleHTML = """
    <!doctype html>
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Sample Nostr app</title>
    <style>body{font:17px -apple-system,sans-serif;padding:16px}button{font-size:17px;margin:6px 0;padding:10px 14px}p{word-break:break-all}</style>
    </head><body>
    <h1>Sample Nostr app</h1>
    <p id="nostr">window.nostr: missing</p>
    <button id="connect" onclick="connect()">Connect</button>
    <button id="sign" onclick="sign()">Sign note</button>
    <button onclick="setTimeout(connect, 1800)">Connect after delay</button>
    <p><a href="https://browser.sample.invalid/new-tab" target="_blank">Open target blank</a></p>
    <button onclick="window.open('https://browser.sample.invalid/popup')">Open popup</button>
    <p id="result">Nothing yet</p>
    <script>
      const out = (text) => { document.getElementById('result').textContent = text; };
      if (window.nostr) document.getElementById('nostr').textContent = 'window.nostr: ready';
      async function connect() {
        try { const key = await window.nostr.getPublicKey(); out('pubkey ' + key.slice(0, 8)); }
        catch (e) { out('error ' + e.message); }
      }
      async function sign() {
        try {
          const e = await window.nostr.signEvent({ kind: 1, content: 'Hello from the sample page', tags: [['t', 'sample']], created_at: Math.floor(Date.now() / 1000) });
          out('signed ' + e.kind + ' ' + (e.sig.length === 128 ? 'sig ok' : 'sig bad') + ' by ' + e.pubkey.slice(0, 8));
        } catch (e) { out('error ' + e.message); }
      }
    </script>
    </body></html>
    """
}
