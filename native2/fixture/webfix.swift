import AppKit
import WebKit
// The WebKit fixture (#5, #229): a WKWebView page with an <input>, a <textarea>, a contenteditable composer and a
// terminal input that clears itself as xterm.js's does, under a standard Edit menu. The page logs every focus, paste
// and input event to stdout, with the pasted text or the pasted file types, so a test can tell a paste that landed
// from one that didn't. Build it with
// `swiftc -O native2/fixture/webfix.swift -o native2/.build/webfix`; the process and Dock title are "webfix".
func log(_ s: String) { print(s); fflush(stdout) }

final class Logger: NSObject, WKScriptMessageHandler {
	func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		log("page \(message.body)")
	}
}

let page = """
<!doctype html><html><head><title>Web Fixture</title><style>
body{font:14px -apple-system;margin:16px}input,textarea,[contenteditable]{display:block;width:90%;margin:8px 0;font:14px -apple-system}
[contenteditable]{border:1px solid #888;min-height:60px;padding:4px}
</style></head><body>
<label>Name <input id="name" aria-label="Name"></label>
<label>Notes <textarea id="notes" rows="4" aria-label="Notes"></textarea></label>
<div id="composer" contenteditable="true" role="textbox" aria-multiline="true" aria-label="Composer"></div>
<textarea id="term" class="xterm-helper-textarea" aria-label="Terminal input" rows="1"></textarea>
<script>
const post = s => window.webkit.messageHandlers.log.postMessage(s);
for (const id of ['name', 'notes', 'composer']) {
  const el = document.getElementById(id);
  el.addEventListener('focus', () => post('focus ' + id));
  el.addEventListener('paste', e => {
    const d = e.clipboardData;
    post('paste ' + id + ' types=' + JSON.stringify(Array.from(d.types)) + ' files=' + d.files.length + ' text=' + JSON.stringify(d.getData('text/plain')));
  });
  el.addEventListener('input', () => post('input ' + id + ' ' + JSON.stringify(el.value ?? el.innerText)));
}
// Like xterm.js's helper textarea, the terminal input hands each input and paste on and clears itself.
const term = document.getElementById('term');
term.addEventListener('input', () => { post('terminal ' + JSON.stringify(term.value)); term.value = ''; });
post('ready');
</script></body></html>
"""

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu(title: "webfix")
appItem.submenu!.addItem(withTitle: "Quit webfix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
let editItem = NSMenuItem()
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = edit
menu.addItem(editItem)
app.mainMenu = menu

let configuration = WKWebViewConfiguration()
let logger = Logger()
configuration.userContentController.add(logger, name: "log")
let window = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 560, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = "Web Fixture"
window.isReleasedWhenClosed = false
let web = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
web.autoresizingMask = [.width, .height]
window.contentView!.addSubview(web)
web.loadHTMLString(page, baseURL: nil)
window.makeKeyAndOrderFront(nil)
log("ready window=\(window.windowNumber)")
app.run()
