// Kyvia: sileo toasts on macOS — a transparent panel in the top-right corner renders the bundled
// page and lets clicks through except on a toast; POST /notify on 127.0.0.1:47321 shows a toast.
// Body: {"type": "success|error|warning|info|action", "title": "...", "description": "...", "duration": ms,
//        "app": "bundle id to bring forward on click", "path": "the directory the toast is about"}
// POST /ask takes a Claude Code PreToolUse hook's input for AskUserQuestion (X-Kyvia-App: the bundle id to
// bring forward); a question the toast cannot answer gets 204 at once, so the terminal asks it instead.
import Cocoa
import Network
import WebKit

let port: NWEndpoint.Port = 47321
let size = NSSize(width: 390, height: 420)

// WebKit hit-tests pointer moves (hover, :hover) only in a key window; the panel must never take the keyboard,
// so it only claims to be key. Keystrokes still go to the app that has them.
final class Panel: NSPanel {
    override var isKeyWindow: Bool { true }
}

// The window server ignores cursor changes from an app in the background unless its connection opts in.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty") func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var panel: Panel!
    var web: WKWebView!
    var listener: NWListener!
    var statusItem: NSStatusItem!
    // shortcut: history lives in memory only, so a restart of the app empties the menu.
    var history: [(date: Date, payload: [String: Any])] = []
    let historyLimit = 20
    // Questions waiting for a click, by toast; each connection gets exactly one answer.
    // shortcut: Esc in the terminal kills the hook but the toast stays until its deadline; drop the toast when the peer closes if that annoys.
    var pending: [Int: (conn: NWConnection, input: [String: Any], question: String, labels: [String], timer: Timer)] = [:]
    var askCount = 0
    var pointerInside = false
    let symbols = ["success": "checkmark.circle", "error": "xmark.circle", "warning": "exclamationmark.triangle",
                   "info": "info.circle", "action": "arrow.right.circle"]

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["sound": true])
        _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        panel = Panel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        // The panel takes the mouse only while the pointer is over a toast.
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.trackMouse() }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] in self?.trackMouse(); return $0 }

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "focus")
        config.userContentController.add(self, name: "answer")
        web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        panel.contentView = web
        let page = Bundle.main.resourceURL!.appendingPathComponent("index.html")
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

        placePanel()
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")
        rebuildMenu()
        startServer()
    }

    // Newest first; clicking an entry brings its app forward, or shows the toast again if it has none.
    func rebuildMenu() {
        let menu = NSMenu()
        if history.isEmpty { menu.addItem(withTitle: "No notifications", action: nil, keyEquivalent: "") }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        for (index, entry) in history.enumerated().reversed() {
            let title = entry.payload["title"] as? String ?? ""
            let item = NSMenuItem(title: "\(time.string(from: entry.date))  \(title)", action: #selector(replay(_:)), keyEquivalent: "")
            if #available(macOS 14.4, *) { item.subtitle = entry.payload["description"] as? String }
            else { item.toolTip = entry.payload["description"] as? String }
            item.image = NSImage(systemSymbolName: symbols[entry.payload["type"] as? String ?? ""] ?? "bell",
                                 accessibilityDescription: nil)
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sound = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        sound.state = UserDefaults.standard.bool(forKey: "sound") ? .on : .off
        sound.target = self
        menu.addItem(sound)
        let clear = NSMenuItem(title: "Clear", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        statusItem.menu = menu
    }

    @objc func replay(_ item: NSMenuItem) {
        let payload = history[item.tag].payload
        if payload["app"] != nil { focus(app: payload["app"] as? String, path: payload["path"] as? String) }
        else { show(payload) }
    }

    // A never-key window gets no pointer moves, so the app hands each one to the page itself (hover, :hover,
    // the cursor) and once more on the way out; the panel takes the mouse only while the page says the
    // pointer is over a toast.
    func trackMouse() {
        let point = NSEvent.mouseLocation, frame = panel.frame
        let inside = frame.contains(point)
        guard inside || pointerInside else { return }
        pointerInside = inside
        let at = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY), now = ProcessInfo.processInfo.systemUptime
        guard inside else {
            panel.ignoresMouseEvents = true
            forward("_simulateMouseExit:", NSEvent.enterExitEvent(with: .mouseExited, location: at, modifierFlags: [], timestamp: now,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            return
        }
        forward("_simulateMouseMove:", NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: now,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        web.callAsyncJavaScript("return window.toastCursor(x, y)", arguments: ["x": at.x, "y": frame.height - at.y], in: nil, in: .page) { [weak self] in
            guard let self, self.pointerInside else { return } // the pointer left before the page answered
            let cursor = (try? $0.get()) as? String
            self.panel.ignoresMouseEvents = cursor == nil
            // The app under the panel resets the cursor on each move and WebKit sets it only on a change, so set it every time.
            if let cursor { (cursor == "pointer" ? NSCursor.pointingHand : NSCursor.arrow).set() }
        }
    }

    // WKWebView reads pointer moves only from its own tracking area; this WebKit SPI takes one from the app.
    // A WebKit without it leaves the page without hover, nothing worse.
    func forward(_ selector: String, _ event: NSEvent?) {
        let sel = NSSelectorFromString(selector)
        if let event, web.responds(to: sel) { web.perform(sel, with: event) }
    }

    // A click on a toast: an option answers its question; anywhere else the page sends back the toast's app
    // and path, and a question is left to the terminal.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let target = message.body as? [String: Any]
        let id = target?["ask"] as? Int ?? 0
        if message.name == "answer" {
            // The label comes from the question itself, so the page can only pick an offered option.
            if let option = target?["option"] as? Int, let labels = pending[id]?.labels, labels.indices.contains(option) {
                finish(id, label: labels[option])
            }
            return
        }
        focus(app: target?["app"] as? String, path: target?["path"] as? String)
        finish(id, label: nil)
    }

    // Bring a running app forward, never launch one. VS Code gets the window whose folder holds the path:
    // opening a folder it already shows focuses that window instead of opening a new one.
    func focus(app: String?, path: String?) {
        guard let app, let url = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        if app == "com.microsoft.VSCode", let path, let folder = vscodeFolder(holding: path) {
            NSWorkspace.shared.open([folder], withApplicationAt: url, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    // The deepest folder open in a VS Code window that holds path, from the window list VS Code saves.
    func vscodeFolder(holding path: String) -> URL? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["windowsState"] as? [String: Any] else { return nil }
        let windows = [state["lastActiveWindow"] as Any] + (state["openedWindows"] as? [Any] ?? [])
        return windows.compactMap { ($0 as? [String: Any])?["folder"] as? String }
            .compactMap(URL.init(string:)).filter { $0.isFileURL }
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    @objc func toggleSound() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "sound"), forKey: "sound")
        rebuildMenu()
    }

    @objc func clearHistory() {
        history.removeAll()
        rebuildMenu()
    }

    // Follow the screen the user is working on.
    func placePanel() {
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height))
    }

    func show(_ payload: [String: Any]) {
        placePanel()
        panel.orderFrontRegardless()
        // Arguments are passed as values, never spliced into the script source.
        web.callAsyncJavaScript("window.notify(p)", arguments: ["p": payload], in: nil, in: .page)
    }

    func startServer() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        listener = try! NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.read(conn, Data())
        }
        // A busy port fails here, not in init; exit so launchd's KeepAlive retries instead of idling deaf.
        listener.stateUpdateHandler = { if case .failed = $0 { exit(1) } }
        listener.start(queue: .main)
    }

    func read(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if error != nil || data.count > 65536 { return conn.cancel() }
            switch self.parse(data) {
            case .incomplete where !done: self.read(conn, data)
            case .notify(let body): self.reply(conn, self.handle(body) ? "204 No Content" : "400 Bad Request")
            case .ask(let body, let app): self.ask(conn, body, app: app)
            case .forbidden: self.reply(conn, "403 Forbidden")
            default: self.reply(conn, "400 Bad Request")
            }
        }
    }

    enum Parsed { case incomplete, notify(Data), ask(Data, app: String?), forbidden, bad }

    func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let raw = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let lines = raw.map { $0.lowercased() }
        let isAsk = lines.first?.hasPrefix("post /ask ") == true
        guard isAsk || lines.first?.hasPrefix("post /notify ") == true else { return .bad }
        // A custom header cannot be sent cross-origin without a CORS preflight, which this
        // server never answers, so web pages in a browser cannot raise toasts.
        guard lines.contains("x-kyvia: 1") else { return .forbidden }
        // A page that rebinds its own domain to 127.0.0.1 is same-origin and may send the header; its Host gives it away.
        guard lines.contains("host: 127.0.0.1:47321") || lines.contains("host: localhost:47321") else { return .forbidden }
        let length = lines.lazy.compactMap { $0.hasPrefix("content-length:") ? Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
        guard length >= 0 else { return .bad }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        let content = Data(body.prefix(length))
        guard isAsk else { return .notify(content) }
        // Header names ignore case, a bundle id does not: read the value from the raw line.
        let app = raw.first { $0.lowercased().hasPrefix("x-kyvia-app:") }?.dropFirst(12).trimmingCharacters(in: .whitespaces)
        return .ask(content, app: bundleID(app))
    }

    func bundleID(_ value: String?) -> String? {
        guard let value, value.count <= 255, value.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }

    // The one shape a toast can answer: a single single-choice question with 2 to 4 labelled options.
    func askable(_ json: [String: Any]) -> (input: [String: Any], question: String, labels: [String])? {
        guard json["tool_name"] as? String == "AskUserQuestion", let input = json["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]], questions.count == 1,
              let question = questions[0]["question"] as? String, !question.isEmpty,
              questions[0]["multiSelect"] as? Bool != true,
              let options = questions[0]["options"] as? [[String: Any]], (2...4).contains(options.count) else { return nil }
        let labels = options.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
        return labels.count == options.count ? (input, question, labels) : nil
    }

    func ask(_ conn: NWConnection, _ body: Data, app: String?) {
        // isValidJSONObject: -1e999 parses as -inf, which writing the answer back would crash on (an uncatchable exception).
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], JSONSerialization.isValidJSONObject(json)
        else { return reply(conn, "400 Bad Request") }
        guard let (input, question, labels) = askable(json) else { return reply(conn, "204 No Content") }
        askCount += 1
        let id = askCount
        let timer = Timer(timeInterval: 120, repeats: false) { [weak self] _ in self?.finish(id, label: nil) }
        RunLoop.main.add(timer, forMode: .common) // the deadline keeps running while the menu-bar menu is open
        pending[id] = (conn, input, question, labels, timer)
        var payload: [String: Any] = ["type": "action", "title": "Claude", "description": String(question.prefix(500)),
                                      "duration": 120000.0, "options": labels.map { String($0.prefix(500)) }, "ask": id]
        if let cwd = json["cwd"] as? String, cwd.hasPrefix("/"), cwd.count <= 1024 {
            payload["path"] = cwd
            payload["title"] = String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(500))
        }
        if let app { payload["app"] = app }
        present(payload)
    }

    // Answer a waiting question once: 200 with the hook's output for a label, 204 to leave it to the terminal.
    func finish(_ id: Int, label: String?) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.invalidate()
        // sileo restarts a toast's full duration whenever the pointer leaves it, so the page cannot keep the deadline.
        web.callAsyncJavaScript("window.dismissAsk(a)", arguments: ["a": id], in: nil, in: .page)
        guard let label else { return reply(entry.conn, "204 No Content") }
        var input = entry.input
        input["answers"] = [entry.question: label]
        let output = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]]
        reply(entry.conn, "200 OK", body: (try? JSONSerialization.data(withJSONObject: output)) ?? Data())
    }

    // Keep only the known fields, as strings of bounded length.
    func handle(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        var payload: [String: Any] = [:]
        for key in ["type", "title", "description"] {
            if let value = json[key] as? String { payload[key] = String(value.prefix(500)) }
        }
        if let duration = json["duration"] as? Double, duration > 0 { payload["duration"] = min(duration, 600000) }
        if let app = bundleID(json["app"] as? String) { payload["app"] = app }
        if let path = json["path"] as? String, path.hasPrefix("/"), path.count <= 1024 { payload["path"] = path }
        present(payload)
        return true
    }

    func present(_ payload: [String: Any]) {
        show(payload)
        if UserDefaults.standard.bool(forKey: "sound") { NSSound(named: "Glass")?.play() }
        // A replayed question has nobody waiting for it, so history keeps it without its options.
        history.append((Date(), payload.filter { $0.key != "options" && $0.key != "ask" }))
        history.removeFirst(max(0, history.count - historyLimit))
        rebuildMenu()
    }

    func reply(_ conn: NWConnection, _ status: String, body: Data = Data()) {
        let type = body.isEmpty ? "" : "Content-Type: application/json\r\n"
        let head = "HTTP/1.1 \(status)\r\n\(type)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
