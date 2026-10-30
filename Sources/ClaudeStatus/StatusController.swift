import AppKit
import ClaudeStatusCore

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let queue = DispatchQueue(label: "dev.chrfalch.ClaudeStatus.poll", qos: .utility)
    private var timer: Timer?
    private var binary: String?
    private var lastLookupFailure: Date?
    private var refreshing = false
    private var agents: [Agent] = []
    private let summarizer = Summarizer()
    private var summaries: [String: String] = [:]
    private var errorText: String? = "Loading…"
    private var lastUpdated: Date?
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

    func menuWillOpen(_ menu: NSMenu) { refresh(force: true) }

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
                    return live.map { agent in
                        var agent = agent
                        agent.ledgerTitle = agent.cwd.flatMap(Ledger.title(forWorktree:))
                        let sessionActivity = agent.sessionId.flatMap { activity[$0] }
                        agent.lastActivity = sessionActivity?.lastModified
                        agent.runningSubagents = sessionActivity?.runningSubagents ?? 0
                        return agent
                    }
                } catch {
                    throw CommandError(message: error.localizedDescription)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
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

    private func render() {
        menu.removeAllItems()
        if let errorText {
            item.button?.image = dot(color: .systemOrange)
            item.button?.toolTip = errorText
            addLabel(errorText)
        } else {
            let activities = agents.map { $0.resolvedStatus.activity }
            item.button?.image = dot(Activity.aggregate(activities))
            item.button?.toolTip = "\(activities.filter { $0 == .waiting }.count) waiting · \(activities.filter { $0 == .working }.count) working · \(activities.filter { $0 == .idle }.count) idle"
            if agents.isEmpty { addLabel("No agents") }
            else {
                let rows = agents.map { agent in
                    let host = agent.pid.flatMap { hostApp(of: Int32($0)) }
                    return AgentRow(
                        title: agent.menuLabel,
                        summary: agent.sessionId.flatMap { summaries[$0] }.map { Summary.twoLines($0) },
                        color: color(agent.resolvedStatus.activity),
                        runningSubagents: agent.runningSubagents,
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

    private func dot(_ activity: Activity) -> NSImage { dot(color: color(activity)) }

    private func dot(color: NSColor) -> NSImage { StatusDot.image(color, canvas: 16) }
}
