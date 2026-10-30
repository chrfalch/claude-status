import Darwin

public enum ProcessTree {
    public static func parent(of pid: Int32) -> Int32? {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func environment(of pid: Int32) -> [String: String]? {
        guard let strings = processArguments(of: pid) else { return nil }
        var environment: [String: String] = [:]
        for text in strings.environment {
            guard let equals = text.firstIndex(of: "=") else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    public static func arguments(of pid: Int32) -> [String]? {
        processArguments(of: pid)?.arguments
    }

    /// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, argc arguments, then environment strings.
    private static func processArguments(of pid: Int32) -> (arguments: [String], environment: [String])? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let strings = buffer[MemoryLayout<Int32>.size..<size]
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        let afterPath = strings.dropFirst()
        return (Array(afterPath.prefix(argc)), Array(afterPath.dropFirst(argc)))
    }

    public static func children(of pid: Int32) -> [Int32] {
        children(of: [pid])[pid] ?? []
    }

    /// Reads the process list once for all the parents.
    public static func children(of parents: Set<Int32>) -> [Int32: [Int32]] {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&query, 4, nil, &size, nil, 0) == 0 else { return [:] }
        // Room for processes that start between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&query, 4, &processes, &size, nil, 0) == 0 else { return [:] }
        var children: [Int32: [Int32]] = [:]
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) where parents.contains(process.kp_eproc.e_ppid) {
            children[process.kp_eproc.e_ppid, default: []].append(process.kp_proc.p_pid)
        }
        return children
    }

    /// Claude Code runs each shell command through a wrapper that first loads a saved shell snapshot.
    public static func isClaudeShellCommand(_ arguments: [String]) -> Bool {
        arguments.contains { $0.contains("/.claude/shell-snapshots/snapshot-") }
    }

    public static func firstAncestor(of pid: Int32, parent: (Int32) -> Int32? = parent(of:), where matches: (Int32) -> Bool) -> Int32? {
        var seen: Set<Int32> = [pid]
        var current = pid
        while let next = parent(current), next > 1, seen.insert(next).inserted {
            if matches(next) { return next }
            current = next
        }
        return nil
    }
}
