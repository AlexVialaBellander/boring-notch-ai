//
//  BurndownChart.swift
//  boringNotch
//
//  One burndown for the whole pool of weekly limits over the next 7 days.
//
//  Every account has its own reset, but we know all of them, so treat the pool as
//  a single budget:
//    budget B   = what's left on every account now
//               + a full limit (100%) for each account that resets within 7 days
//    unlocked A(t) = what's usable by time t (current remaining + resets so far)
//    burn       = your current combined rate (Σ each account's used% / elapsed)
//
//  Plot (normalised so B = 100%):
//    solid   – B − burn·t      projected budget left
//    dashed  – B·(1 − t/7d)    even pace: spend exactly B over the week
//    shaded  – B − A(t)        capacity not unlocked yet (steps down at each reset)
//  If the solid line drops into the shaded area you've used everything available
//  before the next reset: that's a stall.
//

import SwiftUI

struct PoolBurndown {
    let budget: Double                 // in "% of one limit" units, e.g. 640 = 6.4 limits
    let remainingNow: Double
    let rate: Double                   // % per second, all accounts combined
    let resets: [TimeInterval]         // seconds from now, within horizon, sorted
    let horizon: TimeInterval = 7 * 86400
    let limitCount: Int

    init?(accounts: [AIAccountUsage], now: Date = Date()) {
        var remaining = 0.0, rate = 0.0, resets: [TimeInterval] = [], count = 0
        for account in accounts where !account.isStale {
            guard let bar = account.weekly, bar.isWeekly,
                  let reset = bar.resetsAt, let minutes = bar.windowMinutes else { continue }
            let window = Double(minutes) * 60
            let resetIn = reset.timeIntervalSince(now)
            guard resetIn > 0, resetIn <= window + 60 else { continue }
            let used = min(100, max(0, bar.usedPercent))
            remaining += 100 - used
            rate += used / max(window - resetIn, 3600)
            if resetIn < 7 * 86400 { resets.append(resetIn) }
            count += 1
        }
        guard count > 0 else { return nil }
        self.remainingNow = remaining
        self.rate = rate
        self.resets = resets.sorted()
        self.budget = remaining + 100 * Double(resets.count)
        self.limitCount = count
    }

    /// Positive = you'd burn more than the 7-day budget at the current rate ("ahead of pace").
    var paceDelta: Double { budget > 0 ? (rate * horizon / budget - 1) * 100 : 0 }

    /// Capacity usable by time t.
    func unlocked(at t: TimeInterval) -> Double {
        remainingNow + 100 * Double(resets.filter { $0 <= t }.count)
    }

    /// First moment the projected burn exceeds what's unlocked, and when it frees up again.
    var stall: (start: TimeInterval, until: TimeInterval?)? {
        guard rate > 0 else { return nil }
        // Between resets unlocked capacity is flat, so check each segment's end.
        var segmentStart: TimeInterval = 0
        for boundary in resets + [horizon] {
            let available = unlocked(at: segmentStart)
            let hitsAt = available / rate
            if hitsAt < boundary, hitsAt >= segmentStart {
                return (hitsAt, boundary < horizon ? boundary : nil)
            }
            segmentStart = boundary
        }
        return nil
    }
}

struct PoolBurndownChart: View {
    let pool: PoolBurndown
    let now: Date
    var tint: Color = AIProviderStyle.tint(for: "claude")

    var body: some View {
        let stall = pool.stall
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Next 7d")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f limits", pool.budget / 100))
                    .fontWeight(.semibold)
                    .help("Left now across \(pool.limitCount) weekly limits, plus \(pool.resets.count) refill\(pool.resets.count == 1 ? "" : "s") from resets this week")
                Text("budget")
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 2)
            }
            .font(.system(size: 9.5))
            .lineLimit(1)

            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let px = { (t: TimeInterval) in w * t / pool.horizon }
                let py = { (value: Double) in h * (1 - min(1, max(0, value / pool.budget))) }

                ZStack(alignment: .topLeading) {
                    ForEach(1..<7, id: \.self) { day in
                        Rectangle().fill(Color.white.opacity(0.06))
                            .frame(width: 1, height: h)
                            .offset(x: px(Double(day) * 86400))
                    }
                    // Locked capacity (not yet reset): steps down at each reset.
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        var t: TimeInterval = 0
                        p.addLine(to: CGPoint(x: 0, y: py(pool.budget - pool.unlocked(at: 0))))
                        for reset in pool.resets {
                            p.addLine(to: CGPoint(x: px(reset), y: py(pool.budget - pool.unlocked(at: t))))
                            p.addLine(to: CGPoint(x: px(reset), y: py(pool.budget - pool.unlocked(at: reset))))
                            t = reset
                        }
                        p.addLine(to: CGPoint(x: w, y: py(pool.budget - pool.unlocked(at: t))))
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.white.opacity(0.08))

                    // Even pace
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: py(pool.budget)))
                        p.addLine(to: CGPoint(x: w, y: py(0)))
                    }
                    .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Projected burn (orange once it stalls)
                    let end = min(pool.horizon, pool.rate > 0 ? pool.budget / pool.rate : pool.horizon)
                    let stallAt = stall?.start ?? end
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: py(pool.budget)))
                        p.addLine(to: CGPoint(x: px(stallAt), y: py(pool.budget - pool.rate * stallAt)))
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    if stallAt < end {
                        Path { p in
                            p.move(to: CGPoint(x: px(stallAt), y: py(pool.budget - pool.rate * stallAt)))
                            p.addLine(to: CGPoint(x: px(end), y: py(pool.budget - pool.rate * end)))
                        }
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 2]))
                    }
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .offset(x: -2.5, y: py(pool.budget) - 2.5)
                }
            }

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { day in
                    Text(day == 0 ? "now" : Self.weekday(now.addingTimeInterval(Double(day) * 86400)))
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
        }
        .help("All weekly limits as one budget for the next 7 days. Solid: projected at your current combined burn rate. Dashed: even pace. Shaded: capacity that only unlocks when an account resets — dipping into it means you'd stall until the next reset.")
    }

    private static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f.string(from: date)
    }
}
