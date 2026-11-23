//
//  AIUsageView.swift
//  boringNotch
//
//  Notch tab that mirrors CodexBar's menu (Overview + one page per provider),
//  laid out horizontally to fit the ~580×135pt open notch.
//

import SwiftUI

struct AIUsageView: View {
    @ObservedObject private var manager = CodexBarManager.shared
    /// nil = overview
    @State private var selection: String?
    /// Row under the pointer; drives the burndown chart.
    @State private var hoveredAccount: String?

    init(initialSelection: String? = nil) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                header(now: context.date)
                content(now: context.date)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { manager.becameVisible() }
        .onDisappear { manager.becameHidden() }
        .onChange(of: manager.providers.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    // MARK: Header

    private func header(now: Date) -> some View {
        HStack(spacing: 4) {
            UsagePill(title: "Overview", icon: "square.grid.2x2.fill", provider: nil, tint: .white, selected: selection == nil) {
                withAnimation(.smooth(duration: 0.25)) { selection = nil }
            }
            ForEach(manager.providers) { provider in
                UsagePill(title: provider.displayName, icon: nil, provider: provider.id, tint: provider.tint, selected: selection == provider.id) {
                    withAnimation(.smooth(duration: 0.25)) { selection = provider.id }
                }
            }

            Spacer(minLength: 6)

            if manager.status == .ready {
                Text("Updated \(AIUsageFormat.relative(manager.lastUpdated))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HeaderIconButton(systemName: "arrow.clockwise", spinning: manager.isFetchingDetails, help: "Refresh from CodexBar") {
                Task { await manager.refresh(force: true) }
            }
            HeaderIconButton(systemName: "arrow.up.forward.app", spinning: false, help: "Open CodexBar") {
                manager.openCodexBar()
            }
        }
        .frame(height: 20)
    }

    // MARK: Content

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch manager.status {
        case .notInstalled:
            UsageEmptyState(
                icon: "chart.bar.xaxis",
                title: "CodexBar isn't installed",
                subtitle: "This tab reads usage & spend straight from CodexBar.",
                action: ("Get CodexBar", { manager.openCodexBar() })
            )
        case .noSnapshot:
            UsageEmptyState(
                icon: "hourglass",
                title: "No usage data yet",
                subtitle: "Open CodexBar once so it can publish its usage snapshot.",
                action: ("Open CodexBar", { manager.openCodexBar() })
            )
        case .idle, .loading, .ready:
            if manager.providers.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .frame(maxHeight: .infinity)
            } else if let id = selection, let provider = manager.providers.first(where: { $0.id == id }) {
                ProviderDetailView(provider: provider, now: now)
                    .transition(.opacity)
            } else {
                overview(now: now)
                    .transition(.opacity)
            }
        }
    }

    private func overview(now: Date) -> some View {
        HStack(alignment: .top, spacing: 14) {
            OverviewSummary(manager: manager, now: now, focusedID: hoveredAccount)
                .frame(width: 168, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(Array(manager.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0,
                           CodexBarManager.pickingGroup(for: account, now: now)
                            != CodexBarManager.pickingGroup(for: manager.accounts[index - 1], now: now) {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 1)
                        }
                        AccountRow(account: account, now: now)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hoveredAccount = account.id } else if hoveredAccount == account.id { hoveredAccount = nil }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(hoveredAccount == account.id ? 0.06 : 0))
                                    .padding(.horizontal, -4)
                            )
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.25)) { selection = account.provider }
                            }
                    }
                }
                .padding(.bottom, 4)
            }
            AccountLimitLegend()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Overview summary (left column)

private struct OverviewSummary: View {
    @ObservedObject var manager: CodexBarManager
    let now: Date
    let focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Tokens · 30d")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(manager.hasTokenData ? AIUsageFormat.tokens(manager.total30dTokens) : "—")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("≈\(AIUsageFormat.currency(manager.total30dCost, compact: true))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .help("Estimated at API list prices — not what you're billed")
            }
            .monospacedDigit()
            .lineLimit(1)

            HStack(spacing: 4) {
                Text("Today")
                    .foregroundStyle(.secondary)
                Text(manager.hasTokenData ? AIUsageFormat.tokens(manager.totalTodayTokens) : "loading…")
                    .fontWeight(.semibold)
                Text("· \(AIUsageFormat.currency(manager.totalTodayCost, compact: true))")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.top, 2)

            if manager.hasTokenData {
                StackedDailyChart(providers: manager.providers)
                    .frame(height: 18)
                    .padding(.top, 3)
            }

            Spacer(minLength: 4)
            if let pool = PoolBurndown(accounts: manager.accounts, now: now) {
                paceBlock(pool)
                PoolBurndownChart(pool: pool, now: now)
                    .frame(height: 62)
                    .padding(.top, 4)
            }
        }
    }

    /// Pace and the burndown come from the same pooled model, so they can't disagree.
    private func paceBlock(_ pool: PoolBurndown) -> some View {
        let delta = pool.paceDelta
        let ahead = delta > 5, behind = delta < -5
        let stall = pool.stall
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("7d pace")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: ahead ? "hare.fill" : behind ? "tortoise.fill" : "checkmark.circle.fill")
                Text(ahead ? "\(Int(delta.rounded()))% ahead" : behind ? "\(Int((-delta).rounded()))% under" : "on pace")
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(ahead ? Color.orange : behind ? Color.green : Color.white)

            Group {
                if let stall {
                    Text("Runs dry \(AIUsageFormat.exactReset(now.addingTimeInterval(stall.start), now: now))"
                         + (stall.until.map { " · refill \(AIUsageFormat.resetLabel(now.addingTimeInterval($0), now: now, usable: false))" } ?? ""))
                        .foregroundStyle(.orange.opacity(0.9))
                } else {
                    Text("Budget lasts the week")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 9.5))
            .lineLimit(1)
        }
        .help("All weekly limits pooled: at your current combined burn rate you'd use \(String(format: "%.1f", pool.rate * pool.horizon / 100)) limits in 7 days against a budget of \(String(format: "%.1f", pool.budget / 100)).")
    }
}

// MARK: - Account row

private struct AccountRow: View {
    let account: AIAccountUsage
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            // Dot + "active" ring drawn inside a fixed 10pt slot so the scroll view never clips it.
            ZStack {
                if account.isActive {
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                }
                ProviderLogo(provider: account.provider, size: account.isActive ? 7 : 9)
                    .foregroundStyle(account.tint)
            }
            .frame(width: 12, height: 12)

            HStack(spacing: 3) {
                Text(account.label.split(separator: "@").first.map(String.init) ?? account.label)
                    .fontWeight(account.isActive ? .semibold : .regular)
                    .foregroundStyle(account.isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let badge = account.badge {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if account.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange.opacity(0.8))
                        .help("Last known usage — this account hasn't refreshed recently")
                }
            }
            .font(.system(size: 10.5))
            .frame(maxWidth: .infinity, alignment: .leading)

            if let weekly = account.weekly {
                let pace = weekly.pace(now: now)
                let fill = account.fillBar ?? weekly
                let blocked = account.sessionBlocked(now: now)
                Text(fill.windowLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
                // Fill = weekly (all models). Violet tick = Fable limit. White tick = even pace.
                // Amber line underneath = current 5h session.
                AccountLimitBar(
                    fill: fill.usedPercent,
                    pace: fill.pace(now: now)?.expectedPercent,
                    fable: account.fable?.usedPercent,
                    session: account.session?.usedPercent,
                    tint: weekly.usedPercent >= 100 ? Color.red.opacity(0.85) : account.tint
                )
                .frame(width: 120, height: 11)
                Text(AIUsageFormat.percent(weekly.usedPercent))
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(weekly.usedPercent >= 90 ? Color.red.opacity(0.9) : (pace.map { $0.deltaPercent > 5 } ?? false) ? Color.orange : .primary)
                    .overlay(alignment: .topTrailing) {
                        // Fable is the limit that binds: % refers to the violet tick, not the fill.
                        if weekly.isFable, account.allModels != nil {
                            Circle().fill(AccountLimitBar.fableColor).frame(width: 4, height: 4).offset(x: 4, y: 1)
                        }
                    }
                    .frame(width: 34, alignment: .trailing)
                if blocked, let reset = account.session?.resetsAt {
                    Text("5h · " + AIUsageFormat.duration(reset.timeIntervalSince(now)))
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(AccountLimitBar.sessionColor)
                        .lineLimit(1)
                        .frame(width: 60, alignment: .trailing)
                } else {
                    Text(weekly.resetsAt.map { AIUsageFormat.resetLabel($0, now: now) } ?? "—")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            } else {
                Text("no weekly limit")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 120 + 34 + 60 + 22 + 18, alignment: .trailing)
            }
        }
        .frame(height: 16)
        .opacity(account.isStale ? 0.6 : 1)
        .help(helpText)
    }

    private var helpText: String {
        var parts = [account.label]
        if let badge = account.badge { parts.append(badge) }
        if let fable = account.fable, let all = account.allModels {
            parts.append("All models \(AIUsageFormat.percent(all.usedPercent)), Fable \(AIUsageFormat.percent(fable.usedPercent))")
        }
        if let session = account.session {
            var text = "5h session \(AIUsageFormat.percent(session.usedPercent))"
            if let reset = session.resetsAt { text += " (resets \(AIUsageFormat.exactReset(reset, now: now)))" }
            parts.append(text)
        }
        if let reset = account.weekly?.resetsAt {
            parts.append("resets \(AIUsageFormat.exactReset(reset, now: now))")
        }
        if let weekly = account.weekly, let pace = weekly.pace(now: now) {
            let delta = Int(pace.deltaPercent.rounded())
            parts.append(delta > 0 ? "\(delta)% ahead of pace" : "\(-delta)% in reserve")
            if let eta = pace.runsOutIn { parts.append(eta <= 0 ? "limit reached" : "runs out in \(AIUsageFormat.duration(eta))") }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Provider detail

private struct ProviderDetailView: View {
    let provider: AIProviderUsage
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    if provider.bars.isEmpty {
                        Text(provider.errorMessage ?? "CodexBar reports no limits for this provider.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(provider.bars) { bar in
                        DetailBar(bar: bar, tint: provider.tint, now: now)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                if let account = provider.account ?? provider.plan {
                    Text(account)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        StatLabel(title: "Today", value: AIUsageFormat.currency(provider.todayCost))
                        StatLabel(title: "30d", value: AIUsageFormat.currency(provider.last30Cost, compact: true))
                    }
                    GridRow {
                        StatLabel(title: "Tokens", value: AIUsageFormat.tokens(provider.todayTokens))
                        StatLabel(title: "30d tok", value: AIUsageFormat.tokens(provider.last30Tokens))
                    }
                }
                if let credits = provider.resetCreditsAvailable, credits > 0 {
                    Label("\(credits) reset credit\(credits == 1 ? "" : "s")", systemImage: "arrow.counterclockwise.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(provider.tint)
                }
            }
            .frame(width: 122, alignment: .leading)

            DailyCostChart(points: Array(provider.daily.suffix(30)), tint: provider.tint, footnote: provider.costLabel)
                .frame(width: 150)
        }
    }
}

private struct DetailBar: View {
    let bar: AIUsageBar
    let tint: Color
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(bar.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(AIUsageFormat.percent(bar.usedPercent)) used")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(bar.usedPercent >= 90 ? Color.red.opacity(0.9) : .secondary)
                Spacer(minLength: 4)
                if let reset = AIUsageFormat.resetText(for: bar, now: now) {
                    Text(reset)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            UsageBarTrack(percent: bar.usedPercent, expected: bar.expectedPercent, tint: tint)
                .frame(height: 5)
            if let pace = paceText {
                Text(pace)
                    .font(.system(size: 9.5))
                    .foregroundStyle(bar.willLastToReset == false ? Color.orange.opacity(0.95) : .secondary)
                    .lineLimit(1)
            }
        }
    }

    /// CodexBar's summary is "63% in deficit | Expected 12% used | Runs out in 6h 36m".
    /// The tick on the bar already shows "expected", so drop that segment.
    private var paceText: String? {
        guard let summary = bar.paceSummary else { return nil }
        let parts = summary
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.lowercased().hasPrefix("expected") && !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Building blocks

/// One account's limits on a single track.
struct AccountLimitBar: View {
    let fill: Double
    let pace: Double?
    let fable: Double?
    let session: Double?
    let tint: Color

    static let fableColor = Color(red: 0.66, green: 0.58, blue: 1.0)
    static let sessionColor = Color(red: 1.0, green: 0.78, blue: 0.3)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barY: CGFloat = 2, barH: CGFloat = 5
            let x = { (p: Double) in w * min(1, max(0, p) / 100) }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.white.opacity(0.12))
                    .frame(width: w, height: barH).offset(y: barY)
                Capsule().fill(tint)
                    .frame(width: max(barH, x(fill)), height: barH).offset(y: barY)
                    .opacity(fill <= 0 ? 0 : 1)
                if let pace, pace > 0, pace < 100 {
                    Rectangle().fill(Color.white.opacity(0.85))
                        .frame(width: 1.5, height: barH + 4)
                        .offset(x: x(pace) - 0.75, y: barY - 2)
                }
                if let fable {
                    // Fable: violet notch that pokes above the bar.
                    RoundedRectangle(cornerRadius: 1).fill(Self.fableColor)
                        .frame(width: 2.5, height: barH + 4)
                        .offset(x: min(w - 2.5, max(0, x(fable) - 1.25)), y: barY - 2)
                }
                if let session {
                    Capsule().fill(Color.white.opacity(0.08))
                        .frame(width: w, height: 2).offset(y: barY + barH + 2)
                    Capsule().fill(session >= 100 ? Color.red.opacity(0.9) : Self.sessionColor)
                        .frame(width: max(2, x(session)), height: 2).offset(y: barY + barH + 2)
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: fill)
    }
}

/// Legend for the account bars.
struct AccountLimitLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item("Fable") { RoundedRectangle(cornerRadius: 1).fill(AccountLimitBar.fableColor).frame(width: 2.5, height: 8) }
            item("even pace") { Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.5, height: 8) }
            item("5h session") { Capsule().fill(AccountLimitBar.sessionColor).frame(width: 10, height: 2) }
        }
        .font(.system(size: 8.5))
        .foregroundStyle(.tertiary)
    }

    private func item<V: View>(_ label: String, @ViewBuilder _ mark: () -> V) -> some View {
        HStack(spacing: 3) { mark(); Text(label) }
    }
}

struct UsageBarTrack: View {
    let percent: Double
    let expected: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(geo.size.height, width * min(1, max(0, percent) / 100)))
                    .opacity(percent <= 0 ? 0 : 1)
                if let expected, expected > 0, expected < 100 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 1.5, height: geo.size.height + 4)
                        .offset(x: width * expected / 100 - 0.75)
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: percent)
    }
}

private struct StatLabel: View {
    let title: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct DailyCostChart: View {
    let points: [AIDailyPoint]
    let tint: Color
    let footnote: String?
    @State private var hovered: AIDailyPoint?

    private var maxCost: Double { max(points.map(\.cost).max() ?? 0, 0.01) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(hovered.map { Self.dayLabel($0.dayKey) } ?? "Daily cost")
                Spacer()
                Text(AIUsageFormat.currency(hovered?.cost ?? maxCost, compact: true))
                    .monospacedDigit()
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)

            if points.isEmpty {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.05))
                    .overlay(Text("No cost history").font(.system(size: 9.5)).foregroundStyle(.tertiary))
            } else {
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 1.5) {
                        ForEach(points) { point in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(tint.opacity(hovered == point || (hovered == nil && point == points.last) ? 1 : 0.6))
                                .frame(height: max(1, geo.size.height * point.cost / maxCost))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { hovered = point } else if hovered == point { hovered = nil }
                                }
                        }
                    }
                }
            }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    static func dayLabel(_ dayKey: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dayKey) else { return dayKey }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate("MMMd")
        return out.string(from: date)
    }
}

/// Last 30 days of spend, stacked per provider.
private struct StackedDailyChart: View {
    let providers: [AIProviderUsage]

    var body: some View {
        let days = Array(Set(providers.flatMap { $0.daily.map(\.dayKey) })).sorted().suffix(30)
        let lookup: [String: [String: Double]] = Dictionary(uniqueKeysWithValues: providers.map { p in
            (p.id, Dictionary(p.daily.map { ($0.dayKey, $0.cost) }, uniquingKeysWith: +))
        })
        let totals = days.map { day in providers.reduce(0) { $0 + (lookup[$1.id]?[day] ?? 0) } }
        let maxTotal = max(totals.max() ?? 0, 0.01)

        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 0) {
                        ForEach(providers.reversed()) { provider in
                            Rectangle()
                                .fill(provider.tint.opacity(0.85))
                                .frame(height: geo.size.height * (lookup[provider.id]?[day] ?? 0) / maxTotal)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .help("\(day) · \(AIUsageFormat.currency(totals[index]))")
                }
            }
        }
        .help("Daily spend, last 30 days (API list-price estimate)")
    }
}

private struct UsagePill: View {
    let title: String
    let icon: String?
    let provider: String?
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 8, weight: .semibold))
                } else if let provider {
                    ProviderLogo(provider: provider, size: 10).foregroundStyle(tint)
                }
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(selected ? .white : .gray)
            .background(Capsule().fill(selected ? Color.white.opacity(0.14) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderIconButton: View {
    let systemName: String
    let spinning: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.gray)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct UsageEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: (String, () -> Void)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action.0, action: action.1)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
