import Foundation
import GRDB

private struct CollaborationVersion: Decodable { var revision: Int }

public extension ContinuityDatabase {
    func collaborationSnapshot() throws -> CollaborationSnapshot {
        try queue.read { db in
            var snapshot = CollaborationSnapshot()
            snapshot.projects = try Self.records(ProjectContext.self, kind: "project", in: db)
            snapshot.annotations = try Self.records(ChatAnnotation.self, kind: "annotation", in: db)
            snapshot.reviews = try Self.records(ReviewComment.self, kind: "review", in: db)
            return snapshot
        }
    }
    func projectContext(_ id: String) throws -> ProjectContext {
        try queue.read { db in
            try Self.record(ProjectContext.self, key: Self.key("project", id), in: db) ?? ProjectContext(id: id)
        }
    }
    @discardableResult func saveProjectContext(_ value: ProjectContext) throws -> ProjectContext {
        var next = value; next.revision += 1
        try saveCollaboration(next, kind: "project", id: value.id, expectedRevision: value.revision)
        return next
    }
    @discardableResult func saveAnnotation(_ value: ChatAnnotation) throws -> ChatAnnotation {
        var next = value; next.revision += 1
        try saveCollaboration(next, kind: "annotation", id: value.id.uuidString, expectedRevision: value.revision)
        return next
    }
    @discardableResult func saveReviewComment(_ value: ReviewComment) throws -> ReviewComment {
        var next = value; next.revision += 1
        try saveCollaboration(next, kind: "review", id: value.id.uuidString, expectedRevision: value.revision)
        return next
    }
    private func saveCollaboration<T: Encodable>(_ value: T, kind: String, id: String, expectedRevision: Int) throws {
        try queue.write { db in
            let key = Self.key(kind, id)
            let old = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?", arguments: [key])
            let revision = try old.map { raw -> Int in
                return try JSONDecoder().decode(CollaborationVersion.self, from: Data(raw.utf8)).revision
            } ?? 0
            guard revision == expectedRevision else { throw ShastraError.invalidResponse("This item changed in another window. Reload it before saving.") }
            let data = String(decoding: try Self.encode(value), as: UTF8.self)
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key, data])
        }
    }
    private static func key(_ kind: String, _ id: String) -> String { "collaboration.\(kind)." + StableIdentity.hash(id) }
    private static func record<T: Decodable>(_ type: T.Type, key: String, in db: Database) throws -> T? {
        try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key=?", arguments: [key]).map {
            try JSONDecoder().decode(type, from: Data($0.utf8))
        }
    }
    private static func records<T: Decodable>(_ type: T.Type, kind: String, in db: Database) throws -> [T] {
        try String.fetchAll(db, sql: "SELECT value FROM metadata WHERE key LIKE ? ORDER BY key", arguments: ["collaboration.\(kind).%"]).map {
            try JSONDecoder().decode(type, from: Data($0.utf8))
        }
    }
}
public actor CollaborationStore {
    private let directory: URL
    private var database: ContinuityDatabase?
    public init(directory: URL? = nil) {
        self.directory = directory ?? ServicePaths.directory
    }
    private func repository() throws -> ContinuityDatabase {
        if let database { return database }
        let opened = try ContinuityDatabase(directory: directory); database = opened; return opened
    }
    public func load() throws -> CollaborationSnapshot { try repository().collaborationSnapshot() }
    public func save(_ value: ProjectContext) throws -> ProjectContext { try repository().saveProjectContext(value) }
    public func save(_ value: ChatAnnotation) throws -> ChatAnnotation { try repository().saveAnnotation(value) }
    public func save(_ value: ReviewComment) throws -> ReviewComment { try repository().saveReviewComment(value) }
    public func prompt(_ request: String, workspace: String) async throws -> String {
        let identity = await WorkspaceIdentityCatalog().resolve([workspace])[workspace] ?? .folder(workspace)
        return try repository().projectContext(identity.projectID).applying(to: request)
    }
}
