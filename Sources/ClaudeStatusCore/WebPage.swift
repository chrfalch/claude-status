import Foundation

/// What the menu showed at its last refresh, for the read-only web page.
public struct WebSnapshot: Sendable {
    public let agents: [Agent]
    /// Keyed by `WebPage.key(of:)`.
    public let summaries: [String: String]
    public let hosts: [String: String]
    public let usages: [(String, Usage)]
    public let updated: Date?

    public init(agents: [Agent], summaries: [String: String], hosts: [String: String], usages: [(String, Usage)], updated: Date?) {
        self.agents = agents
        self.summaries = summaries
        self.hosts = hosts
        self.usages = usages
        self.updated = updated
    }
}

public enum WebPage {
    public static func key(of agent: Agent) -> String {
        agent.sessionId ?? agent.id ?? "pid-\(agent.pid ?? 0)"
    }

    public static func list(_ snapshot: WebSnapshot, now: Date) -> String {
        var body = usage(snapshot.usages, now: now)
        if snapshot.agents.isEmpty { body += "<p class=muted>No agents</p>" }
        body += "<ul class=agents>"
        for agent in snapshot.agents {
            let key = key(of: agent)
            body += "<li><a href=\"/agent/\(escape(key))\"><span class=\"dot \(agent.activity.label)\"></span><div><b>\(escape(agent.menuLabel))</b>"
            body += counts(agent)
            if let summary = snapshot.summaries[key] { body += "<p class=muted>\(escape(Summary.twoLines(summary)))</p>" }
            body += "</div></a></li>"
        }
        body += "</ul>" + footer(snapshot, now: now)
        return page(title: "Claude Status", body: body)
    }

    public static func detail(_ snapshot: WebSnapshot, id: String, ledger: String?, lastText: String?, now: Date, stopToken: String) -> String? {
        guard let agent = snapshot.agents.first(where: { key(of: $0) == id }) else { return nil }
        var body = "<p><a href=\"/\">← All agents</a></p><h1><span class=\"dot \(agent.activity.label)\"></span>\(escape(agent.displayName))</h1>"
        var rows: [(String, String)] = [("State", agent.activity.label + ((agent.state ?? agent.status).map { " (\(escape($0)))" } ?? ""))]
        let work = [plural(agent.runningSubagents, "sub-agent"), plural(agent.shellCommands, "shell command")].compactMap { $0 }
        if !work.isEmpty { rows.append(("Running", work.joined(separator: ", "))) }
        if let lastActivity = agent.lastActivity { rows.append(("Last activity", ago(lastActivity, now: now))) }
        if let startedAt = agent.startedAt { rows.append(("Started", ago(Date(timeIntervalSince1970: startedAt / 1000), now: now))) }
        if let host = snapshot.hosts[id] { rows.append(("App", escape(host))) }
        if let cwd = agent.cwd { rows.append(("Folder", "<code>\(escape(cwd))</code>")) }
        if let kind = agent.kind { rows.append(("Kind", escape(kind))) }
        if let sessionId = agent.sessionId { rows.append(("Session", "<code>\(escape(sessionId))</code>")) }
        if let pid = agent.pid { rows.append(("Process", "\(pid)")) }
        body += "<table>" + rows.map { "<tr><th>\($0.0)</th><td>\($0.1)</td></tr>" }.joined() + "</table>"
        if stopAction(for: agent) != nil {
            body += "<form method=\"post\" action=\"/agent/\(escape(id))/stop\" onsubmit=\"return confirm('Stop this agent?')\">"
                + "<input type=hidden name=token value=\"\(escape(stopToken))\"><button class=stop>Stop agent</button></form>"
        }
        if let summary = snapshot.summaries[id] { body += "<h2>Summary</h2><p>\(escape(summary))</p>" }
        if let lastText { body += "<h2>Last message</h2><pre>\(escape(lastText))</pre>" }
        if let ledger { body += "<h2>Ledger</h2><pre>\(escape(ledger))</pre>" }
        body += footer(snapshot, now: now)
        return page(title: agent.displayName, body: body)
    }

    public struct Request {
        public let method: String
        public let path: String
        public let form: [String: String]

        public init?(_ text: String) {
            let parts = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
            guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
            method = String(parts[0])
            path = String(parts[1].prefix { $0 != "?" })
            let body = text.range(of: "\r\n\r\n").map { text[$0.upperBound...] } ?? ""
            form = body.split(separator: "&").reduce(into: [:]) { form, pair in
                let field = pair.split(separator: "=", maxSplits: 1).map { $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
                if field.count == 2 { form[field[0]] = field[1] }
            }
        }

        /// True when the headers and the whole body, as told by Content-Length, have arrived.
        public static func isComplete(_ text: String) -> Bool {
            guard let end = text.range(of: "\r\n\r\n") else { return false }
            let length = text[..<end.lowerBound].split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            return text[end.upperBound...].utf8.count >= length
        }
    }

    public enum StopAction: Equatable, Sendable {
        /// Arguments for the claude binary.
        case command([String])
        case signal(Int32)
    }

    // Background sessions have their own stop command; for the others, SIGTERM lets Claude Code save the conversation.
    public static func stopAction(for agent: Agent) -> StopAction? {
        if agent.kind == "background", let id = agent.id { return .command(["stop", id]) }
        return agent.pid.map { .signal(Int32($0)) }
    }

    /// Tailscale gives each device an address in 100.64.0.0/10.
    public static func isTailscale(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func counts(_ agent: Agent) -> String {
        let work = [plural(agent.runningSubagents, "sub-agent"), plural(agent.shellCommands, "shell command")].compactMap { $0 }
        return work.isEmpty ? "" : " <span class=chip>\(work.joined(separator: " · "))</span>"
    }

    private static func plural(_ count: Int, _ noun: String) -> String? {
        count == 0 ? nil : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func usage(_ usages: [(String, Usage)], now: Date) -> String {
        var html = ""
        for (name, usage) in usages {
            let gauges = usage.gauges(now: now)
            guard !gauges.isEmpty else { continue }
            html += "<section class=usage><h3>\(escape(name))"
            if let age = usage.ageText(now: now) { html += " <span class=muted>\(escape(age))</span>" }
            html += "</h3>"
            for gauge in gauges {
                let used = Int(((gauge.used ?? 0) * 100).rounded())
                let fill = used >= 90 ? "red" : used >= 75 ? "orange" : "blue"
                let marker = gauge.elapsed.map { "<i style=\"left:\(Int($0 * 100))%\"></i>" } ?? ""
                html += "<div class=gauge><span>\(escape(gauge.name))</span><div class=bar><b class=\(fill) style=\"width:\(used)%\"></b>\(marker)</div><span>\(escape(gauge.detail))"
                if let pace = gauge.pace { html += "<br><small class=\"pace \(pace.level)\">\(escape(pace.text))</small>" }
                html += "</span></div>"
            }
            html += "</section>"
        }
        return html
    }

    private static func footer(_ snapshot: WebSnapshot, now: Date) -> String {
        "<p class=muted>Updated \(snapshot.updated.map { ago($0, now: now) } ?? "never"). This page reloads every 5 seconds.</p>"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m ago" }
        return "\(seconds / 86400)d ago"
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
        <meta http-equiv=refresh content=5><title>\(escape(title))</title><style>
        :root{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--track:#e5e5ea}
        @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f2f2f7;--muted:#98989d;--line:#38383a;--track:#3a3a3c}}
        body{background:var(--bg);color:var(--fg);font:15px -apple-system,system-ui,sans-serif;max-width:720px;margin:0 auto;padding:16px}
        a{color:inherit;text-decoration:none}h1{font-size:20px;display:flex;align-items:center;gap:8px}h2{font-size:15px;margin-top:24px}
        h3{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin:12px 0 6px}
        .muted{color:var(--muted);font-size:13px;margin:2px 0}.agents{list-style:none;padding:0}
        .agents li a{display:flex;gap:10px;padding:10px 4px;border-bottom:1px solid var(--line)}.agents li a:hover{background:var(--line)}
        .dot{flex:none;width:10px;height:10px;border-radius:50%;margin-top:5px}.dot.waiting{background:#0a84ff}.dot.working{background:#30d158}.dot.idle{background:#8e8e93}
        .chip{font-size:12px;color:var(--muted);border:1px solid var(--line);border-radius:8px;padding:0 6px;margin-left:6px}
        .gauge{display:grid;grid-template-columns:64px 1fr auto;gap:10px;align-items:center;font-size:13px;margin:4px 0}.gauge>span:last-child{text-align:right}
        .bar{position:relative;height:6px;border-radius:3px;background:var(--track)}.bar b{position:absolute;inset:0 auto 0 0;border-radius:3px}
        .bar i{position:absolute;top:-3px;width:2px;height:12px;background:var(--fg)}.blue{background:#0a84ff}.orange{background:#ff9f0a}.red{background:#ff453a}
        .stop{margin-top:16px;font:inherit;color:#fff;background:#ff453a;border:0;border-radius:8px;padding:8px 16px}
        .pace{color:var(--muted)}.pace.ahead{color:#ff9f0a}.pace.over{color:#ff453a;background:none}
        table{border-collapse:collapse}th{text-align:left;color:var(--muted);font-weight:500;padding:3px 16px 3px 0;vertical-align:top}
        pre{white-space:pre-wrap;word-break:break-word;background:var(--line);padding:10px;border-radius:6px;font-size:12px}
        </style></head><body>\(body)</body></html>
        """
    }
}
