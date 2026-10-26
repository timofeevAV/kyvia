// Kyvia: sileo toasts on macOS — a transparent, click-through panel in the top-right
// corner renders the bundled page; POST /notify on 127.0.0.1:47321 shows a toast.
// Body: {"type": "success|error|warning|info|action", "title": "...", "description": "...", "duration": ms}
import Cocoa
import Network
import WebKit

let port: NWEndpoint.Port = 47321
let size = NSSize(width: 390, height: 420)

final class App: NSObject, NSApplicationDelegate {
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

        web = WKWebView(frame: NSRect(origin: .zero, size: size))
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

    // Newest first; clicking an entry shows its toast again.
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

    @objc func replay(_ item: NSMenuItem) { show(history[item.tag].payload) }

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
