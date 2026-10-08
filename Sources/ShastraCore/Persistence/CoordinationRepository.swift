import Foundation
import GRDB

public extension ContinuityDatabase {
    func loadCoordination() throws -> CoordinationState {
        try queue.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='coordination-v1'") else { return CoordinationState() }
            return try JSONDecoder().decode(CoordinationState.self, from: Data(value.utf8))
        }
    }
    func saveCoordination(_ state: CoordinationState) throws {
        let value = String(decoding: try Self.encode(state), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES('coordination-v1',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [value])
        }
    }
}
