import Foundation

/// Serializes local dispatch and journals intent before calling an adapter.
/// A thrown transport error means unknown acceptance, never permission to retry.
public actor ConversationCoordinator {
    private let database: ContinuityDatabase
    private var dispatching: Set<UUID> = []
    public init(database: ContinuityDatabase) { self.database = database }

    public func send(_ proposed: Delivery, endpoint: NativeEndpoint, adapter: any DesktopSurfaceAdapter) async throws -> Delivery {
        guard proposed.endpointID == endpoint.id else { throw ShastraError.invalidResponse("Wrong endpoint") }
        let delivery = try database.enqueue(proposed)
        guard delivery.state == .queued else { return delivery }
        guard try !database.unresolvedDeliveries().contains(where: { $0.endpointID == endpoint.id }) else {
            throw ShastraError.unsupported("Reconcile the previous uncertain delivery before sending another prompt")
        }
        guard dispatching.insert(endpoint.id).inserted else {
            throw ShastraError.unsupported("Another delivery is inspecting or dispatching to this endpoint")
        }
        defer { dispatching.remove(endpoint.id) }
        // Inspection is read-only; a failed gate leaves the operation queued and sends nothing.
        let binding = try await adapter.inspectBinding(endpoint: endpoint)
        guard binding.endpoint.id == endpoint.id else { throw ShastraError.invalidResponse("Adapter bound a different endpoint") }
        try binding.requireSend(expectedRevision: proposed.expectedRevision)
        let pending = try database.transition(delivery.id, to: .dispatching)
        do {
            return try record(await adapter.send(pending, binding: binding), id: pending.id)
        } catch {
            return try database.transition(pending.id, to: .unknown, detail: "Transport ended without confirmed acceptance")
        }
    }

    public func reconcile(_ id: UUID, adapter: any DesktopSurfaceAdapter) async throws -> Delivery {
        guard let delivery = try database.delivery(id) else { throw ShastraError.invalidResponse("Unknown operation") }
        guard delivery.state == .unknown else { return delivery }
        switch try await adapter.reconcile(delivery) {
        case .unknown: return delivery
        case .accepted(let receipt): return try database.transition(id, to: .accepted, receipt: receipt)
        case .notAccepted(let receipt): return try database.transition(id, to: .notAccepted, receipt: receipt)
        }
    }

    private func record(_ outcome: NativeSendOutcome, id: UUID) throws -> Delivery {
        switch outcome {
        case .accepted(let receipt): try database.transition(id, to: .accepted, receipt: receipt)
        case .notAccepted(let receipt): try database.transition(id, to: .notAccepted, receipt: receipt)
        case .unknown(let detail): try database.transition(id, to: .unknown, detail: detail)
        }
    }
}
