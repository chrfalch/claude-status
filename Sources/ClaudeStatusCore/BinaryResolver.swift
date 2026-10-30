import Foundation

public enum BinaryResolver {
    public static func resolve(
        override: String?, candidates: [String],
        isExecutable: (String) -> Bool, shellLookup: () throws -> String
    ) throws -> String {
        if let override, isExecutable(override) { return override }
        for path in candidates where isExecutable(path) { return path }
        do {
            let path = try shellLookup()
            if !path.isEmpty, isExecutable(path) { return path }
        } catch {
            let context = override.map { " CLAUDE_BIN is not executable: \($0)." } ?? ""
            throw CommandError(message: "Claude binary not found.\(context) Set CLAUDE_BIN. \(error.localizedDescription)")
        }
        let context = override.map { " CLAUDE_BIN is not executable: \($0)." } ?? ""
        throw CommandError(message: "Claude binary not found.\(context) Set CLAUDE_BIN.")
    }
}
