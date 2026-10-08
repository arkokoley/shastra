import Foundation
import CryptoKit
import TOMLDecoder

public enum ConfigValue: Codable, Equatable, Sendable {
    case null, string(String), number(Double), bool(Bool), array([ConfigValue]), object([String: ConfigValue])
    public init(from decoder: any Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode(Double.self) { self = .number(v); return }
            if let v = try? c.decode(Int64.self) { self = .number(Double(v)); return }
        }
        if let v = try? [ConfigValue](from: decoder) { self = .array(v); return }
        self = .object(try [String: ConfigValue](from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    var containsNull: Bool {
        switch self { case .null: true; case .array(let values): values.contains(where: \.containsNull); case .object(let values): values.values.contains(where: \.containsNull); default: false }
    }
    var text: String? { if case .string(let v) = self { return v }; return nil }
    var toml: String {
        switch self {
        case .null: return "\"\"" // Null MCP values are rejected before TOML conversion.
        case .string(let v):
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try! encoder.encode(v), as: UTF8.self)
        case .number(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .array(let v): return "[" + v.map(\.toml).joined(separator: ", ") + "]"
        case .object(let v): return "{ " + v.keys.sorted().map { ConfigValue.string($0).toml + " = " + v[$0]!.toml }.joined(separator: ", ") + " }"
        }
    }
}
public struct RuntimeLocation: Sendable, Equatable {
    public let provider: Provider
    public let base: URL
    public let project: Bool
    public init(provider: Provider, base: URL, project: Bool = false) { self.provider = provider; self.base = base; self.project = project }
    public var skills: URL { base.appending(path: provider == .codex ? ".agents/skills" : ".\(provider.rawValue)/skills") }
    public var config: URL {
        switch provider {
        case .claude: base.appending(path: project ? ".mcp.json" : ".claude.json")
        case .cursor: base.appending(path: ".cursor/mcp.json")
        default: base.appending(path: ".\(provider.rawValue)/config.toml")
        }
    }
    var isTOML: Bool { provider == .codex || provider == .grok }
}
public struct RuntimeLibraryItem: Identifiable, Sendable {
    public enum Kind: String, Sendable { case skill = "Skill", tool = "MCP server" }
    public let id: String
    public let name: String
    public let kind: Kind
    public let source: URL
    public let fields: [String: ConfigValue]?
    public let detail: String
}
public struct RuntimeCopyPlan: Sendable {
    public let item: RuntimeLibraryItem
    public let destination: URL
    public let destinationName: String
    public let sourceDigest: String
    public let destinationDigest: String
    public let preview: String
    public let containsCredentials: Bool
    fileprivate let data: Data?
    fileprivate let files: [String: Data]
}
public struct RuntimeCopyReceipt: Sendable {
    public let destination: URL
    public let backup: URL?
    public let writtenDigest: String
    public let isDirectory: Bool
}
public actor RuntimeLibrary {
    private let fm = FileManager.default
    public init() {}
    public func inventory(_ location: RuntimeLocation) throws -> [RuntimeLibraryItem] {
        var items: [RuntimeLibraryItem] = []
        var roots = [location.skills]
        if location.provider == .codex { roots.append(location.base.appending(path: ".codex/skills")) }
        for root in roots {
            for child in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard !child.lastPathComponent.hasPrefix(".") else { continue }
                let file = child.appending(path: "SKILL.md")
                guard fm.fileExists(atPath: file.path) else { continue }
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                items.append(.init(id: child.path, name: child.lastPathComponent, kind: .skill, source: child,
                                   fields: nil, detail: String(text.prefix(600))))
            }
        }
        if fm.fileExists(atPath: location.config.path) {
            let servers = try readServers(location)
            for name in servers.keys.sorted() {
                let fields = servers[name]!
                items.append(.init(id: location.config.path + "#" + name, name: name, kind: .tool, source: location.config,
                                   fields: fields, detail: fields["command"]?.text ?? fields["url"]?.text ?? "Configuration"))
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private struct TOMLConfig: Decodable { var mcp_servers: [String: [String: ConfigValue]]? }
    private func readServers(_ location: RuntimeLocation) throws -> [String: [String: ConfigValue]] {
        guard fm.fileExists(atPath: location.config.path) else { return [:] }
        let data = try Data(contentsOf: location.config)
        guard data.count < 10_000_000 else { throw failure("Configuration is too large to copy safely.") }
        if location.isTOML { return try TOMLDecoder().decode(TOMLConfig.self, from: data).mcp_servers ?? [:] }
        let object = try JSONDecoder().decode([String: ConfigValue].self, from: data)
        guard case .object(let servers) = object["mcpServers"] else { return [:] }
        return try servers.mapValues { value in
            guard case .object(let fields) = value else { throw failure("Invalid MCP server configuration.") }; return fields
        }
    }
    public func preview(_ item: RuntimeLibraryItem, from source: RuntimeLocation, to target: RuntimeLocation, name: String) throws -> RuntimeCopyPlan {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\n") else { throw failure("Enter a single name without path separators.") }
        if item.kind == .skill {
            let destination = target.skills.appending(path: name)
            guard !fm.fileExists(atPath: destination.path) else { throw failure("A skill with this name already exists. Choose another name to keep both.") }
            let files = try skillFiles(item.source)
            return .init(item: item, destination: destination, destinationName: name, sourceDigest: hash(files), destinationDigest: "missing",
                         preview: files.keys.sorted().joined(separator: "\n"), containsCredentials: false, data: nil, files: files)
        }
        let current = try readServers(source)
        guard var fields = current[item.name] else { throw failure("The source server was removed. Refresh the library.") }
        let existing = try readServers(target)
        guard existing[name] == nil else { throw failure("A server with this name already exists. Choose another name to keep both.") }
        guard fields["command"]?.text != nil || fields["url"]?.text != nil else { throw failure("Only command and HTTP MCP servers can be copied.") }
        let supported: Set<String> = ["command", "args", "env", "url", "headers", "http_headers", "type"]
        let unsupported = Set(fields.keys).subtracting(supported)
        guard unsupported.isEmpty else { throw failure("This server has runtime-specific settings: \(unsupported.sorted().joined(separator: ", ")). Copying them needs a manual configuration edit.") }
        if let type = fields["type"]?.text, !["stdio", "http", "streamable-http"].contains(type) {
            throw failure("The \(type) transport is not portable across these runtimes.")
        }
        // Variable expansion syntax is not interchangeable between these runtimes.
        let encodedFields = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        if source.provider != target.provider && (encodedFields.contains("${") || encodedFields.contains("{{")) {
            throw failure("This server uses runtime-specific variable expansion. Adapt those references for the destination before copying.")
        }
        if target.isTOML {
            guard !fields.values.contains(where: \.containsNull) else { throw failure("Null MCP settings cannot be represented in TOML. Remove them before copying.") }
            fields.removeValue(forKey: "type")
            if target.provider == .codex, let headers = fields.removeValue(forKey: "headers") { fields["http_headers"] = headers }
            if target.provider == .grok, let headers = fields.removeValue(forKey: "http_headers") { fields["headers"] = headers }
        } else {
            if let headers = fields.removeValue(forKey: "http_headers") { fields["headers"] = headers }
            fields["type"] = .string(fields["command"] == nil ? "http" : "stdio")
        }
        let sensitive = fields["env"] != nil || fields["headers"] != nil || fields["http_headers"] != nil
            || (fields["url"]?.text?.contains("?") == true) || (fields["args"].map { String(describing: $0).lowercased().contains("token") || String(describing: $0).lowercased().contains("key") } ?? false)
        let destination = target.config
        if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw failure("Destination configuration is a symlink. Choose its owning runtime configuration instead.") }
        var data: Data
        if target.isTOML {
            let old = fm.fileExists(atPath: destination.path) ? try String(contentsOf: destination, encoding: .utf8) : ""
            let added = "\n[mcp_servers.\(ConfigValue.string(name).toml)]\n" + fields.keys.sorted().map { ConfigValue.string($0).toml + " = " + fields[$0]!.toml }.joined(separator: "\n") + "\n"
            data = Data((old + added).utf8)
            _ = try TOMLDecoder().decode(TOMLConfig.self, from: data)
        } else {
            var root = fm.fileExists(atPath: destination.path) ? try JSONDecoder().decode([String: ConfigValue].self, from: Data(contentsOf: destination)) : [:]
            var servers = existing.mapValues(ConfigValue.object); servers[name] = .object(fields); root["mcpServers"] = .object(servers)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(root)
        }
        var redacted = fields
        for key in ["env", "headers", "http_headers", "args", "url"] where fields[key] != nil { redacted[key] = .string("[value hidden in preview]") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return .init(item: item, destination: destination, destinationName: name, sourceDigest: try digest(item.source),
                     destinationDigest: try digest(destination), preview: String(decoding: try encoder.encode(redacted), as: UTF8.self),
                     containsCredentials: sensitive, data: data, files: [:])
    }
    public func apply(_ plan: RuntimeCopyPlan, includeCredentials: Bool = false) throws -> RuntimeCopyReceipt {
        guard !plan.containsCredentials || includeCredentials else { throw failure("This server includes environment values or credentials. Review the destination and explicitly include them to copy.") }
        let sourceDigest = plan.item.kind == .skill ? hash(try skillFiles(plan.item.source)) : try digest(plan.item.source)
        guard sourceDigest == plan.sourceDigest, try digest(plan.destination) == plan.destinationDigest else { throw failure("Files changed since preview. Refresh the preview before copying.") }
        let parent = plan.destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup: URL?
        if plan.item.kind == .skill {
            let stage = parent.appending(path: ".shastra-stage-\(UUID())")
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            for (name, data) in plan.files {
                let dest = stage.appending(path: name)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
                if let mode = try? fm.attributesOfItem(atPath: plan.item.source.appending(path: name).path)[.posixPermissions] {
                    try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dest.path)
                }
            }
            try fm.moveItem(at: stage, to: plan.destination)
        } else if let data = plan.data {
            if fm.fileExists(atPath: plan.destination.path) {
                let file = parent.appending(path: plan.destination.lastPathComponent + ".shastra-backup-\(UUID())")
                try fm.copyItem(at: plan.destination, to: file)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); backup = file
            }
            try data.write(to: plan.destination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.destination.path)
        }
        return .init(destination: plan.destination, backup: backup, writtenDigest: try digest(plan.destination), isDirectory: plan.item.kind == .skill)
    }
    public func undo(_ receipt: RuntimeCopyReceipt) throws {
        guard try digest(receipt.destination) == receipt.writtenDigest else { throw failure("The destination changed after copying. Use its backup to reconcile manually.") }
        if let backup = receipt.backup { try Data(contentsOf: backup).write(to: receipt.destination, options: .atomic) }
        else {
            // Retain the copied content so undo is itself recoverable.
            let retired = receipt.destination.deletingLastPathComponent().appending(path: ".shastra-undone-\(UUID())")
            try fm.moveItem(at: receipt.destination, to: retired)
        }
    }
    private func skillFiles(_ url: URL) throws -> [String: Data] {
        let root = url.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw failure("Skill folder is unavailable.") }
        var files: [String: Data] = [:], total = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw failure("Skill contains a symlink. Resolve it before copying.") }
            guard values.isRegularFile == true else { continue }
            guard !["auth.json", ".credentials.json", ".env"].contains(file.lastPathComponent) else { throw failure("Skill contains a credential file; remove it from the bundle before copying.") }
            guard (values.fileSize ?? 20_000_000) + total < 20_000_000 else { throw failure("Skill exceeds the 20 MB copy limit.") }
            let data = try Data(contentsOf: file); total += data.count
            guard files.count < 1000, total < 20_000_000 else { throw failure("Skill exceeds the 20 MB / 1,000 file copy limit.") }
            files[file.resolvingSymlinksInPath().pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")] = data
        }
        guard files["SKILL.md"] != nil else { throw failure("Skill has no SKILL.md.") }; return files
    }
    private func digest(_ url: URL) throws -> String {
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &directory) else { return "missing" }
        if directory.boolValue { return hash(try skillFiles(url)) }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func hash(_ files: [String: Data]) -> String {
        var hash = SHA256()
        for name in files.keys.sorted() { hash.update(data: Data(name.utf8)); hash.update(data: Data([0])); hash.update(data: files[name]!) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func failure(_ text: String) -> ShastraError { .invalidResponse(text) }
}
