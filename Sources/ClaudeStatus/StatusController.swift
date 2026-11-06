import AppKit
import ClaudeStatusCore

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let queue = DispatchQueue(label: "dev.chrfalch.ClaudeStatus.poll", qos: .utility)
    private var timer: Timer?
    private var binary: String?
    private var lastLookupFailure: Date?
    private var refreshing = false
    private var agents: [Agent] = []
    private let summarizer = Summarizer()
    private let web = WebServer()
    private var summaries: [String: String] = [:]
    private var errorText: String? = "Loading…"
    private var lastUpdated: Date?
    private var iconColor: NSColor?
    private var dot: NSImage?
    private var warningColor: NSColor?
    private var blink: Timer?
    private var usages: [(String, Usage)] = []
    private var fetchingClaudeUsage = false
    private let usageIcons: [String: NSImage] = [("Claude", "com.anthropic.claudefordesktop"), ("Codex", "com.openai.codex")]
        .reduce(into: [:]) { icons, app in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.1) {
                icons[app.0] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    private var pulse: Timer?
    // Larger than the dot so the rings have room to grow; the menu bar scales down anything taller.
    private let iconCanvas = min(22, NSStatusBar.system.thickness)
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // The poll reads usage only after the slower agent list, so the menu would open with the last poll's numbers.
    func menuWillOpen(_ menu: NSMenu) {
        usages = Self.readUsages()
        render()
        refresh(force: true)
        fetchClaudeUsage()
    }

    // Claude Code writes its usage cache only on some events, such as /usage, and not when only the VS Code panel is used.
    // In print mode /usage makes no model call, so it costs no tokens.
    private func fetchClaudeUsage() {
        let claude = usages.first { $0.0 == "Claude" }?.1
        guard !fetchingClaudeUsage, let binary,
              Date().timeIntervalSince(claude?.fetchedAt ?? .distantPast) > Usage.claudeCacheLifetime else { return }
        fetchingClaudeUsage = true
        render()
        DispatchQueue.global(qos: .utility).async {
            _ = try? ProcessRunner.run(URL(fileURLWithPath: binary), arguments: ["-p", "/usage", "--no-session-persistence"], timeout: 30,
                                       directory: FileManager.default.homeDirectoryForCurrentUser)
            let usages = Self.readUsages()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fetchingClaudeUsage = false
                self.usages = usages
                self.render()
            }
        }
    }

    @objc private func refreshNow() { refresh(force: true) }

    private func refresh(force: Bool = false) {
        guard !refreshing else { return }
        // A failed lookup may run the user's interactive shell, and a hung shell leaks children on timeout.
        if binary == nil, !force, let lastLookupFailure, Date().timeIntervalSince(lastLookupFailure) < 60 { return }
        refreshing = true
        let cachedBinary = binary
        queue.async { [weak self] in
            let resolved = Result { () throws(CommandError) -> String in
                do { return try cachedBinary ?? resolveBinary() }
                catch { throw CommandError(message: error.localizedDescription) }
            }
            let result: Result<[Agent], CommandError> = Result { () throws(CommandError) -> [Agent] in
                do {
                    let agents = try Agent.decode(ProcessRunner.run(URL(fileURLWithPath: try resolved.get()), arguments: ["agents", "--json"], timeout: 15))
                    let rosterURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/daemon/roster.json")
                    let roster = (try? Data(contentsOf: rosterURL)).flatMap { try? JSONDecoder().decode(Roster.self, from: $0) }
                    let live = Agent.live(agents, roster: roster, isAlive: ProcessLiveness.isAlive)
                    let activity = Transcript.activity(sessionIds: Set(live.compactMap(\.sessionId)))
                    let children = ProcessTree.children(of: Set(live.compactMap { $0.pid.map(Int32.init) }))
                    return live.map { agent in
                        var agent = agent
                        agent.ledgerTitle = agent.cwd.flatMap(Ledger.title(forWorktree:))
                        let sessionActivity = agent.sessionId.flatMap { activity[$0] }
                        agent.lastActivity = sessionActivity?.lastModified
                        agent.runningSubagents = sessionActivity?.runningSubagents ?? 0
                        agent.shellCommands = agent.pid.flatMap { children[Int32($0)] }?
                            .filter { ProcessTree.arguments(of: $0).map(ProcessTree.isClaudeShellCommand) ?? false }.count ?? 0
                        return agent
                    }
                } catch {
                    throw CommandError(message: error.localizedDescription)
                }
            }
            let usages = Self.readUsages()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.usages = usages
                switch resolved {
                case .success(let path): self.binary = path
                case .failure: self.lastLookupFailure = Date()
                }
                self.refreshing = false
                switch result {
                case .success(let agents):
                    self.lastUpdated = Date()
                    self.agents = Agent.sorted(agents)
                    let sessionIds = Set(agents.compactMap(\.sessionId))
                    self.summaries = self.summaries.filter { sessionIds.contains($0.key) }
                    self.errorText = nil
                    Task { [self] in
                        await self.summarizer.update(sessionIds: agents.compactMap(\.sessionId)) { [weak self] sessionId, summary in
                            guard let self, self.agents.contains(where: { $0.sessionId == sessionId }),
                                  self.summaries[sessionId] != summary else { return }
                            self.summaries[sessionId] = summary
                            self.render()
                        }
                    }
                case .failure(let error):
                    self.errorText = error.message
                }
                self.render()
            }
        }
    }

    nonisolated private static func readUsages() -> [(String, Usage)] {
        // The status line file is written only when the CLI runs, and the config cache only when Claude Code fetches.
        let claude = Usage.newest([
            (try? Data(contentsOf: Usage.file)).flatMap(Usage.decode)?.with(fetchedAt: modificationDate(Usage.file)),
            (try? Data(contentsOf: Usage.claudeConfig)).flatMap(Usage.decodeClaudeConfig),
        ])
        let codexLog = Usage.newestCodexSessionLog()
        let codex = codexLog.flatMap { try? tail(of: $0) }.flatMap { Usage.codex(sessionLog: $0) }?.with(fetchedAt: codexLog.flatMap(modificationDate))
        return [("Claude", claude), ("Codex", codex)].compactMap { name, usage in usage.map { (name, $0) } }
    }

    nonisolated private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Codex session logs grow for the whole session, and its latest limits are near the end.
    nonisolated private static func tail(of url: URL, bytes: UInt64 = 512 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return try handle.readToEnd() ?? Data()
    }

    private func render() {
        menu.removeAllItems()
        let sections = usages
            .map { name, usage in
                let age = name == "Claude" && fetchingClaudeUsage ? "updating…" : usage.ageText(now: Date())
                return (title: name, icon: usageIcons[name], age: age, gauges: usage.gauges(now: Date()))
            }
            .filter { !$0.gauges.isEmpty }
        if !sections.isEmpty {
            let line = NSMenuItem()
            line.view = UsageView(sections: sections)
            menu.addItem(line)
            menu.addItem(.separator())
        }
        showWarning(Usage.warning(usages.map(\.1), now: Date()).map { $0 == .over ? .systemRed : .systemOrange })
        if let errorText {
            showIcon(.systemOrange)
            item.button?.toolTip = errorText
            addLabel(errorText)
        } else {
            let activities = agents.map(\.activity)
            showIcon(color(Activity.aggregate(activities)))
            item.button?.toolTip = "\(activities.filter { $0 == .waiting }.count) waiting · \(activities.filter { $0 == .working }.count) working · \(activities.filter { $0 == .idle }.count) idle"
            if agents.isEmpty { addLabel("No agents") }
            else {
                let rows = agents.map { agent in
                    let host = agent.pid.flatMap { hostApp(of: Int32($0)) }
                    return AgentRow(
                        title: agent.menuLabel,
                        summary: agent.sessionId.flatMap { summaries[$0] }.map { Summary.twoLines($0) },
                        color: color(agent.activity),
                        runningSubagents: agent.runningSubagents,
                        shellCommands: agent.shellCommands,
                        host: host,
                        open: host.map { host -> @MainActor () -> Void in { [weak self] in self?.open(agent, in: host) } }
                    )
                }
                let list = NSMenuItem()
                list.view = AgentListView(rows: rows)
                menu.addItem(list)
            }
        }
        menu.addItem(.separator())
        let time = lastUpdated.map { timeFormatter.string(from: $0) } ?? "—"
        addLabel("Last updated \(time)")
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = .command
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = NSApp
        menu.addItem(quit)
        web.update(WebSnapshot(
            agents: agents,
            summaries: summaries,
            hosts: agents.reduce(into: [:]) { hosts, agent in
                hosts[WebPage.key(of: agent)] = agent.pid.flatMap { hostApp(of: Int32($0)) }?.localizedName
            },
            usages: usages,
            updated: lastUpdated
        ), binary: binary)
        web.startIfNeeded()
    }

    @discardableResult
    private func addLabel(_ title: String) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        menu.addItem(row)
        return row
    }

    /// Brings the session's own window or tab forward when the host app allows it; otherwise just the app.
    private func open(_ agent: Agent, in host: NSRunningApplication) {
        let bundleId = host.bundleIdentifier
        let bundleURL = host.bundleURL
        let pid = agent.pid.map(Int32.init)
        let cwd = agent.cwd
        queue.async {
            switch bundleId {
            case "com.cmuxterm.app":
                if let pid, let surface = ProcessTree.environment(of: pid)?["CMUX_SURFACE_ID"], let bundleURL {
                    _ = Cmux.focus(surface: surface, cli: bundleURL.appendingPathComponent("Contents/Resources/bin/cmux"))
                }
            case "com.microsoft.VSCode":
                if let cwd, let bundleURL,
                   let storage = try? Data(contentsOf: VSCodeWindows.storage),
                   let folder = VSCodeWindows.folder(containing: cwd, in: VSCodeWindows.folders(fromStorage: storage)) {
                    // Opening a folder that is already open focuses its window instead of making a new one.
                    NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: bundleURL, configuration: NSWorkspace.OpenConfiguration())
                }
            default:
                break
            }
            DispatchQueue.main.async { host.activate() }
        }
    }

    private func hostApp(of pid: Int32) -> NSRunningApplication? {
        let host = ProcessTree.firstAncestor(of: pid) {
            NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular
        }
        return host.flatMap(NSRunningApplication.init(processIdentifier:))
    }

    private func color(_ activity: Activity) -> NSColor {
        switch activity {
        case .waiting: .systemBlue
        case .working: .systemGreen
        case .idle: .systemGray
        }
    }

    private func showIcon(_ color: NSColor) {
        guard color != iconColor else { return }
        let previous = iconColor
        iconColor = color
        pulse?.invalidate()
        pulse = nil
        guard let previous, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dot = StatusDot.image(color, canvas: iconCanvas)
            drawIcon()
            return
        }
        let start = Date()
        let duration: TimeInterval = 1.6
        let canvas = iconCanvas
        // A scheduled timer fires on the main run loop.
        pulse = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = min(1, Date().timeIntervalSince(start) / duration)
                self.dot = StatusDot.pulse(from: previous, to: color, progress: progress, canvas: canvas)
                self.drawIcon()
                if progress >= 1 {
                    self.pulse?.invalidate()
                    self.pulse = nil
                }
            }
        }
    }

    private func showWarning(_ color: NSColor?) {
        guard color != warningColor else { return }
        warningColor = color
        blink?.invalidate()
        blink = nil
        drawIcon()
        guard color != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        blink = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawIcon() }
        }
    }

    private func drawIcon() {
        guard let dot else { return }
        let tint = warningColor.map { color -> NSColor in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return color.withAlphaComponent(0.7) }
            let period: TimeInterval = 1.6
            let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            return color.withAlphaComponent(0.85 * (0.5 - 0.5 * cos(2 * .pi * phase)))
        }
        item.button?.image = StatusDot.pill(dot, tint: tint)
    }
}
