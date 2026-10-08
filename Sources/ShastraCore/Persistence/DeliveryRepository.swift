import Foundation
import GRDB

public extension ContinuityDatabase {
    /// Repeating an operation key returns the original result. Reusing it for different work fails.
    func enqueue(_ delivery: Delivery) throws -> Delivery {
        try queue.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM deliveries WHERE principal=? AND idempotency_key=?",
                                           arguments: [delivery.principal, delivery.idempotencyKey]) {
                let previous = try JSONDecoder().decode(Delivery.self, from: data)
                guard previous.endpointID == delivery.endpointID, previous.message == delivery.message,
                      previous.expectedRevision == delivery.expectedRevision else {
                    throw ShastraError.invalidResponse("Operation key was already used for different work")
                }
                return previous
            }
            guard delivery.state == .queued, delivery.receipt == nil else {
                throw ShastraError.invalidResponse("A new delivery must start queued without a receipt")
            }
            try db.execute(sql: "INSERT INTO deliveries VALUES (?,?,?,?,?,?)", arguments:
                [delivery.id.uuidString, delivery.principal, delivery.idempotencyKey, delivery.endpointID.uuidString,
                 delivery.state.rawValue, try Self.encode(delivery)])
            return delivery
        }
    }

    func delivery(_ id: UUID) throws -> Delivery? {
        try queue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM deliveries WHERE id=?", arguments: [id.uuidString])
                .map { try JSONDecoder().decode(Delivery.self, from: $0) }
        }
    }

    func transition(_ id: UUID, to state: DeliveryState, receipt: DeliveryReceipt? = nil, detail: String? = nil) throws -> Delivery {
        try queue.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM deliveries WHERE id=?", arguments: [id.uuidString]) else {
                throw ShastraError.invalidResponse("Unknown delivery")
            }
            var delivery = try JSONDecoder().decode(Delivery.self, from: data)
            guard delivery.state.permits(state) else {
                throw ShastraError.invalidResponse("Invalid delivery transition: \(delivery.state.rawValue) → \(state.rawValue)")
            }
            if [.accepted, .nativeObserved, .notAccepted].contains(state) {
                // A definitely-not-accepted reconciliation also requires evidence. A timeout isn't evidence.
                guard let receipt, receipt.endpointID == delivery.endpointID, !receipt.evidence.isEmpty,
                      let endpointData = try Data.fetchOne(db, sql: "SELECT payload FROM endpoints WHERE id=?", arguments: [delivery.endpointID.uuidString]),
                      try JSONDecoder().decode(NativeEndpoint.self, from: endpointData).nativeThreadID == receipt.nativeThreadID else {
                    throw ShastraError.invalidResponse("Delivery requires evidence for the exact native endpoint")
                }
                delivery.receipt = receipt
            }
            delivery.state = state; delivery.detail = detail
            try db.execute(sql: "UPDATE deliveries SET state=?,payload=? WHERE id=?",
                           arguments: [state.rawValue, try Self.encode(delivery), id.uuidString])
            try db.execute(sql: "INSERT INTO delivery_transitions(delivery_id,state,recorded_at) VALUES (?,?,?)",
                           arguments: [id.uuidString, state.rawValue, Date.now.timeIntervalSince1970])
            return delivery
        }
    }

    /// Must be called once by the service owner at startup, never by an arbitrary reader.
    /// No queued/unknown operation is automatically replayed.
    func recoverDispatches() throws -> [Delivery] {
        try queue.write { db in
            let records = try Data.fetchAll(db, sql: "SELECT payload FROM deliveries WHERE state='dispatching'")
            return try records.map { data in
                var delivery = try JSONDecoder().decode(Delivery.self, from: data)
                delivery.state = .unknown
                delivery.detail = "Service stopped during dispatch. Reconcile native acceptance before retrying."
                try db.execute(sql: "UPDATE deliveries SET state=?,payload=? WHERE id=?",
                               arguments: [delivery.state.rawValue, try Self.encode(delivery), delivery.id.uuidString])
                try db.execute(sql: "INSERT INTO delivery_transitions(delivery_id,state,recorded_at) VALUES (?,?,?)",
                               arguments: [delivery.id.uuidString, delivery.state.rawValue, Date.now.timeIntervalSince1970])
                return delivery
            }
        }
    }

    func unresolvedDeliveries() throws -> [Delivery] {
        try queue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM deliveries WHERE state IN ('dispatching','unknown')")
                .map { try JSONDecoder().decode(Delivery.self, from: $0) }
        }
    }
}
