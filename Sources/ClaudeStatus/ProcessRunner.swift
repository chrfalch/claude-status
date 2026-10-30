import Foundation
import ClaudeStatusCore

func resolveBinary() throws -> String {
    let files = FileManager.default
    let home = files.homeDirectoryForCurrentUser.path
    return try BinaryResolver.resolve(
        override: ProcessInfo.processInfo.environment["CLAUDE_BIN"],
        candidates: ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"],
        isExecutable: { files.isExecutableFile(atPath: $0) },
        shellLookup: {
            let data = try ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lic", "command -v claude"], timeout: 15)
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? ""
        }
    )
}
