import Foundation

public enum VSCodeWindows {
    public static let storage = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")

    public static func folders(fromStorage data: Data) -> [String] {
        struct Window: Decodable { let folder: String? }
        struct State: Decodable { let lastActiveWindow: Window?; let openedWindows: [Window]? }
        struct Storage: Decodable { let windowsState: State? }
        guard let state = (try? JSONDecoder().decode(Storage.self, from: data))?.windowsState else { return [] }
        var folders: [String] = []
        for window in [state.lastActiveWindow].compactMap({ $0 }) + (state.openedWindows ?? []) {
            guard let folder = window.folder.flatMap(URL.init(string:)), folder.isFileURL, !folders.contains(folder.path) else { continue }
            folders.append(folder.path)
        }
        return folders
    }

    public static func folder(containing path: String, in folders: [String]) -> String? {
        folders
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }
}

public enum Cmux {
    public static func workspaceIds(fromList data: Data) -> [String] {
        struct Workspace: Decodable { let id: String? }
        struct List: Decodable { let workspaces: [Workspace] }
        return (try? JSONDecoder().decode(List.self, from: data))?.workspaces.compactMap(\.id) ?? []
    }

    public static func contains(surface: String, panels data: Data) -> Bool {
        struct Surface: Decodable { let id: String? }
        struct Panels: Decodable { let surfaces: [Surface] }
        return (try? JSONDecoder().decode(Panels.self, from: data))?.surfaces.contains { $0.id == surface } ?? false
    }

    /// Selects the workspace that holds the surface and focuses it. Returns false when the surface was not found.
    public static func focus(surface: String, cli: URL) -> Bool {
        let run = { (arguments: [String]) in try? ProcessRunner.run(cli, arguments: arguments, timeout: 5) }
        guard let list = run(["--json", "--id-format", "uuids", "list-workspaces"]) else { return false }
        for workspace in workspaceIds(fromList: list) {
            guard let panels = run(["--json", "--id-format", "uuids", "list-panels", "--workspace", workspace]),
                  contains(surface: surface, panels: panels) else { continue }
            _ = run(["select-workspace", "--workspace", workspace])
            return run(["focus-panel", "--panel", surface, "--workspace", workspace]) != nil
        }
        return false
    }
}
