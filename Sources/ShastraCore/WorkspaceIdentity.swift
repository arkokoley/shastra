import Foundation
import Darwin

public struct WorkspaceIdentity: Equatable, Sendable {
    public let projectID: String
    public let projectPath: String
    public let workspacePath: String
    public let branch: String?
    public let isWorktree: Bool
    public var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    public var workspaceName: String {
        guard isWorktree else { return "Main workspace" }
        let root = URL(fileURLWithPath: workspacePath)
        if root.lastPathComponent == projectName,
           root.pathComponents.contains("worktrees") { return root.deletingLastPathComponent().lastPathComponent }
        return root.lastPathComponent
    }

    /// Git identity is independent of branch names (detached HEAD is valid).
    public var isGit: Bool { projectID != workspacePath }

    public var isAvailable: Bool { FileManager.default.fileExists(atPath: workspacePath) }

    public static func folder(_ path: String) -> Self {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.canonicalFileURL.path
        return Self(projectID: canonical, projectPath: canonical, workspacePath: canonical,
                    branch: nil, isWorktree: false)
    }
}

/// Read Git metadata off the UI thread. A shared common directory identifies a
/// repository across checkouts; matching folder names are never enough to merge it.
public actor WorkspaceIdentityCatalog {
    private let excludedMetadataRoots: [String]

    public init(excludedMetadataRoots: [URL] = []) {
        self.excludedMetadataRoots = excludedMetadataRoots.map { $0.standardizedFileURL.canonicalFileURL.path }
    }

    private func excludesMetadata(_ path: String) -> Bool {
        excludedMetadataRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public func resolve(_ paths: [String]) -> [String: WorkspaceIdentity] {
        var resolved: [String: WorkspaceIdentity] = [:]
        for path in Set(paths) { resolved[path] = locate(path) }
        // Registered worktrees can still identify histories whose folder was removed.
        var registered: [String: WorkspaceIdentity] = [:]
        for projectID in Set(resolved.values.map(\.projectID)) {
            let common = URL(fileURLWithPath: projectID)
            guard !excludesMetadata(common.path) else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(at: common.appending(path: "worktrees"),
                includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                guard let backlink = read(entry.appending(path: "gitdir")), !backlink.isEmpty else { continue }
                let workspace = absolute(backlink, relativeTo: entry).deletingLastPathComponent()
                let main = common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : common
                registered[workspace.path] = identity(common: common, project: main, workspace: workspace, admin: entry)
            }
        }
        for path in paths where resolved[path]?.branch == nil {
            var candidate = URL(fileURLWithPath: path).standardizedFileURL.canonicalFileURL
            while candidate.path != "/" {
                if let known = registered[candidate.path] { resolved[path] = known; break }
                candidate.deleteLastPathComponent()
            }
        }
        // Pruned managed histories retain a tool-specific project path. Use it
        // only when there is one verified repository with that project name.
        let projects = Dictionary(grouping: resolved.values.filter {
            FileManager.default.fileExists(atPath: $0.projectID.appending("/HEAD"))
        }, by: \.projectName)
        for path in paths {
            guard let existing = resolved[path], !existing.isAvailable,
                  existing.projectID == existing.workspacePath,
                  let name = managedProjectName(existing.workspacePath),
                  let candidates = projects[name], Set(candidates.map(\.projectID)).count == 1,
                  let project = candidates.first else { continue }
            resolved[path] = WorkspaceIdentity(projectID: project.projectID, projectPath: project.projectPath,
                workspacePath: existing.workspacePath, branch: nil, isWorktree: true)
        }
        // Offer registered checkouts even when they have no imported chats yet.
        for (path, workspace) in registered where resolved[path] == nil { resolved[path] = workspace }
        return resolved
    }

    private func managedProjectName(_ path: String) -> String? {
        let pieces = URL(fileURLWithPath: path).pathComponents
        for index in pieces.indices where index + 1 < pieces.count && pieces[index + 1] == "worktrees" {
            if pieces[index] == ".codex", index + 3 < pieces.count { return pieces[index + 3] }
            if pieces[index] == ".superset", index + 2 < pieces.count { return pieces[index + 2] }
            if pieces[index] == ".claude", index > 0 { return pieces[index - 1] }
        }
        return nil
    }

    private func managedWorkspaceRoot(_ path: String) -> URL? {
        let pieces = URL(fileURLWithPath: path).pathComponents
        for index in pieces.indices where index + 1 < pieces.count && pieces[index + 1] == "worktrees" {
            let end: Int
            switch pieces[index] {
            case ".codex", ".superset": end = index + 3
            case ".claude": end = index + 2
            default: continue
            }
            guard end < pieces.count else { continue }
            return URL(fileURLWithPath: NSString.path(withComponents: Array(pieces.prefix(end + 1))))
        }
        return nil
    }

    private func locate(_ path: String) -> WorkspaceIdentity {
        let original = URL(fileURLWithPath: path).standardizedFileURL.canonicalFileURL
        guard !excludesMetadata(original.path) else { return .folder(path) }
        var directory = original
        while directory.path != "/" {
            let marker = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let admin: URL
                if isDirectory.boolValue { admin = marker.canonicalFileURL }
                else if let pointer = read(marker), pointer.hasPrefix("gitdir: ") {
                    admin = absolute(String(pointer.dropFirst(8)), relativeTo: directory)
                } else { return .folder(path) }
                let common: URL
                if let pointer = read(admin.appending(path: "commondir")), !pointer.isEmpty {
                    common = absolute(pointer, relativeTo: admin)
                } else { common = admin }
                // Submodule and separate-git-dir metadata have their own identity.
                let project = common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : directory
                if !FileManager.default.fileExists(atPath: original.path),
                   let archived = managedWorkspaceRoot(original.path),
                   archived.path.hasPrefix(project.path + "/.claude/worktrees/") {
                    return WorkspaceIdentity(projectID: common.path, projectPath: project.path,
                        workspacePath: archived.path, branch: nil, isWorktree: true)
                }
                return identity(common: common, project: project, workspace: directory, admin: admin)
            }
            directory.deleteLastPathComponent()
        }
        return .folder(path)
    }

    private func identity(common: URL, project: URL, workspace: URL, admin: URL) -> WorkspaceIdentity {
        guard let head = read(admin.appending(path: "HEAD")),
              head.hasPrefix("ref: ") || (head.count == 40 || head.count == 64) && head.allSatisfy(\.isHexDigit),
              FileManager.default.fileExists(atPath: common.appending(path: "objects").path),
              FileManager.default.fileExists(atPath: common.appending(path: "refs").path) else {
            return .folder(workspace.path)
        }
        let prefix = "ref: refs/heads/"
        let branch = head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : nil
        return WorkspaceIdentity(projectID: common.path, projectPath: project.path,
                                 workspacePath: workspace.path, branch: branch,
                                 isWorktree: common != admin)
    }

    private func read(_ url: URL) -> String? {
        guard !excludesMetadata(url.path) else { return nil }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16_384 else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func absolute(_ path: String, relativeTo base: URL) -> URL {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appending(path: path)
        return url.standardizedFileURL.canonicalFileURL
    }
}

private extension URL {
    /// Resolve the existing ancestor with realpath, retaining any missing suffix.
    /// Foundation may spell /private/var differently for existing and deleted URLs.
    var canonicalFileURL: URL {
        var ancestor = standardizedFileURL
        var suffix: [String] = []
        while true {
            if let physical = realpath(ancestor.path, nil) {
                let root = URL(fileURLWithPath: String(cString: physical))
                free(physical)
                return suffix.reversed().reduce(root) { $0.appending(path: $1) }
            }
            if ancestor.path == "/" { return standardizedFileURL }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
}
