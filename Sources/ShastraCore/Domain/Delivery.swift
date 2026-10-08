import Foundation

public enum DeliveryState: String, Codable, Sendable, CaseIterable {
    case queued, dispatching, accepted, nativeObserved, notAccepted, unknown, cancelled, held, needsInput

    public func permits(_ next: DeliveryState) -> Bool {
        switch self {
        case .queued: [.dispatching, .cancelled, .held, .needsInput].contains(next)
        case .held, .needsInput: [.queued, .cancelled].contains(next)
        case .dispatching: [.accepted, .notAccepted, .unknown].contains(next)
        case .accepted: next == .nativeObserved
        case .unknown: [.accepted, .notAccepted, .nativeObserved].contains(next)
        case .nativeObserved, .notAccepted, .cancelled: false
        }
    }
}

public struct DeliveryReceipt: Codable, Sendable, Equatable {
    public var endpointID: UUID
    public var nativeThreadID: String
    public var nativeTurnID: String?
    public var evidence: String
    public var observedAt: Date
    public init(endpointID: UUID, nativeThreadID: String, nativeTurnID: String? = nil, evidence: String) {
        self.endpointID = endpointID; self.nativeThreadID = nativeThreadID
        self.nativeTurnID = nativeTurnID; self.evidence = evidence; observedAt = .now
    }
}

public struct Delivery: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var principal: String
    public var idempotencyKey: String
    public var endpointID: UUID
    public var expectedRevision: String?
    public var message: String
    public var state: DeliveryState
    public var receipt: DeliveryReceipt?
    public var detail: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), principal: String, idempotencyKey: String, endpointID: UUID,
                expectedRevision: String? = nil, message: String) {
        self.id = id; self.principal = principal; self.idempotencyKey = idempotencyKey
        self.endpointID = endpointID; self.expectedRevision = expectedRevision; self.message = message
        state = .queued; createdAt = .now
    }
}
