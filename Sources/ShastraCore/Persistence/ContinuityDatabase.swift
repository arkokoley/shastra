import Foundation
import GRDB

/// In-process service repository. The UI never writes vendor databases.
public final class ContinuityDatabase: Sendable {
    let queue: DatabaseQueue
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA busy_timeout = 5000") }
        let path = directory.appending(path: "continuity.sqlite").path
        queue = try DatabaseQueue(path: path, configuration: configuration)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("continuity-v1") { db in
            try db.execute(sql: """
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE conversations (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE endpoints (
                    id TEXT PRIMARY KEY, provider TEXT NOT NULL, surface TEXT NOT NULL,
                    namespace TEXT NOT NULL, native_id TEXT NOT NULL, payload BLOB NOT NULL,
                    UNIQUE(provider, surface, namespace, native_id));
                CREATE TABLE conversation_endpoints (
                    conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    endpoint_id TEXT NOT NULL REFERENCES endpoints(id),
                    PRIMARY KEY(conversation_id, endpoint_id));
                CREATE TABLE entries (
                    id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    endpoint_id TEXT REFERENCES endpoints(id), native_item_id TEXT,
                    sequence INTEGER NOT NULL, text TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX entries_conversation ON entries(conversation_id, sequence);
                CREATE UNIQUE INDEX entries_native_identity ON entries(conversation_id, endpoint_id, native_item_id)
                    WHERE endpoint_id IS NOT NULL AND native_item_id IS NOT NULL;
                CREATE TABLE entry_revisions (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, entry_id TEXT NOT NULL REFERENCES entries(id),
                    payload BLOB NOT NULL, recorded_at DOUBLE NOT NULL);
                CREATE VIRTUAL TABLE entries_fts USING fts5(text, content='entries', content_rowid='rowid');
                CREATE TRIGGER entries_insert AFTER INSERT ON entries BEGIN
                    INSERT INTO entries_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TRIGGER entries_update AFTER UPDATE OF text ON entries BEGIN
                    INSERT INTO entries_fts(entries_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
                    INSERT INTO entries_fts(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TABLE deliveries (
                    id TEXT PRIMARY KEY, principal TEXT NOT NULL, idempotency_key TEXT NOT NULL,
                    endpoint_id TEXT NOT NULL REFERENCES endpoints(id), state TEXT NOT NULL, payload BLOB NOT NULL,
                    UNIQUE(principal, idempotency_key));
                CREATE TABLE delivery_transitions (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, delivery_id TEXT NOT NULL REFERENCES deliveries(id),
                    state TEXT NOT NULL, recorded_at DOUBLE NOT NULL);
                """)
        }
        try migrator.migrate(queue)
        try migrateLegacy()
    }

    private func migrateLegacy() throws {
        let finished = try queue.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key = 'legacy-import'") != nil }
        guard !finished else { return }
        let fm = FileManager.default
        let legacyURL = directory.appending(path: "conversations.json")
        var conversations: [Conversation] = []
        if fm.fileExists(atPath: legacyURL.path) {
            let data = try Data(contentsOf: legacyURL)
            conversations = try JSONDecoder().decode([Conversation].self, from: data)
            // Decode before creating a backup; corrupt JSON must fail visibly rather than become an empty database.
            let backup = directory.appending(path: "MigrationBackup-v1")
            try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for relative in ["conversations.json", "Accounts/accounts.json"] {
                let source = directory.appending(path: relative)
                let destination = backup.appending(path: URL(fileURLWithPath: relative).lastPathComponent)
                if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) {
                    try fm.copyItem(at: source, to: destination)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
            }
        }
        guard Set(conversations.map(\.id)).count == conversations.count else {
            throw ShastraError.invalidResponse("Legacy data contains duplicate conversation identities")
        }
        let original = conversations
        for index in conversations.indices { conversations[index].migrateEndpoints() }
        try queue.write { db in
            // A second opener may have migrated while the backup was being prepared.
            guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'legacy-import'") == nil else { return }
            try Self.persist(conversations, in: db)
            let imported = try Self.load(in: db)
            guard imported.count == original.count else { throw ShastraError.invalidResponse("Migration conversation count mismatch") }
            let lookup = Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0) })
            for conversation in original {
                guard let result = lookup[conversation.id], result.title == conversation.title,
                      result.accountID == conversation.accountID,
                      try Self.encode(result.entries) == Self.encode(conversation.entries) else {
                    throw ShastraError.invalidResponse("Migration verification failed; original JSON is retained")
                }
            }
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES ('legacy-import','1')")
        }
    }

    public func load() throws -> [Conversation] { try queue.read { try Self.load(in: $0) } }
    public func save(_ conversations: [Conversation]) throws {
        try queue.write { try Self.persist(conversations, in: $0) }
    }
    public func export(to url: URL) throws {
        try Self.encode(load()).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func search(_ query: String, limit: Int = 50) throws -> [HistorySearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        guard !words.isEmpty else { return [] }
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.conversation_id, e.payload FROM entries_fts f
                JOIN entries e ON e.rowid=f.rowid WHERE entries_fts MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [words.joined(separator: " AND "), max(1, min(limit, 500))]).map { row in
                let entry = try JSONDecoder().decode(Entry.self, from: row["payload"])
                return HistorySearchResult(conversationID: UUID(uuidString: row["conversation_id"])!, entry: entry)
            }
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func load(in db: Database) throws -> [Conversation] {
        let decoder = JSONDecoder()
        var conversations = try Data.fetchAll(db, sql: "SELECT payload FROM conversations").map {
            try decoder.decode(Conversation.self, from: $0)
        }
        for index in conversations.indices {
            let id = conversations[index].id.uuidString
            conversations[index].entries = try Data.fetchAll(db, sql:
                "SELECT payload FROM entries WHERE conversation_id = ? ORDER BY sequence", arguments: [id])
                .map { try decoder.decode(Entry.self, from: $0) }
            conversations[index].endpoints = try Data.fetchAll(db, sql: """
                SELECT e.payload FROM endpoints e JOIN conversation_endpoints c ON e.id=c.endpoint_id
                WHERE c.conversation_id = ? ORDER BY c.rowid
                """, arguments: [id]).map { try decoder.decode(NativeEndpoint.self, from: $0) }
        }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func persist(_ conversations: [Conversation], in db: Database) throws {
        for var conversation in conversations {
            conversation.migrateEndpoints()
            let id = conversation.id.uuidString
            var metadata = conversation; metadata.entries = []; metadata.endpoints = nil
            let payload = try encode(metadata)
            try db.execute(sql: "INSERT INTO conversations(id,payload) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                           arguments: [id, payload])
            for endpoint in conversation.nativeEndpoints {
                try db.execute(sql: """
                    INSERT INTO endpoints(id,provider,surface,namespace,native_id,payload) VALUES (?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET payload=excluded.payload
                    """, arguments: [endpoint.id.uuidString, endpoint.provider.rawValue, endpoint.surface.rawValue,
                                       endpoint.storeNamespace, endpoint.nativeThreadID, try encode(endpoint)])
                try db.execute(sql: "INSERT OR IGNORE INTO conversation_endpoints VALUES (?,?)", arguments: [id, endpoint.id.uuidString])
            }
            var sequence = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence),0) FROM entries WHERE conversation_id=?", arguments: [id]) ?? 0
            for entry in conversation.entries {
                let entryID = entry.id.uuidString
                let data = try encode(entry)
                if let row = try Row.fetchOne(db, sql: "SELECT conversation_id,payload FROM entries WHERE id=?", arguments: [entryID]) {
                    let owner: String = row["conversation_id"]
                    guard owner == id else { throw ShastraError.invalidResponse("Entry identity belongs to a different conversation") }
                    let old: Data = row["payload"]
                    if old == data { continue }
                    try db.execute(sql: "UPDATE entries SET endpoint_id=?,native_item_id=?,text=?,payload=? WHERE id=?",
                                   arguments: [entry.endpointID?.uuidString, entry.nativeItemID, entry.text, data, entryID])
                } else {
                    sequence += 1
                    try db.execute(sql: "INSERT INTO entries VALUES (?,?,?,?,?,?,?)", arguments:
                        [entryID, id, entry.endpointID?.uuidString, entry.nativeItemID, sequence, entry.text, data])
                }
                try db.execute(sql: "INSERT INTO entry_revisions(entry_id,payload,recorded_at) VALUES (?,?,?)",
                               arguments: [entryID, data, Date.now.timeIntervalSince1970])
            }
        }
    }
}

public struct HistorySearchResult: Sendable, Identifiable {
    public var conversationID: UUID
    public var entry: Entry
    public var id: UUID { entry.id }
}
