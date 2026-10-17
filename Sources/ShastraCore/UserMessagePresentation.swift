import Foundation

/// Separates a leading, complete browser-context envelope for display only.
/// Stored messages, copies, forks, and provider prompts keep the original text.
public struct UserMessagePresentation: Equatable, Sendable {
    public let text: String
    public let browserContext: String?

    public init(_ raw: String) {
        let leading = raw.drop(while: { $0.isWhitespace })
        guard leading.hasPrefix("<in-app-browser-context ") || leading.hasPrefix("<in-app-browser-context>"),
              let end = leading.range(of: "</in-app-browser-context>") else {
            text = raw; browserContext = nil; return
        }
        browserContext = String(leading[..<end.upperBound])
        var request = leading[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if request.hasPrefix("## My request:\n") {
            request = String(request.dropFirst("## My request:\n".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = request
    }
}
