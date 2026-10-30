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

    /// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, argc arguments, then environment strings.
    public static func environment(of pid: Int32) -> [String: String]? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(1 + Int(argc)) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
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
