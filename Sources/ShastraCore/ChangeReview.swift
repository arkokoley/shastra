import Foundation

public enum ReviewScope: String, CaseIterable, Codable, Sendable { case working = "Unstaged", staged = "Staged", task = "Task changes" }
public struct ReviewHunk: Identifiable, Sendable {
    public var id: String
    public var header: String
    public var text: String
    public var patch: String
    public var line: Int
    public var added: Int
    public var removed: Int
}
public struct ReviewFile: Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var status: String
    public var diff: String
    public var revisionID: String
    public var hunks: [ReviewHunk]
    public var isUntracked: Bool
}
public struct ChangeReviewSnapshot: Sendable {
    public var workspace: String
    public var base: String
    public var scope: ReviewScope
    public var files: [ReviewFile]
    public var capturedAt = Date.now
}
public enum ChangeReview {
    /// A private temporary Git index preserves the user's staged state. The tree is
    /// not a commit and changes no refs; it provides a precise task-start baseline.
    public static func baseline(_ workspace: String) throws -> String {
        let root = try LocalCommand.gitText(workspace, ["rev-parse", "--show-toplevel"])
        let head = try LocalCommand.gitText(root, ["rev-parse", "HEAD"])
        let before = try fingerprint(root)
        let folder = FileManager.default.temporaryDirectory.appending(path: "shastra-review-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["GIT_INDEX_FILE": folder.appending(path: "index").path]
        try LocalCommand.git(root, ["read-tree", head], environment: environment)
        try LocalCommand.git(root, ["add", "-u", "--", "."], environment: environment)
        let names = try LocalCommand.git(root, ["ls-files", "--others", "--exclude-standard", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter(eligible)
        if !names.isEmpty { try LocalCommand.git(root, ["add", "--"] + names, environment: environment) }
        let tree = String(decoding: try LocalCommand.git(root, ["write-tree"], environment: environment), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard before == (try fingerprint(root)), head == (try LocalCommand.gitText(root, ["rev-parse", "HEAD"])) else {
            throw ShastraError.invalidResponse("Workspace changed while capturing the review baseline. Retry once it settles.")
        }
        return tree
    }
    public static func eligible(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name != ".env" && !name.hasPrefix(".env.") && !["auth.json", ".credentials.json"].contains(name) && !name.hasSuffix(".pem") && !name.hasSuffix(".key")
    }
    private static func fingerprint(_ workspace: String) throws -> String {
        let status = try LocalCommand.git(workspace, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let diff = try LocalCommand.git(workspace, ["diff", "HEAD", "--binary", "--no-ext-diff", "--no-textconv"])
        var value = status + diff
        let names = try LocalCommand.git(workspace, ["ls-files", "--others", "--exclude-standard", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter(eligible)
        for name in names {
            let url = URL(fileURLWithPath: workspace).appending(path: name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else { continue }
            value += try Data(contentsOf: url)
        }
        return StableIdentity.hash(value.base64EncodedString())
    }
    public static func capture(workspace: String, scope: ReviewScope, base: String? = nil) throws -> ChangeReviewSnapshot {
        let root = try LocalCommand.gitText(workspace, ["rev-parse", "--show-toplevel"])
        let head = (try? LocalCommand.gitText(root, ["rev-parse", "HEAD"])) ?? ""
        let revision = scope == .task ? (base ?? head) : head
        if scope == .task, !revision.isEmpty {
            guard [40, 64].contains(revision.count), revision.allSatisfy(\.isHexDigit) else { throw ShastraError.invalidResponse("Invalid review baseline") }
            _ = try LocalCommand.git(root, ["cat-file", "-e", revision + "^{tree}"])
        }
        let args: [String]
        if scope == .staged { args = ["--cached"] }
        else if scope == .task, !revision.isEmpty { args = [revision, try baseline(root)] }
        else { args = [] }
        let names = try LocalCommand.git(root, ["diff"] + args + ["--name-only", "-z", "--no-ext-diff", "--no-textconv"])
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [ReviewFile] = []
        for path in names {
            let diff = String(decoding: try LocalCommand.git(root, ["diff"] + args + ["--no-ext-diff", "--no-textconv", "--no-color", "--", path]), as: UTF8.self)
            files.append(file(path: path, status: scope == .staged ? "Staged" : "Changed", diff: diff, base: revision, untracked: false))
        }
        if scope == .working {
            let untracked = try LocalCommand.git(root, ["ls-files", "--others", "--exclude-standard", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter(eligible)
            for path in untracked where !names.contains(path) {
                // A file can be untracked in Git's real index but present in the
                // task-start tree. Compare against that tree before calling it new.
                if scope == .task, !revision.isEmpty,
                   (try? LocalCommand.git(root, ["cat-file", "-e", revision + ":" + path])) != nil { continue }
                let url = URL(fileURLWithPath: root).appending(path: path)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let text = size <= 2_000_000 ? (try? String(contentsOf: url, encoding: .utf8)) : nil
                let diff = text.map { "New file: \(path)\n" + $0 } ?? "Binary or large file. Open it in Preview."
                files.append(file(path: path, status: "Untracked", diff: diff, base: revision, untracked: true))
            }
        }
        return .init(workspace: root, base: revision, scope: scope, files: files.sorted { $0.path < $1.path })
    }
    private static func file(path: String, status: String, diff: String, base: String, untracked: Bool) -> ReviewFile {
        .init(path: path, status: status, diff: diff, revisionID: StableIdentity.hash(base + "\n" + path + "\n" + diff), hunks: hunks(diff), isUntracked: untracked)
    }
    public static func hunks(_ diff: String) -> [ReviewHunk] {
        let lines = diff.components(separatedBy: "\n")
        var preamble: [String] = [], current: [String] = [], result: [ReviewHunk] = []
        func finish() {
            guard let header = current.first else { return }
            let number = header.split(separator: "+").dropFirst().first?.split(separator: ",").first?.split(separator: " ").first.flatMap { Int($0) } ?? 1
            let text = current.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
            result.append(.init(id: StableIdentity.hash(text), header: header, text: text,
                patch: preamble.joined(separator: "\n") + "\n" + text, line: number,
                added: current.filter { $0.hasPrefix("+") }.count, removed: current.filter { $0.hasPrefix("-") }.count))
        }
        for line in lines {
            if line.hasPrefix("@@ ") { finish(); current = [line] }
            else if current.isEmpty { preamble.append(line) }
            else { current.append(line) }
        }
        finish(); return result
    }
    public enum HunkAction: Sendable { case stage, unstage, discard }
    /// Every mutation is tied to the exact file revision shown to the reviewer.
    public static func apply(_ action: HunkAction, hunkID: String, file: ReviewFile, snapshot: ChangeReviewSnapshot) throws {
        guard snapshot.scope != .task, !file.isUntracked, !file.diff.contains("rename from "),
              let current = try capture(workspace: snapshot.workspace, scope: snapshot.scope).files.first(where: { $0.path == file.path }), current.revisionID == file.revisionID,
              let hunk = current.hunks.first(where: { $0.id == hunkID }) else { throw ShastraError.invalidResponse("This diff changed. Refresh before applying a review action.") }
        guard (action == .stage || action == .discard) && snapshot.scope == .working || action == .unstage && snapshot.scope == .staged else {
            throw ShastraError.invalidResponse("This action does not apply to the selected review scope")
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "shastra-hunk-\(UUID()).patch")
        try Data(hunk.patch.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        var args = ["apply", "--whitespace=nowarn"]
        if action != .discard { args.append("--cached") }
        if action != .stage { args.append("--reverse") }
        try LocalCommand.git(snapshot.workspace, args + ["--check", url.path])
        // Recheck after validation, before Git takes its own index lock.
        guard try capture(workspace: snapshot.workspace, scope: snapshot.scope).files.first(where: { $0.path == file.path })?.revisionID == file.revisionID else { throw ShastraError.invalidResponse("The file changed during review") }
        try LocalCommand.git(snapshot.workspace, args + [url.path])
    }
}
