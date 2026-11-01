import ClaudeStatusCore
import Foundation
import Network

/// A read-only copy of the menu as HTML, reachable only over Tailscale.
final class WebServer: @unchecked Sendable {
    static let port: NWEndpoint.Port = 9001

    private let queue = DispatchQueue(label: "dev.chrfalch.ClaudeStatus.web")
    private let lock = NSLock()
    private var snapshot = WebSnapshot(agents: [], summaries: [:], hosts: [:], usages: [], updated: nil)
    private var binary: String?
    // Another web page in the same browser can post a form here, but it cannot read this value from our page.
    private let stopToken = UUID().uuidString
    private var listener: NWListener?
    private var address: String?

    func update(_ snapshot: WebSnapshot, binary: String?) {
        lock.withLock {
            self.snapshot = snapshot
            self.binary = binary
        }
    }

    /// Binds to the Tailscale address only, so the page is not visible on the local network.
    /// Called on every poll, so the server starts when Tailscale connects and moves when its address changes.
    func startIfNeeded() {
        queue.async { [self] in
            let current = Self.tailscaleAddress()
            guard current != address || listener == nil else { return }
            listener?.cancel()
            listener = nil
            address = current
            guard let current else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(current), port: Self.port)
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters) else { return }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.queue.async { self?.listener = nil } }
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, received: Data())
    }

    private func receive(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            let received = received + (data ?? Data())
            let text = String(decoding: received, as: UTF8.self)
            if !WebPage.Request.isComplete(text), !isComplete, error == nil, received.count < 64 * 1024 {
                return self.receive(connection, received: received)
            }
            let (status, headers, html) = self.response(WebPage.Request(text))
            let body = Data(html.utf8)
            let head = "HTTP/1.1 \(status)\r\n\(headers)Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(_ request: WebPage.Request?) -> (String, String, String) {
        let (status, html) = page(request)
        if status == "303 See Other" { return (status, "Location: /\r\n", html) }
        return (status, "", html)
    }

    private func page(_ request: WebPage.Request?) -> (String, String) {
        let (snapshot, binary) = lock.withLock { (self.snapshot, self.binary) }
        let now = Date()
        guard let request else { return ("400 Bad Request", "") }
        if request.method == "POST" {
            guard request.path.hasPrefix("/agent/"), request.path.hasSuffix("/stop"), request.form["token"] == stopToken else {
                return ("403 Forbidden", "<!doctype html><p>Not allowed. <a href=\"/\">All agents</a></p>")
            }
            let id = String(request.path.dropFirst("/agent/".count).dropLast("/stop".count)).removingPercentEncoding ?? ""
            guard let agent = snapshot.agents.first(where: { WebPage.key(of: $0) == id }), let action = WebPage.stopAction(for: agent) else {
                return ("404 Not Found", "<!doctype html><p>No such agent. <a href=\"/\">All agents</a></p>")
            }
            return Self.stop(action, binary: binary) ? ("303 See Other", "") : ("500 Internal Server Error", "<!doctype html><p>The agent did not stop. <a href=\"/\">All agents</a></p>")
        }
        guard request.method == "GET" else { return ("405 Method Not Allowed", "") }
        switch request.path {
        case "/":
            return ("200 OK", WebPage.list(snapshot, now: now))
        case let path where path.hasPrefix("/agent/"):
            let id = String(path.dropFirst("/agent/".count)).removingPercentEncoding ?? ""
            let agent = snapshot.agents.first { WebPage.key(of: $0) == id }
            let ledger = agent?.cwd.flatMap { try? String(contentsOfFile: $0 + "/.claude/ledger.md", encoding: .utf8) }
            let lastText = agent?.sessionId.flatMap(Self.transcript).flatMap { try? Transcript.lastText(at: $0) }
            if let html = WebPage.detail(snapshot, id: id, ledger: ledger, lastText: lastText, now: now, stopToken: stopToken) { return ("200 OK", html) }
            return ("404 Not Found", "<!doctype html><p>No such agent. <a href=\"/\">All agents</a></p>")
        default:
            return ("404 Not Found", "<!doctype html><p>Not found. <a href=\"/\">All agents</a></p>")
        }
    }

    private static func stop(_ action: WebPage.StopAction, binary: String?) -> Bool {
        switch action {
        case .command(let arguments):
            guard let binary else { return false }
            return (try? ProcessRunner.run(URL(fileURLWithPath: binary), arguments: arguments, timeout: 15)) != nil
        case .signal(let pid):
            // The list can be up to one poll old, so the process ID may belong to another program by now.
            guard ProcessTree.arguments(of: pid)?.first.map({ $0.hasSuffix("/claude") || $0.contains("/claude/versions/") }) == true else { return false }
            return kill(pid, SIGTERM) == 0
        }
    }

    private static func transcript(sessionId: String) -> URL? {
        let directories = (try? FileManager.default.contentsOfDirectory(at: Transcript.projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        return directories.map { $0.appendingPathComponent("\(sessionId).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func tailscaleAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if WebPage.isTailscale(text) { return text }
        }
        return nil
    }
}
