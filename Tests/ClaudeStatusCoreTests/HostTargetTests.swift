import Foundation
import Testing
@testable import ClaudeStatusCore

@Test func environmentOfCurrentProcess() throws {
    let environment = try #require(ProcessTree.environment(of: getpid()))
    #expect(environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
}

@Test func environmentOfMissingProcessIsNil() {
    #expect(ProcessTree.environment(of: 999_999) == nil)
}

@Test func vscodeWindowIsLongestContainingFolder() {
    let windows = ["/repos/expo/expo", "/repos/expo/expo-cli", "/repos/expo"]
    #expect(VSCodeWindows.folder(containing: "/repos/expo/expo/.claude/worktrees/ruby2ts", in: windows) == "/repos/expo/expo")
    #expect(VSCodeWindows.folder(containing: "/repos/expo/expo", in: windows) == "/repos/expo/expo")
    #expect(VSCodeWindows.folder(containing: "/repos/expo/expo-cli/x", in: windows) == "/repos/expo/expo-cli")
    #expect(VSCodeWindows.folder(containing: "/repos/other", in: windows) == nil)
}

@Test func vscodeWindowFoldersFromStorage() {
    let json = #"""
    {"windowsState":{
      "lastActiveWindow":{"folder":"file:///Users/me/repos/react-native"},
      "openedWindows":[{"folder":"file:///Users/me/Dropbox%20(Personal)/B%C3%B8ker"},{"workspace":{"configPath":"file:///x.code-workspace"}},{"folder":"vscode-remote://ssh/x"}]
    }}
    """#
    #expect(VSCodeWindows.folders(fromStorage: Data(json.utf8)) == ["/Users/me/repos/react-native", "/Users/me/Dropbox (Personal)/Bøker"])
}

@Test func cmuxWorkspaceForSurface() {
    let workspaces = Data(#"{"workspaces":[{"ref":"workspace:1","id":"W1"},{"ref":"workspace:3","id":"W3"}]}"#.utf8)
    let panels: [String: Data] = [
        "W1": Data(#"{"surfaces":[{"id":"S1"}]}"#.utf8),
        "W3": Data(#"{"surfaces":[{"id":"S2"},{"id":"S3"}]}"#.utf8),
    ]
    #expect(Cmux.workspaceIds(fromList: workspaces) == ["W1", "W3"])
    #expect(Cmux.contains(surface: "S3", panels: panels["W3"]!))
    #expect(!Cmux.contains(surface: "S3", panels: panels["W1"]!))
    #expect(!Cmux.contains(surface: "S3", panels: Data("not json".utf8)))
}
