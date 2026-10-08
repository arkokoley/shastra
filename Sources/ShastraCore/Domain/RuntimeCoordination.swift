import Foundation

public struct RuntimeCoordination: Sendable {
    public var executable: String
    public var token: String
    public var socketPath: String
    public init(executable: String, token: String, socketPath: String) {
        self.executable = executable; self.token = token; self.socketPath = socketPath
    }
    public var acpServer: [String: Any] {
        ["name": "shastra", "command": executable, "args": ["mcp"],
         "env": [["name": "SHASTRA_AGENT_TOKEN", "value": token], ["name": "SHASTRA_SOCKET", "value": socketPath]]]
    }
    public var codexConfiguration: [String: Any] {
        ["mcp_servers.shastra.command": executable, "mcp_servers.shastra.args": ["mcp"],
         "mcp_servers.shastra.env_vars": ["SHASTRA_AGENT_TOKEN", "SHASTRA_SOCKET"]]
    }
    public var codexArguments: [String] {
        let quoted = String(decoding: try! JSONEncoder().encode(executable), as: UTF8.self)
        return ["-c", "mcp_servers.shastra.command=\(quoted)", "-c", "mcp_servers.shastra.args=[\"mcp\"]",
                "-c", "mcp_servers.shastra.env_vars=[\"SHASTRA_AGENT_TOKEN\",\"SHASTRA_SOCKET\"]"]
    }
}
