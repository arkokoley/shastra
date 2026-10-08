import Foundation

public struct CommandResult: Sendable { public var output: Data; public var error: String; public var status: Int32 }
public enum LocalCommand {
    public static func run(_ executable: String, _ arguments: [String], directory: String? = nil,
                           environment: [String: String] = [:]) throws -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        // Files avoid pipe-buffer deadlock when both output streams are large.
        let folder = FileManager.default.temporaryDirectory.appending(path: "shastra-command-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appending(path: "stdout"), err = folder.appending(path: "stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil); FileManager.default.createFile(atPath: err.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return .init(output: try Data(contentsOf: out), error: String(decoding: try Data(contentsOf: err), as: UTF8.self), status: process.terminationStatus)
    }
    @discardableResult public static func git(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Data {
        let result = try run("/usr/bin/git", ["-C", path] + arguments, environment: environment)
        guard result.status == 0 else { throw ShastraError.invalidResponse(result.error.isEmpty ? "Git command failed" : result.error) }
        return result.output
    }
    public static func gitText(_ path: String, _ arguments: [String]) throws -> String {
        String(decoding: try git(path, arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct WorkspaceSnapshot: Codable, Identifiable, Sendable {
    public var id: UUID
    public var source: String
    public var head: String
    public var createdAt: Date
    public var untracked: [String]
    public var excluded: [String]
    public var directory: String
}
public struct ManagedWorkspace: Codable, Identifiable, Sendable {
    public var id: UUID
    public var repository: String
    public var path: String
    public var branch: String
    public var base: String
    public var snapshot: WorkspaceSnapshot
    public var archived: Bool
    public var setupComplete: Bool?
}

public actor WorkspaceManager {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private let fm = FileManager.default

    public func snapshot(_ path: String) throws -> WorkspaceSnapshot {
        let source = try LocalCommand.gitText(path, ["rev-parse", "--show-toplevel"])
        let head = try LocalCommand.gitText(source, ["rev-parse", "--verify", "HEAD"])
        let id = UUID(), folder = directory.appending(path: "snapshots/\(UUID())")
        try fm.createDirectory(at: folder.appending(path: "untracked"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let before = try LocalCommand.git(source, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let staged = try LocalCommand.git(source, ["diff", "--cached", "--binary", "--full-index", "HEAD"])
        let unstaged = try LocalCommand.git(source, ["diff", "--binary", "--full-index"])
        try staged.write(to: folder.appending(path: "staged.patch"), options: .atomic)
        try unstaged.write(to: folder.appending(path: "unstaged.patch"), options: .atomic)
        let names = try LocalCommand.git(source, ["ls-files", "--others", "--exclude-standard", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var included: [String] = [], excluded: [String] = []
        for name in names {
            let basename = URL(fileURLWithPath: name).lastPathComponent
            if basename == ".env" || basename.hasPrefix(".env.") || ["auth.json", ".credentials.json"].contains(basename) || basename.hasSuffix(".pem") || basename.hasSuffix(".key") {
                excluded.append(name); continue
            }
            let target = folder.appending(path: "untracked").appending(path: name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: source).appending(path: name), to: target)
            included.append(name)
        }
        guard before == (try LocalCommand.git(source, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])),
              head == (try LocalCommand.gitText(source, ["rev-parse", "HEAD"])),
              staged == (try LocalCommand.git(source, ["diff", "--cached", "--binary", "--full-index", "HEAD"])),
              unstaged == (try LocalCommand.git(source, ["diff", "--binary", "--full-index"])) else {
            throw ShastraError.invalidResponse("Workspace changed during snapshot; retry after the writer settles")
        }
        for name in included {
            let original = URL(fileURLWithPath: source).appending(path: name)
            let copy = folder.appending(path: "untracked").appending(path: name)
            let attributes = try fm.attributesOfItem(atPath: original.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                guard try fm.destinationOfSymbolicLink(atPath: original.path) == fm.destinationOfSymbolicLink(atPath: copy.path) else { throw ShastraError.invalidResponse("Untracked symlink changed during snapshot") }
            } else {
                guard try Data(contentsOf: original) == Data(contentsOf: copy) else { throw ShastraError.invalidResponse("Untracked file changed during snapshot") }
            }
        }
        let result = WorkspaceSnapshot(id: id, source: source, head: head, createdAt: .now,
                                       untracked: included, excluded: excluded, directory: folder.path)
        try JSONEncoder().encode(result).write(to: folder.appending(path: "manifest.json"), options: .atomic)
        return result
    }

    public func allocate(from source: String, id: UUID = UUID()) throws -> ManagedWorkspace {
        if let existing = try list().first(where: { $0.id == id }) {
            guard existing.setupComplete == true, !existing.archived else { throw ShastraError.invalidResponse("Workspace setup requires inspection; the existing allocation was preserved") }
            return existing
        }
        return try allocate(snapshot: snapshot(source), id: id)
    }

    public func allocate(snapshot: WorkspaceSnapshot, id: UUID = UUID()) throws -> ManagedWorkspace {
        if let existing = try list().first(where: { $0.id == id }) {
            guard existing.setupComplete == true, !existing.archived else { throw ShastraError.invalidResponse("Workspace setup requires inspection") }; return existing
        }
        let repository = try list().first(where: { $0.path == snapshot.source })?.repository ?? snapshot.source
        let path = directory.appending(path: "worktrees/\(id.uuidString)").path
        let branch = "codex/shastra-\(id.uuidString.lowercased().prefix(12))"
        try fm.createDirectory(at: directory.appending(path: "worktrees"), withIntermediateDirectories: true)
        // Register durable intent before creating a worktree. Failed setup remains recoverable.
        var workspace = ManagedWorkspace(id: id, repository: repository, path: path, branch: branch,
                                         base: snapshot.head, snapshot: snapshot, archived: false)
        workspace.setupComplete = false
        try save(workspace)
        try LocalCommand.git(repository, ["worktree", "add", "-b", branch, path, snapshot.head])
        try apply(snapshot, to: path)
        workspace.setupComplete = true; try save(workspace)
        return workspace
    }

    private func apply(_ snapshot: WorkspaceSnapshot, to path: String) throws {
        let folder = URL(fileURLWithPath: snapshot.directory)
        for (file, args) in [("staged.patch", ["apply", "--index", "--binary"]), ("unstaged.patch", ["apply", "--binary"])] {
            let patch = folder.appending(path: file)
            if try Data(contentsOf: patch).isEmpty == false { try LocalCommand.git(path, args + [patch.path]) }
        }
        for name in snapshot.untracked {
            let target = URL(fileURLWithPath: path).appending(path: name)
            guard !fm.fileExists(atPath: target.path) else { throw ShastraError.invalidResponse("Snapshot file already exists: \(name)") }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: folder.appending(path: "untracked").appending(path: name), to: target)
        }
    }

    public func list() throws -> [ManagedWorkspace] {
        let root = directory.appending(path: "registry")
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ManagedWorkspace.self, from: Data(contentsOf: $0)) }
    }
    private func save(_ workspace: ManagedWorkspace) throws {
        let root = directory.appending(path: "registry")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(workspace).write(to: root.appending(path: "\(workspace.id).json"), options: .atomic)
    }
    public func archive(_ id: UUID) throws -> ManagedWorkspace {
        guard var workspace = try list().first(where: { $0.id == id }), !workspace.archived else { throw ShastraError.invalidResponse("Unknown active managed workspace") }
        guard try LocalCommand.git(workspace.path, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]).isEmpty else { throw ShastraError.invalidResponse("Archive paused: ignored files exist in this workspace. Preserve or remove them before archiving.") }
        workspace.snapshot = try snapshot(workspace.path)
        guard workspace.snapshot.excluded.isEmpty else { throw ShastraError.invalidResponse("Archive would omit private untracked files: \(workspace.snapshot.excluded.joined(separator: ", ")). Move them to a safe location first.") }
        try save(workspace)
        try LocalCommand.git(workspace.repository, ["worktree", "remove", "--force", workspace.path])
        workspace.archived = true; try save(workspace); return workspace
    }
    public func restore(_ id: UUID) throws -> ManagedWorkspace {
        guard var workspace = try list().first(where: { $0.id == id }), workspace.archived else { throw ShastraError.invalidResponse("Unknown archived workspace") }
        try LocalCommand.git(workspace.repository, ["worktree", "add", "--detach", workspace.path, workspace.snapshot.head])
        workspace.archived = false; try save(workspace)
        try apply(workspace.snapshot, to: workspace.path)
        return workspace
    }
    public func integrate(_ id: UUID, into destination: String) throws -> String {
        guard let workspace = try list().first(where: { $0.id == id }), !workspace.archived else { throw ShastraError.invalidResponse("Unknown active workspace") }
        guard try LocalCommand.git(workspace.path, ["status", "--porcelain"]).isEmpty else { throw ShastraError.invalidResponse("Commit the worker's changes before integration") }
        guard try LocalCommand.git(destination, ["status", "--porcelain"]).isEmpty else { throw ShastraError.invalidResponse("Commit or preserve destination changes before integration") }
        let sourceCommon = try LocalCommand.gitText(workspace.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard sourceCommon == (try LocalCommand.gitText(destination, ["rev-parse", "--path-format=absolute", "--git-common-dir"])) else { throw ShastraError.invalidResponse("Workspaces belong to different repositories") }
        let head = try LocalCommand.gitText(workspace.path, ["rev-parse", "HEAD"])
        try LocalCommand.git(destination, ["merge", "--no-edit", head])
        return try LocalCommand.gitText(destination, ["rev-parse", "HEAD"])
    }
}
