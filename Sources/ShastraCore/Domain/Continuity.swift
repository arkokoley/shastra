import Foundation
import CryptoKit

public enum NativeSurface: String, Codable, Sendable, CaseIterable {
    case codexLocal, cursorEditor, cursorCLI, claudeLocal, grokLocal, managedRuntime
    case codexDesktop, cursorIDE, cursorAgentsWindow, claudeDesktopCode

    public var isVerifiedDesktopIdentity: Bool {
        [.codexDesktop, .cursorIDE, .cursorAgentsWindow, .claudeDesktopCode].contains(self)
    }
}

public enum HistoryCompleteness: String, Codable, Sendable { case unknown, partial, complete }
public enum EndpointOwnership: String, Codable, Sendable { case observed, managed, needsReconciliation }

/// Native identity is independent of the logical conversation and survives agent changes.
public struct NativeEndpoint: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var provider: Provider
    public var surface: NativeSurface
    public var storeNamespace: String
    public var nativeThreadID: String
    public var sourceIdentity: String?
    public var locator: String?
    public var accountID: UUID?
    public var workingDirectory: String?
    public var ownership: EndpointOwnership
    public var completeness: HistoryCompleteness
    public var sourceRevision: String?
    public var sourceUpdatedAt: Date?

    public init(provider: Provider, surface: NativeSurface, storeNamespace: String, nativeThreadID: String,
                sourceIdentity: String? = nil, locator: String? = nil, accountID: UUID? = nil,
                workingDirectory: String? = nil, ownership: EndpointOwnership = .observed) {
        self.provider = provider; self.surface = surface; self.storeNamespace = storeNamespace
        self.nativeThreadID = nativeThreadID; self.sourceIdentity = sourceIdentity; self.locator = locator
        self.accountID = accountID; self.workingDirectory = workingDirectory; self.ownership = ownership
        completeness = .unknown
        id = StableIdentity.uuid([provider.rawValue, surface.rawValue, storeNamespace, nativeThreadID])
    }
}

public enum StableIdentity {
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func uuid(_ components: [String]) -> UUID {
        // Length framing avoids collisions between components containing separators.
        let digest = hash(components.map { "\($0.utf8.count):\($0)" }.joined())
        let a = Array(digest.prefix(32))
        return UUID(uuidString: "\(String(a[0..<8]))-\(String(a[8..<12]))-\(String(a[12..<16]))-\(String(a[16..<20]))-\(String(a[20..<32]))")!
    }
}

public extension Conversation {
    var nativeEndpoints: [NativeEndpoint] { endpoints ?? [] }
    var activeEndpoint: NativeEndpoint? { nativeEndpoints.first { $0.id == activeEndpointID } }
    var sourceEndpoint: NativeEndpoint? { nativeEndpoints.first { $0.sourceIdentity == sourceIdentity && sourceIdentity != nil } }
    /// Resume the active native identity. A provider change is an explicit new session.
    var resumeEndpoint: NativeEndpoint? {
        guard let endpoint = activeEndpoint, endpoint.provider == provider,
              !endpoint.nativeThreadID.isEmpty else { return nil }
        return endpoint
    }
    var nativeResumeUnavailableReason: String? {
        guard let endpoint = resumeEndpoint,
              [.cursorEditor, .cursorIDE, .cursorAgentsWindow].contains(endpoint.surface) else { return nil }
        return "Cursor desktop chats use a separate store from Cursor CLI. Continue this thread in Cursor; Shastra will keep reading its history."
    }
    var continuityLabel: String {
        if nativeResumeUnavailableReason != nil { return "Cursor desktop thread · Continue in Cursor" }
        if resumeEndpoint != nil { return "Same provider thread" }
        if !nativeEndpoints.isEmpty { return "New session with another provider" }
        return "Managed runtime"
    }

    func validateResumeAccount() throws {
        if let reason = nativeResumeUnavailableReason { throw ShastraError.unsupported(reason) }
        if let endpoint = resumeEndpoint, endpoint.accountID != accountID {
            throw ShastraError.invalidResponse("This thread belongs to a different sign-in. Restore its original account to continue in the same thread.")
        }
    }

    mutating func recordResumedEndpoint(nativeID: String) throws -> NativeEndpoint {
        guard let endpoint = resumeEndpoint, endpoint.nativeThreadID == nativeID,
              let index = endpoints?.firstIndex(where: { $0.id == endpoint.id }) else {
            throw ShastraError.invalidResponse("The provider returned a different thread. No message was sent.")
        }
        endpoints?[index].ownership = .managed
        vendorSessionID = nativeID
        managedContinuationEnabled = true
        return endpoints![index]
    }

    mutating func migrateEndpoints() {
        guard endpoints == nil else { return }
        endpoints = []
        if let sourceIdentity {
            let nativeID = sourceIdentity.split(separator: ":", maxSplits: 1).last.map(String.init) ?? vendorSessionID ?? ""
            let surface: NativeSurface = switch sourceKind {
            case "Cursor Editor": .cursorEditor
            case "Cursor CLI": .cursorCLI
            case "Claude Code": .claudeLocal
            case "Grok": .grokLocal
            default: .codexLocal
            }
            let namespace = sourceLocator.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
                ?? "local-default:\(provider.rawValue)"
            let endpoint = NativeEndpoint(provider: provider, surface: surface, storeNamespace: namespace,
                nativeThreadID: nativeID, sourceIdentity: sourceIdentity, locator: sourceLocator,
                workingDirectory: workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path ? nil : workingDirectory)
            endpoints?.append(endpoint)
            activeEndpointID = endpoint.id
        }
        if let vendorSessionID, vendorSessionID != sourceEndpoint?.nativeThreadID {
            let endpoint = NativeEndpoint(provider: provider, surface: .managedRuntime,
                storeNamespace: profileDirectory ?? accountID?.uuidString ?? "managed-default:\(provider.rawValue)",
                nativeThreadID: vendorSessionID, accountID: accountID, workingDirectory: workingDirectory,
                ownership: .needsReconciliation)
            endpoints?.append(endpoint)
            activeEndpointID = endpoint.id
        }
    }

    mutating func attachManagedEndpoint(nativeID: String) -> NativeEndpoint {
        migrateEndpoints()
        let endpoint = NativeEndpoint(provider: provider, surface: .managedRuntime,
            storeNamespace: profileDirectory ?? accountID?.uuidString ?? "managed-default:\(provider.rawValue)",
            nativeThreadID: nativeID, accountID: accountID, workingDirectory: workingDirectory, ownership: .managed)
        if !nativeEndpoints.contains(where: { $0.id == endpoint.id }) { endpoints?.append(endpoint) }
        activeEndpointID = endpoint.id
        vendorSessionID = nativeID // Compatibility for existing runtime code only; never used for source refresh.
        return endpoint
    }
}

public enum HistoryReconciler {
    /// Never replace another endpoint's events, or discard source events that disappear from a partial read.
    public static func merge(_ incoming: [Entry], endpoint: NativeEndpoint, into existing: [Entry]) -> [Entry] {
        var result = existing
        var positions = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        for (offset, original) in incoming.enumerated() {
            var entry = original
            // Fallback includes position and content, preserving repeated text at distinct source locations.
            let key = original.nativeItemID ?? "fallback:\(offset):\(StableIdentity.hash(original.kind.rawValue + original.text))"
            entry.id = StableIdentity.uuid([endpoint.id.uuidString, key])
            entry.endpointID = endpoint.id
            entry.provenance = .nativeObservation
            entry.nativeItemID = key
            if let index = positions[entry.id] {
                entry.createdAt = result[index].createdAt
                result[index] = entry
            } else {
                positions[entry.id] = result.count
                result.append(entry)
            }
        }
        return result
    }
}
