//
//  CodexBarModels.swift
//  boringNotch
//
//  Decodable mirrors of the two data sources CodexBar exposes:
//   1. `widget-snapshot.json` in its group container (limits, daily cost, tokens)
//   2. `codexbar usage --provider <id> --json` (identity, pace, extra windows, reset credits)
//  plus the merged view model the notch renders.
//
//  Every field is optional on purpose: CodexBar evolves quickly and we'd rather
//  show partial data than fail the whole decode.
//

import Foundation
import SwiftUI

// MARK: - Shared

struct CodexBarRateWindow: Decodable, Hashable {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Date?
    var resetDescription: String?
}

// MARK: - Widget snapshot

struct CodexBarSnapshot: Decodable {
    var generatedAt: Date?
    var entries: [Entry]
    var enabledProviders: [String]?
    var usageBarsShowUsed: Bool?

    struct Entry: Decodable {
        var provider: String
        var updatedAt: Date?
        var primary: CodexBarRateWindow?
        var secondary: CodexBarRateWindow?
        var tertiary: CodexBarRateWindow?
        var usageRows: [UsageRow]?
        var dailyUsage: [DailyUsage]?
        var tokenUsage: TokenUsage?
        var creditsRemaining: Double?

        func window(named id: String) -> CodexBarRateWindow? {
            switch id {
            case "primary": return primary
            case "secondary": return secondary
            case "tertiary": return tertiary
            default: return nil
            }
        }
    }

    struct UsageRow: Decodable {
        var id: String
        var title: String
        var percentLeft: Double?
        var window: CodexBarRateWindow?
    }

    struct DailyUsage: Decodable {
        var dayKey: String
        var costUSD: Double?
        var totalTokens: Double?
    }

    struct TokenUsage: Decodable {
        var sessionCostUSD: Double?
        var sessionTokens: Double?
        var sessionLabel: String?
        var last30DaysCostUSD: Double?
        var last30DaysTokens: Double?
        var last30DaysLabel: String?
        var currencyCode: String?
    }
}

// MARK: - CLI (`codexbar usage --json`)

struct CodexBarCLIResult: Decodable {
    var provider: String
    var source: String?
    var usage: Usage?
    var rateWindowLabels: [String: String]?
    var pace: [String: Pace]?
    var resetCredits: ResetCredits?
    var error: CLIError?

    struct Usage: Decodable {
        var primary: CodexBarRateWindow?
        var secondary: CodexBarRateWindow?
        var tertiary: CodexBarRateWindow?
        var extraRateWindows: [ExtraWindow]?
        var accountEmail: String?
        var loginMethod: String?
        var updatedAt: Date?
    }

    struct ExtraWindow: Decodable {
        var id: String
        var title: String
        var window: CodexBarRateWindow?
    }

    struct Pace: Decodable {
        var summary: String?
        var deltaPercent: Double?
        var expectedUsedPercent: Double?
        var etaSeconds: Double?
        var willLastToReset: Bool?
        var stage: String?
    }

    struct ResetCredits: Decodable {
        var available: Int?
        var nextExpiresAt: Date?
    }

    struct CLIError: Decodable {
        var message: String?
    }
}

// MARK: - CLI (`codexbar cost --json`)

struct CodexBarCostResult: Decodable {
    var provider: String
    var sessionCostUSD: Double?
    var sessionTokens: Double?
    var last30DaysCostUSD: Double?
    var last30DaysTokens: Double?
    var provenance: String?
    var daily: [Day]?

    struct Day: Decodable {
        var date: String
        var totalCost: Double?
        var totalTokens: Double?
    }
}

// MARK: - ~/.codexbar/config.json

struct CodexBarConfig: Decodable {
    var providers: [Provider]

    struct Provider: Decodable {
        var id: String
        var enabled: Bool?
    }

    var enabledIDs: [String] { providers.filter { $0.enabled == true }.map(\.id) }
}

// MARK: - Per-account files (via helper `codexBarAccounts`)

struct CodexBarAccountsPayload: Decodable {
    var claude: [ClaudeRetained]?
    var claudeSwap: ClaudeSwap?
    var codex: [CodexAccount]?

    struct ClaudeRetained: Decodable {
        var opaqueID: String?
        var primary: CodexBarRateWindow?
        var secondary: CodexBarRateWindow?
        var extraRateWindows: [CodexBarCLIResult.ExtraWindow]?
        var updatedAt: Date?
        var usesLastKnownUsage: Bool?
    }

    struct ClaudeSwap: Decodable {
        var active: Int?
        var accounts: [String: Account]?

        struct Account: Decodable {
            var email: String?
            var organizationName: String?
            var alias: String?
        }
    }

    struct CodexAccount: Decodable {
        var email: String?
        var plan: String?
        var primary: CodexBarRateWindow?
        var secondary: CodexBarRateWindow?
        var tertiary: CodexBarRateWindow?
        var updatedAt: Date?
    }
}

enum CodexBarDecoding {
    /// CodexBar's own on-disk files encode dates as Apple reference-date seconds.
    static let referenceDateDecoder = JSONDecoder()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            if let date = plain.date(from: string) ?? fractional.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(string)")
        }
        return decoder
    }()
}

// MARK: - Merged view model

struct AIUsageBar: Identifiable, Hashable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    let resetDescription: String?
    var windowMinutes: Int? = nil
    /// Where usage "should" be if spread evenly over the window (from CodexBar pace).
    let expectedPercent: Double?
    let paceSummary: String?
    let willLastToReset: Bool?
    let etaSeconds: Double?
}

struct AIPace {
    /// Where usage would be if spread evenly across the window.
    let expectedPercent: Double
    /// Positive = using faster than even pace ("ahead"), negative = in reserve.
    let deltaPercent: Double
    /// Seconds until 100% at the current rate; nil if it lasts until reset.
    let runsOutIn: TimeInterval?
}

extension AIUsageBar {
    /// Short window label: 5h / 7d / Mo.
    var windowLabel: String {
        switch windowMinutes {
        case 300: return "5h"
        case 10080: return "7d"
        case .some(let m) where m >= 40000: return "Mo"
        case .some(let m) where m >= 1440: return "\(m / 1440)d"
        case .some(let m): return "\(m / 60)h"
        default: return title
        }
    }

    var isWeekly: Bool { windowMinutes == 10080 }

    var isFable: Bool { id.lowercased().contains("fable") || title.lowercased().contains("fable") }
    /// Short name for compact rows: "Fable" / "All models" / window label.
    var limitName: String { isFable ? "Fable" : isWeekly ? "All models" : windowLabel }

    /// Prefers CodexBar's own pace numbers; otherwise derives them from reset time + window length.
    func pace(now: Date = Date()) -> AIPace? {
        guard let resetsAt, let minutes = windowMinutes, minutes > 0 else {
            return expectedPercent.map { AIPace(expectedPercent: $0, deltaPercent: usedPercent - $0, runsOutIn: etaSeconds) }
        }
        let window = Double(minutes) * 60
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= window + 60 else { return nil }
        let elapsed = max(window - remaining, 1)
        let expected = expectedPercent ?? min(100, max(0, elapsed / window * 100))

        var runsOut: TimeInterval?
        if let etaSeconds, willLastToReset == false {
            runsOut = etaSeconds
        } else if usedPercent >= 100 {
            runsOut = 0
        } else if usedPercent > 0, elapsed > 600 {
            let secondsToFull = (100 - usedPercent) / (usedPercent / elapsed)
            if secondsToFull < remaining { runsOut = secondsToFull }
        }
        return AIPace(expectedPercent: expected, deltaPercent: usedPercent - expected, runsOutIn: runsOut)
    }
}

/// One row in the overview: a single login on a provider.
struct AIAccountUsage: Identifiable {
    let id: String
    let provider: String
    let label: String
    /// e.g. "Team", "Personal", "Pro Lite"
    let badge: String?
    let isActive: Bool
    let isStale: Bool
    /// Most constrained weekly-ish limit (7d, 7d · Fable, or monthly when that's all there is).
    let weekly: AIUsageBar?
    /// All-models weekly limit (the bar's fill). Falls back to `weekly`.
    var allModels: AIUsageBar? = nil
    /// Fable-scoped weekly limit, drawn as a coloured tick on the same bar.
    var fable: AIUsageBar? = nil
    /// Active 5h session window (Team plans), drawn as a thin line under the bar.
    var session: AIUsageBar? = nil

    var fillBar: AIUsageBar? { allModels ?? weekly }
    /// True while the 5h session limit is exhausted — account is unusable until it resets.
    func sessionBlocked(now: Date = Date()) -> Bool {
        guard let session, session.usedPercent >= 100, let reset = session.resetsAt else { return false }
        return reset > now
    }

    var tint: Color { AIProviderStyle.tint(for: provider) }
}

struct AIDailyPoint: Identifiable, Hashable {
    var id: String { dayKey }
    let dayKey: String
    let cost: Double
    let tokens: Double
}

struct AIProviderUsage: Identifiable {
    let id: String
    var displayName: String { AIProviderStyle.name(for: id) }
    var tint: Color { AIProviderStyle.tint(for: id) }

    var account: String?
    var plan: String?
    var updatedAt: Date?
    var bars: [AIUsageBar] = []

    var todayCost: Double?
    var todayTokens: Double?
    var last30Cost: Double?
    var last30Tokens: Double?
    var costLabel: String?
    var daily: [AIDailyPoint] = []

    var resetCreditsAvailable: Int?
    var errorMessage: String?

    /// The most constrained limit — what the overview card leads with.
    var headlineBar: AIUsageBar? { bars.max { $0.usedPercent < $1.usedPercent } }
}

enum AIProviderStyle {
    static func name(for id: String) -> String {
        switch id {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "cursor": return "Cursor"
        case "gemini": return "Gemini"
        case "copilot": return "Copilot"
        case "openai": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "zai": return "z.ai"
        case "xai", "grok": return "Grok"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    static func tint(for id: String) -> Color {
        switch id {
        case "codex", "openai": return Color(red: 0.36, green: 0.70, blue: 0.75)
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "cursor": return Color(white: 0.86) // Cursor's mark is monochrome; also keeps it distinct from Claude
        case "gemini": return Color(red: 0.43, green: 0.56, blue: 0.96)
        case "copilot": return Color(red: 0.64, green: 0.44, blue: 0.97)
        default: return Color(white: 0.75)
        }
    }
}
