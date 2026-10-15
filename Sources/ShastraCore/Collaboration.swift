import Foundation

public struct ProjectContext: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var instructions = ""
    public var references: [String] = []
    public var decisions: [String] = []
    public var revision = 0
    public init(id: String) { self.id = id }
    public var isEmpty: Bool { instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && references.isEmpty && decisions.isEmpty }
    public func applying(to request: String) -> String {
        guard !isEmpty else { return request }
        let files = references.map { "- " + $0 }.joined(separator: "\n")
        let notes = decisions.map { "- " + $0 }.joined(separator: "\n")
        return """
        Project context (revision \(revision), explicitly maintained by the user):
        \(instructions)
        Reference files (read as needed):
        \(files)
        Recorded decisions:
        \(notes)
        End project context.

        Current request:
        \(request)
        """
    }
}

/// UTF-16 offsets match AppKit selections, including emoji and Devanagari text.
/// An anchor never silently attaches a comment to a newer revision of a message.
public struct MessageAnchor: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var entryID: UUID
    public var location: Int
    public var length: Int
    public var quote: String
    public var digest: String
    public init(sourceID: UUID, entry: Entry, range: NSRange) throws {
        let text = entry.text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= text.length, range.length <= text.length - range.location,
              Range(range, in: entry.text) != nil,
              Self.scalarBoundary(range.location, in: entry.text), Self.scalarBoundary(range.location + range.length, in: entry.text) else { throw ShastraError.invalidResponse("Select a nonempty passage from the message") }
        self.sourceID = sourceID; entryID = entry.id; location = range.location; length = range.length
        quote = text.substring(with: range); digest = StableIdentity.hash(entry.text)
    }
    private static func scalarBoundary(_ offset: Int, in text: String) -> Bool {
        let units = Array(text.utf16)
        return offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset])
    }
    public func matches(_ entry: Entry) -> Bool {
        guard entry.id == entryID, StableIdentity.hash(entry.text) == digest else { return false }
        let text = entry.text as NSString
        return location >= 0 && length > 0 && location <= text.length && length <= text.length - location
            && text.substring(with: NSRange(location: location, length: length)) == quote
    }
}
public struct ChatAnnotation: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var projectID: String
    public var anchor: MessageAnchor
    public var comment: String
    public var resolved = false
    public var taskID: UUID?
    public var createdAt = Date.now
    public var revision = 0
    public init(projectID: String, anchor: MessageAnchor, comment: String) {
        self.projectID = projectID; self.anchor = anchor; self.comment = comment
    }
    public static func prompt(_ annotations: [Self]) -> String {
        "Address the following annotated feedback. Report which comments were addressed and any remaining work.\n\n" + annotations.enumerated().map { i, item in
            "[Annotation \(i + 1) · \(item.id)]\nSource: \(item.anchor.sourceID), message: \(item.anchor.entryID)\nQuoted passage:\n\(item.anchor.quote)\nUser comment:\n\(item.comment)"
        }.joined(separator: "\n\n")
    }
}
public struct ForkOrigin: Codable, Sendable {
    public var sourceID: UUID
    public var entryID: UUID
    public var sourceTitle: String
    public var sourceIsTask: Bool
    public var inheritedCount: Int
    public init(sourceID: UUID, entryID: UUID, sourceTitle: String, sourceIsTask: Bool, inheritedCount: Int) {
        self.sourceID = sourceID; self.entryID = entryID; self.sourceTitle = sourceTitle
        self.sourceIsTask = sourceIsTask; self.inheritedCount = inheritedCount
    }
}
public enum ChatFork {
    public static func prefix(_ entries: [Entry], through entryID: UUID) throws -> [Entry] {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { throw ShastraError.invalidResponse("The fork message is no longer available") }
        return entries.prefix(through: index).map { original in
            var copy = Entry(kind: original.kind, text: original.text, createdAt: original.createdAt)
            copy.provenance = .shastra
            return copy
        }
    }
}
public enum FollowupMode: String, CaseIterable, Sendable { case queue = "Queue", parallel = "Run alongside", steer = "Steer current task" }

public struct ReviewComment: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var projectID: String
    public var sourceID: UUID
    public var revisionID: String
    public var path: String
    public var line: Int
    public var quote: String
    public var comment: String
    public var resolved = false
    public var taskID: UUID?
    public var revision = 0
    public init(projectID: String, sourceID: UUID, revisionID: String, path: String, line: Int, quote: String, comment: String) {
        self.projectID = projectID; self.sourceID = sourceID; self.revisionID = revisionID; self.path = path
        self.line = line; self.quote = quote; self.comment = comment
    }
    public var prompt: String {
        "Review feedback for \(path):\(line), review revision \(revisionID).\nSelected diff:\n\(quote)\nUser request: \(comment)\nRe-read the current file before editing; the diff may have changed. Report the fix and verification."
    }
}
public struct CollaborationSnapshot: Sendable {
    public var projects: [ProjectContext] = []
    public var annotations: [ChatAnnotation] = []
    public var reviews: [ReviewComment] = []
    public init() {}
}
