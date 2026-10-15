import Foundation
import Testing
@testable import ShastraCore

private func reviewFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-review-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try LocalCommand.git(root.path, ["init"])
    try LocalCommand.git(root.path, ["config", "user.name", "Fixture"]); try LocalCommand.git(root.path, ["config", "user.email", "fixture@example.invalid"])
    try Data((1...35).map { "line \($0)" }.joined(separator: "\n").appending("\n").utf8).write(to: root.appending(path: "file.txt"))
    try LocalCommand.git(root.path, ["add", "."]); try LocalCommand.git(root.path, ["-c", "commit.gpgsign=false", "commit", "-m", "fixture"])
    return root
}
@Test func reviewBaselinePreservesIndexAndSeparatesPreexistingChanges() throws {
    let root = try reviewFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "file.txt")
    let original = try String(contentsOf: file, encoding: .utf8)
    try Data(original.replacingOccurrences(of: "line 1\n", with: "preexisting\n").utf8).write(to: file)
    try LocalCommand.git(root.path, ["add", "file.txt"])
    try Data("before".utf8).write(to: root.appending(path: "untracked.txt"))
    try Data("private".utf8).write(to: root.appending(path: ".env"))
    let indexBefore = try LocalCommand.git(root.path, ["diff", "--cached", "--binary"])
    let nested = root.appending(path: "nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let base = try ChangeReview.baseline(nested.path)
    #expect(try LocalCommand.git(root.path, ["diff", "--cached", "--binary"]) == indexBefore)
    #expect(try ChangeReview.capture(workspace: root.path, scope: .task, base: base).files.isEmpty)
    try Data(original.replacingOccurrences(of: "line 1\n", with: "preexisting\n").replacingOccurrences(of: "line 30\n", with: "task change\n").utf8).write(to: file)
    try Data("after".utf8).write(to: root.appending(path: "untracked.txt"))
    let review = try ChangeReview.capture(workspace: root.path, scope: .task, base: base)
    #expect(Set(review.files.map(\.path)) == ["file.txt", "untracked.txt"])
    let diff = try #require(review.files.first(where: { $0.path == "file.txt" }))
    #expect(diff.diff.contains("+task change")); #expect(!diff.diff.contains("+preexisting"))
    #expect(try LocalCommand.git(root.path, ["diff", "--cached", "--binary"]) == indexBefore)
}
@Test func reviewStagesAndUnstagesOnlySelectedHunkAndRejectsStaleActions() throws {
    let root = try reviewFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appending(path: "file.txt"), original = try String(contentsOf: fileURL, encoding: .utf8)
    let changed = original.replacingOccurrences(of: "line 2\n", with: "first change\n").replacingOccurrences(of: "line 30\n", with: "second change\n")
    try Data(changed.utf8).write(to: fileURL)
    let review = try ChangeReview.capture(workspace: root.path, scope: .working)
    let file = try #require(review.files.first), first = try #require(file.hunks.first)
    #expect(file.hunks.count == 2)
    try ChangeReview.apply(.stage, hunkID: first.id, file: file, snapshot: review)
    let staged = try LocalCommand.gitText(root.path, ["diff", "--cached"])
    #expect(staged.contains("first change")); #expect(!staged.contains("second change"))
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == changed)
    let indexReview = try ChangeReview.capture(workspace: root.path, scope: .staged), stagedFile = try #require(indexReview.files.first)
    try ChangeReview.apply(.unstage, hunkID: try #require(stagedFile.hunks.first).id, file: stagedFile, snapshot: indexReview)
    #expect(try LocalCommand.gitText(root.path, ["diff", "--cached"]).isEmpty)
    let refreshed = try ChangeReview.capture(workspace: root.path, scope: .working), current = try #require(refreshed.files.first)
    try Data((changed + "later edit\n").utf8).write(to: fileURL)
    #expect(throws: (any Error).self) { try ChangeReview.apply(.discard, hunkID: first.id, file: current, snapshot: refreshed) }
    #expect(try String(contentsOf: fileURL, encoding: .utf8).hasSuffix("later edit\n"))
    let final = try ChangeReview.capture(workspace: root.path, scope: .working), finalFile = try #require(final.files.first)
    try ChangeReview.apply(.discard, hunkID: try #require(finalFile.hunks.first).id, file: finalFile, snapshot: final)
    let result = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(!result.contains("first change")); #expect(result.contains("second change"))
}
