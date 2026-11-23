//
//  UsageHistoryStore.swift
//  boringNotch
//
//  CodexBar only keeps the *current* % per account, so we record our own readings
//  to draw a real burndown line. Samples are tiny, deduplicated and pruned after
//  8 days. Stored in the app container's Application Support.
//

import Foundation

struct UsageSample: Codable, Hashable {
    let at: Date
    let used: Double
    /// Reset time when sampled — lets us keep only samples from the current window.
    let resetsAt: Date?
}

@MainActor
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private var samples: [String: [UsageSample]] = [:]
    private let url: URL
    private let keep: TimeInterval = 8 * 86400
    private let minInterval: TimeInterval = 10 * 60

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("weekly-usage.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [UsageSample]].self, from: data) {
            samples = decoded
        }
    }

    func record(_ accounts: [AIAccountUsage], now: Date = Date()) {
        var changed = false
        for account in accounts where !account.isStale {
            guard let bar = account.weekly else { continue }
            var list = samples[account.id] ?? []
            let last = list.last
            let resetMoved = last?.resetsAt.map { r in bar.resetsAt.map { abs($0.timeIntervalSince(r)) > 3600 } ?? true } ?? false
            let due = last.map { now.timeIntervalSince($0.at) >= minInterval } ?? true
            let moved = last.map { abs($0.used - bar.usedPercent) >= 0.5 } ?? true
            guard due || moved || resetMoved else { continue }
            list.append(UsageSample(at: now, used: bar.usedPercent, resetsAt: bar.resetsAt))
            list.removeAll { now.timeIntervalSince($0.at) > keep }
            samples[account.id] = list
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Samples inside the account's current window (same reset time, after window start).
    func samples(for account: AIAccountUsage) -> [UsageSample] {
        guard let bar = account.weekly, let reset = bar.resetsAt, let minutes = bar.windowMinutes else { return [] }
        let start = reset.addingTimeInterval(-Double(minutes) * 60)
        return (samples[account.id] ?? []).filter { sample in
            sample.at >= start && (sample.resetsAt.map { abs($0.timeIntervalSince(reset)) < 3600 } ?? true)
        }
    }
}
