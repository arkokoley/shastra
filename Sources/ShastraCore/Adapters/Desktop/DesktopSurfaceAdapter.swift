import Foundation

public enum DesktopCapability: String, Codable, Sendable, CaseIterable {
    case readHistory, observeExternalTurns, openExactThread, sendExistingThread, createNativeThread
    case wakeIdleThread, steerActiveTurn, cancel, approvals, isolatedAccounts, appTools, callerBinding
}
public enum CapabilitySupport: String, Codable, Sendable { case verified, documentedUnverified, unsupported, temporarilyUnavailable, unknown }

public struct CapabilityEvidence: Codable, Sendable, Equatable {
    public var capability: DesktopCapability
    public var support: CapabilitySupport
    public var appBuild: String
    public var testRunID: String?
    public var detail: String
    public init(_ capability: DesktopCapability, support: CapabilitySupport, appBuild: String,
                testRunID: String? = nil, detail: String) {
        self.capability = capability; self.support = support; self.appBuild = appBuild
        self.testRunID = testRunID; self.detail = detail
    }
    public func allows(build: String) -> Bool {
        support == .verified && appBuild == build && testRunID?.isEmpty == false
    }
}

public struct DesktopBinding: Sendable {
    public var endpoint: NativeEndpoint
    public var appBuild: String
    public var accountVerified: Bool
    public var workspaceVerified: Bool
    public var nativeThreadVerified: Bool
    public var hasDraft: Bool
    public var isBusy: Bool
    public var sourceRevision: String
    public var capabilities: [CapabilityEvidence]
    public init(endpoint: NativeEndpoint, appBuild: String, accountVerified: Bool, workspaceVerified: Bool,
                nativeThreadVerified: Bool, hasDraft: Bool, isBusy: Bool, sourceRevision: String,
                capabilities: [CapabilityEvidence]) {
        self.endpoint = endpoint; self.appBuild = appBuild; self.accountVerified = accountVerified
        self.workspaceVerified = workspaceVerified; self.nativeThreadVerified = nativeThreadVerified
        self.hasDraft = hasDraft; self.isBusy = isBusy; self.sourceRevision = sourceRevision
        self.capabilities = capabilities
    }
    public func requireSend(expectedRevision: String?) throws {
        guard endpoint.surface.isVerifiedDesktopIdentity, nativeThreadVerified, accountVerified,
              workspaceVerified, endpoint.workingDirectory != nil else {
            throw ShastraError.unsupported("The native thread, account and workspace must be verified before delivery")
        }
        guard !hasDraft else { throw ShastraError.unsupported("A native draft is present; delivery is held to preserve it") }
        guard expectedRevision == sourceRevision else { throw ShastraError.unsupported("Native history changed; refresh before delivery") }
        let required: [DesktopCapability] = [.sendExistingThread, .callerBinding, isBusy ? .steerActiveTurn : .wakeIdleThread]
        guard required.allSatisfy({ operation in capabilities.contains { $0.capability == operation && $0.allows(build: appBuild) } }) else {
            throw ShastraError.unsupported("Desktop delivery has not passed its capability gate for this app build and activity state")
        }
    }
}

public enum NativeSendOutcome: Sendable {
    case accepted(DeliveryReceipt), notAccepted(DeliveryReceipt), unknown(String)
}

/// Separate from AgentSession. A managed subprocess never satisfies this protocol implicitly.
public protocol DesktopSurfaceAdapter: Sendable {
    func inspectBinding(endpoint: NativeEndpoint) async throws -> DesktopBinding
    func send(_ delivery: Delivery, binding: DesktopBinding) async throws -> NativeSendOutcome
    func reconcile(_ delivery: Delivery) async throws -> NativeSendOutcome
    func openNative(_ endpoint: NativeEndpoint) async throws
}
