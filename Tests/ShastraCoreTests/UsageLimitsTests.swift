import Foundation
import Testing
@testable import ShastraCore

@Test func usagePrefersBucketsAndConvertsUsedToRemaining() throws {
    let json = #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1790881200},"secondary":{"usedPercent":7,"windowDurationMins":10080}},"extra":{"primary":{"usedPercent":4}}}}"#
    let limits = try JSONDecoder().decode(AccountUsageLimits.self, from: Data(json.utf8))
    #expect(limits.buckets.count == 2)
    #expect(limits.buckets.first?.primary?.remainingPercent == 77)
    #expect(limits.buckets.first?.primary?.label == "5h")
    #expect(limits.buckets.first?.primary?.resetsAt == 1790881200)
    #expect(limits.buckets.first?.secondary?.label == "Weekly")
}

@Test func unavailableUsageStaysUnknownAndFallbackIsSupported() throws {
    let unknown = try JSONDecoder().decode(AccountUsageLimits.self, from: Data(#"{"rateLimits":{"primary":null,"secondary":null},"rateLimitsByLimitId":null}"#.utf8))
    #expect(unknown.buckets.first?.windows.isEmpty == true)
    let fallback = try JSONDecoder().decode(AccountUsageLimits.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":120},"secondary":{"usedPercent":-10}},"rateLimitsByLimitId":{}}"#.utf8))
    #expect(fallback.buckets.first?.primary?.remainingPercent == 0)
    #expect(fallback.buckets.first?.secondary?.remainingPercent == 100)
    #expect(fallback.buckets.first?.primary?.resetsAt == nil)
}
