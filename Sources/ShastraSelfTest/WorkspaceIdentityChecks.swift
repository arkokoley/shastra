import Foundation
import ShastraCore

func verifyWorkspaceIdentities() async throws {
    let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "shastra-workspace-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: fixture) }
    let main = fixture.appending(path: "first/Shared")
    let other = fixture.appending(path: "second/Shared")
    let unique = fixture.appending(path: "third/Unique")
    let pruned = fixture.appending(path: ".codex/worktrees/old-id/Unique")
    let ambiguous = fixture.appending(path: ".codex/worktrees/old-id/Shared")
    let claudePruned = main.appending(path: ".claude/worktrees/old-worker/Sources")
    let unrelated = fixture.appending(path: "unrelated/Unique")
    let worktree = fixture.appending(path: "external/feature-tree")
    let detached = fixture.appending(path: "external/detached-tree")
    let removed = fixture.appending(path: "external/removed-tree")
    let nested = worktree.appending(path: "Sources/Nested")
    let alias = fixture.appending(path: "linked-checkout")
    for repo in [main, other, unique] {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main", repo.path])
        try git(["-C", repo.path, "-c", "user.name=Shastra Test", "-c", "user.email=shastra-test@example.invalid",
                 "commit", "--allow-empty", "-m", "Fixture"])
    }
    try git(["-C", main.path, "worktree", "add", "-b", "feature/sidebar", worktree.path])
    try git(["-C", main.path, "worktree", "add", "--detach", detached.path])
    try git(["-C", main.path, "worktree", "add", "-b", "old-chat", removed.path])
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: worktree)
    try FileManager.default.removeItem(at: removed)
    let catalog = WorkspaceIdentityCatalog()
    let result = await catalog.resolve([main.path, other.path, worktree.path, nested.path, detached.path, removed.path, alias.path, unique.path, pruned.path, ambiguous.path, unrelated.path, claudePruned.path])
    let primary = result[main.path]!
    precondition(primary.projectID == result[worktree.path]!.projectID, "Linked worktree must join the main repository")
    precondition(primary.projectID != result[other.path]!.projectID, "Same folder name must not merge unrelated repositories")
    precondition(primary.projectID == result[detached.path]!.projectID, "Detached worktrees must remain grouped")
    precondition(result[nested.path]!.workspacePath == result[worktree.path]!.workspacePath, "Subfolders must resolve to their checkout")
    precondition(result[alias.path]!.workspacePath == result[worktree.path]!.workspacePath, "Symlink aliases must resolve to the same checkout")
    guard primary.projectID == result[removed.path]!.projectID else {
        throw ShastraError.invalidResponse("Missing checkout resolved to \(result[removed.path]!) instead of \(primary.projectID)")
    }
    precondition(result[claudePruned.path]!.projectID == primary.projectID && result[claudePruned.path]!.isWorktree,
                 "Pruned Claude worktrees must stay nested, rather than joining the main checkout")
    precondition(result[pruned.path]!.projectID == result[unique.path]!.projectID, "Pruned managed worktree should join its unique project")
    precondition(result[ambiguous.path]!.projectID != primary.projectID, "Ambiguous managed names must not choose a repository")
    precondition(result[unrelated.path]!.projectID != result[unique.path]!.projectID, "Unstructured missing folder names must not merge")
    precondition(result[worktree.path]!.branch == "feature/sidebar")
    precondition(!primary.isWorktree && result[worktree.path]!.isWorktree)
    let excludedCatalog = WorkspaceIdentityCatalog(excludedMetadataRoots: [fixture.appending(path: "first")])
    let excluded = await excludedCatalog.resolve([main.path, other.path])
    guard excluded[main.path] == WorkspaceIdentity.folder(main.path) else {
        throw ShastraError.invalidResponse("Excluded metadata resolved as \(String(describing: excluded[main.path])) instead of folder \(WorkspaceIdentity.folder(main.path))")
    }
    precondition(excluded[other.path]?.projectID == result[other.path]?.projectID)
    print("Workspace identity checks passed: linked/detached worktrees, nested paths, symlinks, missing folders, distinct repositories")
}

private func git(_ arguments: [String]) throws {
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
