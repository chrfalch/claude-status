import Foundation
import Testing
@testable import ClaudeStatusCore

@Test func hostIsFirstAncestorThatIsAnApp() {
    let parents: [Int32: Int32] = [100: 90, 90: 80, 80: 70, 70: 1]
    let host = ProcessTree.firstAncestor(of: 100, parent: { parents[$0] }, where: { $0 == 80 || $0 == 70 })
    #expect(host == 80)
}

@Test func hostSkipsTheSessionItself() {
    let host = ProcessTree.firstAncestor(of: 100, parent: { $0 == 100 ? 90 : nil }, where: { $0 == 100 || $0 == 90 })
    #expect(host == 90)
}

@Test func hostIsNilWithoutAppAncestor() {
    let parents: [Int32: Int32] = [100: 90, 90: 1]
    #expect(ProcessTree.firstAncestor(of: 100, parent: { parents[$0] }, where: { _ in false }) == nil)
}

@Test func hostWalkStopsOnCycle() {
    let host = ProcessTree.firstAncestor(of: 100, parent: { $0 == 100 ? 90 : 100 }, where: { _ in false })
    #expect(host == nil)
}

@Test func realParentOfCurrentProcess() {
    #expect(ProcessTree.parent(of: getpid()) == getppid())
}

@Test func claudeShellCommandIsRecognized() {
    #expect(ProcessTree.isClaudeShellCommand(["/bin/zsh", "-c", "source /Users/me/.claude/shell-snapshots/snapshot-zsh-1-ab.sh 2>/dev/null || true && bun scan.ts"]))
    #expect(!ProcessTree.isClaudeShellCommand(["node", "/Users/me/.npm-global/bin/argent", "mcp"]))
    #expect(!ProcessTree.isClaudeShellCommand([]))
}

@Test func childrenAndArgumentsOfLiveProcess() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { child.terminate() }
    #expect(ProcessTree.children(of: getpid()).contains(child.processIdentifier))
    #expect(ProcessTree.arguments(of: child.processIdentifier) == ["/bin/sleep", "30"])
    #expect(ProcessTree.arguments(of: 999_999) == nil)
}
