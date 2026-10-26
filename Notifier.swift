// Kyvia: sileo toasts on macOS — a transparent panel in the top-right corner renders the bundled
// page and lets clicks through except on a toast; POST /notify on 127.0.0.1:47321 shows a toast.
// Body: {"type": "success|error|warning|info|action", "title": "...", "description": "...", "duration": ms,
//        "app": "bundle id to bring forward on click", "path": "the directory the toast is about"}
import Cocoa
import Network
import WebKit

let port: NWEndpoint.Port = 47321
let size = NSSize(width: 390, height: 420)

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var panel: NSPanel!
    var web: WKWebView!
    var listener: NWListener!
    var statusItem: NSStatusItem!
    // shortcut: history lives in memory only, so a restart of the app empties the menu.
    var history: [(date: Date, payload: [String: Any])] = []
    let historyLimit = 20
    let symbols = ["success": "checkmark.circle", "error": "xmark.circle", "warning": "exclamationmark.triangle",
                   "info": "info.circle", "action": "arrow.right.circle"]

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["sound": true])
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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

    func trackMouse() {
        let point = NSEvent.mouseLocation, frame = panel.frame
        guard frame.contains(point) else { panel.ignoresMouseEvents = true; return }
        web.callAsyncJavaScript("return !!document.elementFromPoint(x, y)?.closest('[data-sileo-toast]')",
                                arguments: ["x": point.x - frame.minX, "y": frame.maxY - point.y], in: nil, in: .page) { [weak self] in
            self?.panel.ignoresMouseEvents = (try? $0.get()) as? Bool != true
        }
    }

    // A click on a toast: the page sends back the toast's app and path.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let target = message.body as? [String: Any]
        focus(app: target?["app"] as? String, path: target?["path"] as? String)
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
            case .request(let body): self.reply(conn, self.handle(body) ? "204 No Content" : "400 Bad Request")
            case .forbidden: self.reply(conn, "403 Forbidden")
            default: self.reply(conn, "400 Bad Request")
            }
        }
    }

    enum Parsed { case incomplete, request(Data), forbidden, bad }

    func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let lines = head.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("post /notify ") == true else { return .bad }
        // A custom header cannot be sent cross-origin without a CORS preflight, which this
        // server never answers, so web pages in a browser cannot raise toasts.
        guard lines.contains("x-kyvia: 1") else { return .forbidden }
        let length = lines.lazy.compactMap { $0.hasPrefix("content-length:") ? Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
        let body = data[end.upperBound...]
        return body.count < length ? .incomplete : .request(Data(body.prefix(length)))
    }

    // Keep only the known fields, as strings of bounded length.
    func handle(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        var payload: [String: Any] = [:]
        for key in ["type", "title", "description"] {
            if let value = json[key] as? String { payload[key] = String(value.prefix(500)) }
        }
        if let duration = json["duration"] as? Double, duration > 0 { payload["duration"] = min(duration, 600000) }
        if let app = json["app"] as? String, app.count <= 255,
           app.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil { payload["app"] = app }
        if let path = json["path"] as? String, path.hasPrefix("/"), path.count <= 1024 { payload["path"] = path }
        show(payload)
        if UserDefaults.standard.bool(forKey: "sound") { NSSound(named: "Glass")?.play() }
        history.append((Date(), payload))
        history.removeFirst(max(0, history.count - historyLimit))
        rebuildMenu()
        return true
    }

    func reply(_ conn: NWConnection, _ status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
