import Foundation
import Darwin

public struct ServiceRequest: Codable, Sendable {
    public var id: String
    public var token: String
    public var method: String
    public var params: [String: String]
    public init(method: String, params: [String: String] = [:], token: String, id: String = UUID().uuidString) {
        self.id = id; self.token = token; self.method = method; self.params = params
    }
}
public struct ServiceResponse: Codable, Sendable {
    public var id: String
    public var value: String?
    public var error: String?
    public init(id: String, value: String? = nil, error: String? = nil) { self.id = id; self.value = value; self.error = error }
}
public enum ServicePaths {
    public static var directory: URL {
        ProcessInfo.processInfo.environment["SHASTRA_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Shastra")
    }
    public static var socket: String { directory.appending(path: "service.sock").path }
    public static var adminToken: URL { directory.appending(path: "service.token") }
    public static func executable(_ name: String) -> String? {
        let candidates = [Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(name)").path,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name).path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
public enum LocalSocket {
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ShastraError.invalidResponse("Service socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    private static func configure(_ fd: Int32) {
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    public static func listen(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ShastraError.invalidResponse("Cannot create service socket") }
        configure(fd)
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); throw ShastraError.invalidResponse("Cannot bind service socket") }
        chmod(path, 0o600)
        return fd
    }
    public static func read(_ fd: Int32) throws -> Data {
        configure(fd)
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while result.count <= 16_777_216 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw ShastraError.processExited("Service connection ended before a receipt") }
            if let end = buffer[..<count].firstIndex(of: 10) { result.append(contentsOf: buffer[..<end]); return result }
            result.append(contentsOf: buffer[..<count])
        }
        throw ShastraError.invalidResponse("Service message exceeds the size limit")
    }
    public static func write(_ data: Data, to fd: Int32) throws {
        let bytes = data + Data([10])
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw ShastraError.processExited("Service receipt could not be sent") }
                offset += count
            }
        }
    }
    public static func call(_ request: ServiceRequest, path: String = ServicePaths.socket) throws -> ServiceResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ShastraError.processExited("Cannot open service connection") }
        defer { Darwin.close(fd) }; configure(fd)
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ShastraError.processExited("Shastra service is unavailable") }
        try write(JSONEncoder().encode(request), to: fd)
        let response = try JSONDecoder().decode(ServiceResponse.self, from: read(fd))
        guard response.id == request.id else { throw ShastraError.invalidResponse("Service response identity mismatch") }
        if let error = response.error { throw ShastraError.invalidResponse(error) }
        return response
    }
    public static func isSameUser(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
}
