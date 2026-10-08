import Foundation
import Testing
@testable import ShastraCore

private func workspaceGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ShastraError.invalidResponse(String(decoding: data, as: UTF8.self))
    }
}

@Test func gitWorkspaceSelectionIncludesDetachedAndUnvisitedWorktrees() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-git-picker-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appending(path: "repo")
    let nested = repo.appending(path: "src")
    let linked = root.appending(path: "detached")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try workspaceGit(["init", repo.path])
    try workspaceGit(["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Fixture"])
    try workspaceGit(["-C", repo.path, "worktree", "add", "--detach", linked.path])
    let catalog = WorkspaceIdentityCatalog()
    let result = await catalog.resolve([nested.path])
    let main = try #require(result[nested.path])
    #expect(main.isGit)
    #expect(main.isAvailable)
    #expect(URL(fileURLWithPath: main.workspacePath).lastPathComponent == "repo")
    let worktree = try #require(result.values.first { $0.isWorktree })
    #expect(worktree.isGit)
    #expect(worktree.branch == nil)
    #expect(worktree.isAvailable)
    #expect(worktree.projectID == main.projectID)
    // A deleted checkout can retain its history identity but must not be selectable.
    try FileManager.default.removeItem(at: linked)
    let removed = await catalog.resolve([nested.path, linked.path])
    #expect(removed[linked.path]?.isGit == true)
    #expect(removed[linked.path]?.isAvailable == false)
}

@Test func workspaceSelectionRejectsPlainFoldersAndBrokenGitMarkers() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-nongit-picker-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = root.appending(path: "plain")
    let broken = root.appending(path: "broken")
    let fake = root.appending(path: "fake")
    for folder in [plain, broken, fake.appending(path: ".git")] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try Data("gitdir: /nonexistent/shastra-git-metadata".utf8).write(to: broken.appending(path: ".git"))
    try Data("ref: refs/heads/main".utf8).write(to: fake.appending(path: ".git/HEAD"))
    let catalog = WorkspaceIdentityCatalog()
    let result = await catalog.resolve([plain.path, broken.path, fake.path])
    #expect(result.values.allSatisfy { !$0.isGit })
    // Empty repositories are valid even before they have their first commit.
    try workspaceGit(["init", plain.path])
    let initialized = await catalog.resolve([plain.path])
    #expect(initialized[plain.path]?.isGit == true)
}
