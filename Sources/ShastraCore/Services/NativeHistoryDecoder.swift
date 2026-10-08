import Foundation

public enum NativeHistoryDecoder {
    public static func date(_ value: Any?) -> Date {
        if let milliseconds = value as? NSNumber { return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000) }
        guard let value = value as? String else { return .distantPast }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    }

    public static func cursorEntry(key: String, data: Data) -> Entry? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty,
              let type = json["type"] as? Int, type == 1 || type == 2 else { return nil }
        var entry = Entry(kind: type == 1 ? .user : .assistant, text: text, createdAt: date(json["createdAt"]))
        entry.nativeItemID = key
        entry.id = StableIdentity.uuid([key])
        return entry
    }
}
