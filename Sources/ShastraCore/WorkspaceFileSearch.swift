import Foundation

public struct WorkspaceFileMatch: Identifiable, Sendable {
    public let url: URL
    public let relativePath: String
    public var id: String { url.path }
}

public enum WorkspaceFileSearch {
    /// Search filenames without following links or reading file contents.
    public static func search(root: URL, query: String, limit: Int = 40) async -> [WorkspaceFileMatch] {
        let task = Task.detached(priority: .utility) {
            scan(root: root, query: query, limit: limit)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func scan(root: URL, query: String, limit: Int) -> [WorkspaceFileMatch] {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            let excluded: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "dist", ".next", "Pods", "DerivedData", ".venv"]
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard limit > 0, !terms.isEmpty, let files = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [WorkspaceFileMatch]() }
            let isHome = root == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
            var visited = 0, matches: [WorkspaceFileMatch] = []
            for case let file as URL in files {
                if Task.isCancelled || visited >= 20_000 { break }
                visited += 1
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { continue }
                if values.isDirectory == true && (excluded.contains(file.lastPathComponent) || (isHome && file.deletingLastPathComponent() == root &&
                    ["Library", "Documents", "Downloads", "Desktop"].contains(file.lastPathComponent))) {
                    files.skipDescendants(); continue
                }
                guard values.isRegularFile == true else { continue }
                let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix(root.path + "/") else { continue }
                let relative = String(path.dropFirst(root.path.count + 1))
                if terms.allSatisfy({ relative.lowercased().contains($0) }) { matches.append(.init(url: file, relativePath: relative)) }
                if matches.count >= limit { break }
            }
            return matches.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
