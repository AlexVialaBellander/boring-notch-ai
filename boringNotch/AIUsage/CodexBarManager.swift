//
//  CodexBarManager.swift
//  boringNotch
//
//  Reads usage/spend from CodexBar (https://github.com/steipete/CodexBar) instead of
//  re-implementing provider scraping. Two layers:
//   • snapshot – cheap local file CodexBar keeps fresh; polled every 30s while visible
//   • CLI      – richer details (account, pace, extra windows); refreshed every few minutes
//

import AppKit
import Combine
import Defaults
import Foundation
import os

private let log = Logger(subsystem: "theboringteam.boringnotch", category: "CodexBar")

@MainActor
final class CodexBarManager: ObservableObject {
    static let shared = CodexBarManager()

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case notInstalled
        case noSnapshot
    }

    @Published private(set) var providers: [AIProviderUsage] = []
    /// Every login across providers (all claude-swap accounts, Codex, Cursor…), for the overview.
    @Published private(set) var accounts: [AIAccountUsage] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isFetchingDetails = false

    private var snapshot: CodexBarSnapshot?
    private var configProviders: [String] = []
    private var cliResults: [String: CodexBarCLIResult] = [:]
    private var costResults: [String: CodexBarCostResult] = [:]
    private var accountsPayload: CodexBarAccountsPayload?
    private var lastCLIFetch: Date?
    private var lastCostFetch: Date?
    private var isFetchingCosts = false
    private var pollTask: Task<Void, Never>?
    private var visibleClients = 0
    /// Clients showing the full tab (vs. the tiny closed-notch readout).
    private var detailedClients = 0

    private let snapshotInterval: Duration = .seconds(30)
    /// The CLI is comparatively heavy (it hits provider APIs), so poll it less
    /// often when only the closed-notch readout is on screen.
    private var cliStaleAfter: TimeInterval { detailedClients > 0 ? 180 : 600 }

    static let bundleID = "com.steipete.codexbar"

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    // MARK: Totals for the overview

    var total30dCost: Double { providers.compactMap(\.last30Cost).reduce(0, +) }
    var totalTodayCost: Double { providers.compactMap(\.todayCost).reduce(0, +) }
    var total30dTokens: Double { providers.compactMap(\.last30Tokens).reduce(0, +) }
    var totalTodayTokens: Double { providers.compactMap(\.todayTokens).reduce(0, +) }
    struct StripStat: Identifiable {
        var id: String { provider }
        let provider: String
        let usedPercent: Double
        let accounts: Int
    }

    /// Per provider: mean of each (non-stale) account's most constrained limit.
    var stripStats: [StripStat] {
        let order = providers.map(\.id)
        let grouped = Dictionary(grouping: accounts.filter { !$0.isStale && $0.weekly != nil }, by: \.provider)
        return order.compactMap { id in
            guard let rows = grouped[id], !rows.isEmpty else { return nil }
            let mean = rows.compactMap { $0.weekly?.usedPercent }.reduce(0, +) / Double(rows.count)
            return StripStat(provider: id, usedPercent: mean, accounts: rows.count)
        }
    }

    /// False until at least one provider has reported token/cost history.
    var hasTokenData: Bool { providers.contains { $0.last30Tokens != nil } }

    // MARK: Lifecycle

    /// Call from `onAppear`; polling stops automatically once every client disappears.
    func becameVisible(detailed: Bool = true) {
        visibleClients += 1
        if detailed {
            detailedClients += 1
            // Opening the tab should feel fresh even if the closed view kept polling
            // (staleness checks inside refresh keep this cheap).
            if pollTask != nil { Task { await refresh(force: false) } }
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                try? await Task.sleep(for: self?.snapshotInterval ?? .seconds(30))
            }
        }
    }

    private var samplerTask: Task<Void, Never>?

    /// Low-cost background sampling for the closed notch and the burndown history: read
    /// CodexBar's per-account files and widget snapshot (no CLI, no network) and record
    /// the readings. The snapshot gives single-login providers (and Claude without
    /// claude-swap) their row before the Usage tab is ever opened.
    func startHistorySampling() {
        guard samplerTask == nil else { return }
        samplerTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if let self, self.pollTask == nil, self.isInstalled {
                    if let data = await XPCHelperClient.shared.codexBarConfig(),
                       let config = try? CodexBarDecoding.decoder.decode(CodexBarConfig.self, from: data) {
                        self.configProviders = config.enabledIDs
                    }
                    if let data = await XPCHelperClient.shared.codexBarAccounts(),
                       let decoded = try? CodexBarDecoding.referenceDateDecoder.decode(CodexBarAccountsPayload.self, from: data) {
                        self.ingest(decoded)
                    }
                    if let data = await XPCHelperClient.shared.codexBarSnapshot(),
                       let decoded = try? CodexBarDecoding.decoder.decode(CodexBarSnapshot.self, from: data) {
                        self.snapshot = decoded
                    }
                    self.rebuild()
                    // Providers without on-disk account files (e.g. Cursor) need the CLI; it's
                    // quick for them, but keep it to every ~5 minutes.
                    tick += 1
                    if tick % 20 == 1, Defaults[.codexBarFetchLiveDetails] {
                        let covered: Set<String> = ["claude", "codex"]
                        let ids = self.providerIDs.filter { !covered.contains($0) }
                        if !ids.isEmpty { await self.fetchCLIDetails(only: ids) }
                    }
                }
                // Short interval: only small file reads, needed to catch claude-swap switches promptly.
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func becameHidden(detailed: Bool = true) {
        visibleClients = max(0, visibleClients - 1)
        if detailed { detailedClients = max(0, detailedClients - 1) }
        if visibleClients == 0 {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refresh(force: Bool) async {
        guard isInstalled else {
            status = .notInstalled
            return
        }
        if providers.isEmpty { status = .loading }

        if let data = await XPCHelperClient.shared.codexBarConfig(),
           let config = try? CodexBarDecoding.decoder.decode(CodexBarConfig.self, from: data) {
            configProviders = config.enabledIDs
        }
        if let data = await XPCHelperClient.shared.codexBarAccounts(),
           let decoded = try? CodexBarDecoding.referenceDateDecoder.decode(CodexBarAccountsPayload.self, from: data) {
            ingest(decoded)
        }
        if let data = await XPCHelperClient.shared.codexBarSnapshot(),
           let decoded = try? CodexBarDecoding.decoder.decode(CodexBarSnapshot.self, from: data) {
            snapshot = decoded
        }
        rebuild()
        log.info("refresh: config=\(self.configProviders, privacy: .public) snapshot=\(self.snapshot != nil) accounts=\(self.accounts.count) providers=\(self.providers.map(\.id), privacy: .public)")

        // Cost history: only needed when the snapshot (which already carries it) is unreadable,
        // and only for the full tab — the closed-notch readout shows limits, not spend.
        let missingCost = providerIDs.filter { id in !(snapshot?.entries.contains { $0.provider == id } ?? false) }
        let costStale = lastCostFetch.map { Date().timeIntervalSince($0) > (detailedClients > 0 ? 300 : 900) } ?? true
        let wantsCost = !missingCost.isEmpty && (force || costStale) && !isFetchingCosts

        let stale = lastCLIFetch.map { Date().timeIntervalSince($0) > cliStaleAfter } ?? true
        let wantsDetails = Defaults[.codexBarFetchLiveDetails] && (force || stale) && !isFetchingDetails

        async let costs: Void = wantsCost ? fetchCosts(for: missingCost) : ()
        async let details: Void = wantsDetails ? fetchCLIDetails() : ()
        _ = await (costs, details)
    }

    private func fetchCosts(for ids: [String]) async {
        isFetchingCosts = true
        defer { isFetchingCosts = false }
        let results = await withTaskGroup(of: (String, CodexBarCostResult?).self) { group in
            for id in ids {
                group.addTask {
                    guard let data = await XPCHelperClient.shared.codexBarCost(provider: id),
                          let decoded = try? CodexBarDecoding.decoder.decode([CodexBarCostResult].self, from: data)
                    else { return (id, nil) }
                    return (id, decoded.first { $0.provider == id } ?? decoded.first)
                }
            }
            var collected: [String: CodexBarCostResult] = [:]
            for await (id, result) in group { if let result { collected[id] = result } }
            return collected
        }
        log.info("costs: requested=\(ids, privacy: .public) got=\(results.mapValues { Int($0.last30DaysTokens ?? -1) }, privacy: .public)")
        costResults.merge(results) { _, new in new }
        lastCostFetch = Date()
        rebuild()
    }

    func openCodexBar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            NSWorkspace.shared.open(URL(string: "https://github.com/steipete/CodexBar")!)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: CLI enrichment

    private func fetchCLIDetails(only subset: [String]? = nil) async {
        let ids = subset ?? providerIDs
        guard !ids.isEmpty else { return }
        isFetchingDetails = true
        defer { isFetchingDetails = false }

        // One CLI process per enabled provider, in parallel. `--provider all` probes
        // every provider CodexBar knows about and is an order of magnitude slower.
        let results = await withTaskGroup(of: (String, CodexBarCLIResult?).self) { group in
            for id in ids {
                group.addTask {
                    guard let data = await XPCHelperClient.shared.codexBarUsage(provider: id),
                          let decoded = try? CodexBarDecoding.decoder.decode([CodexBarCLIResult].self, from: data)
                    else { return (id, nil) }
                    return (id, decoded.first { $0.provider == id } ?? decoded.first)
                }
            }
            var collected: [String: CodexBarCLIResult] = [:]
            for await (id, result) in group {
                if let result { collected[id] = result }
            }
            return collected
        }

        log.info("cli usage: requested=\(ids, privacy: .public) got=\(results.keys.sorted(), privacy: .public)")
        cliResults.merge(results) { _, new in new }
        lastCLIFetch = Date()
        rebuild()
    }

    // MARK: Merge

    private var providerIDs: [String] {
        if !configProviders.isEmpty { return configProviders }
        if let enabled = snapshot?.enabledProviders, !enabled.isEmpty { return enabled }
        if let entries = snapshot?.entries, !entries.isEmpty { return entries.map(\.provider) }
        return ["codex", "claude"]
    }

    private func rebuild() {
        let entriesByID = Dictionary((snapshot?.entries ?? []).map { ($0.provider, $0) }, uniquingKeysWith: { a, _ in a })

        let merged: [AIProviderUsage] = providerIDs.compactMap { id in
            let entry = entriesByID[id]
            let cli = cliResults[id]
            let cost = costResults[id]
            let activeAccountBars = Self.activeAccountBars(provider: id, payload: accountsPayload)
            // claude-swap rows don't need the active account to have a record yet.
            let hasSwapRows = id == "claude" && !(accountsPayload?.claudeSwapAccounts.isEmpty ?? true)
            guard entry != nil || cli?.usage != nil || !activeAccountBars.isEmpty || hasSwapRows else { return nil }

            var usage = AIProviderUsage(id: id)
            usage.account = cli?.usage?.accountEmail
            usage.plan = cli?.usage?.loginMethod.map(Self.prettyPlan)
            usage.updatedAt = [entry?.updatedAt, cli?.usage?.updatedAt].compactMap { $0 }.max()
            usage.bars = Self.bars(entry: entry, cli: cli)
            if usage.bars.isEmpty { usage.bars = activeAccountBars }
            // 5-hour session limits no longer exist; hide any leftover 5h windows.
            usage.bars.removeAll { $0.windowMinutes == 300 }
            usage.todayCost = entry?.tokenUsage?.sessionCostUSD ?? cost?.sessionCostUSD
            usage.todayTokens = entry?.tokenUsage?.sessionTokens ?? cost?.sessionTokens
            usage.last30Cost = entry?.tokenUsage?.last30DaysCostUSD ?? cost?.last30DaysCostUSD
            usage.last30Tokens = entry?.tokenUsage?.last30DaysTokens ?? cost?.last30DaysTokens
            // Only surface the label when it says something beyond "30d" (e.g. "API est. · not billed").
            usage.costLabel = entry?.tokenUsage?.last30DaysLabel.flatMap { $0.trimmingCharacters(in: .whitespaces) == "30d" ? nil : $0 }
            if let days = entry?.dailyUsage {
                usage.daily = days.map { AIDailyPoint(dayKey: $0.dayKey, cost: $0.costUSD ?? 0, tokens: $0.totalTokens ?? 0) }
            } else if let days = cost?.daily {
                usage.daily = days.map { AIDailyPoint(dayKey: $0.date, cost: $0.totalCost ?? 0, tokens: $0.totalTokens ?? 0) }
                if usage.costLabel == nil, cost?.provenance == "listPriceEstimate" {
                    usage.costLabel = "Estimated at API list prices"
                }
            }
            usage.resetCreditsAvailable = cli?.resetCredits?.available
            if usage.bars.isEmpty, entry == nil { usage.errorMessage = cli?.error?.message }
            return usage
        }

        providers = merged
        loadIcons(for: merged.map(\.id))
        accounts = Self.sortForPicking(Self.buildAccounts(providers: merged, payload: accountsPayload))
        UsageHistoryStore.shared.record(accounts)
        lastUpdated = [snapshot?.generatedAt, lastCLIFetch].compactMap { $0 }.max()
        status = merged.isEmpty ? .noSnapshot : .ready
    }

    private static func bars(entry: CodexBarSnapshot.Entry?, cli: CodexBarCLIResult?) -> [AIUsageBar] {
        // Prefer the CLI: it carries labels, pace and provider-specific extra windows.
        if let usage = cli?.usage {
            var bars: [AIUsageBar] = []
            let slots: [(String, CodexBarRateWindow?)] = [
                ("primary", usage.primary), ("secondary", usage.secondary), ("tertiary", usage.tertiary),
            ]
            for (slot, window) in slots {
                guard let window, let used = window.usedPercent else { continue }
                let pace = cli?.pace?[slot]
                bars.append(AIUsageBar(
                    id: slot,
                    title: cli?.rateWindowLabels?[slot] ?? defaultTitle(slot: slot, minutes: window.windowMinutes),
                    usedPercent: used,
                    resetsAt: window.resetsAt,
                    resetDescription: window.resetDescription,
                    windowMinutes: window.windowMinutes,
                    expectedPercent: pace?.expectedUsedPercent,
                    paceSummary: pace?.summary,
                    willLastToReset: pace?.willLastToReset,
                    etaSeconds: pace?.etaSeconds
                ))
            }
            for extra in usage.extraRateWindows ?? [] {
                guard let used = extra.window?.usedPercent else { continue }
                bars.append(AIUsageBar(
                    id: extra.id, title: extra.title, usedPercent: used,
                    resetsAt: extra.window?.resetsAt, resetDescription: extra.window?.resetDescription,
                    windowMinutes: extra.window?.windowMinutes,
                    expectedPercent: nil, paceSummary: nil, willLastToReset: nil, etaSeconds: nil
                ))
            }
            if !bars.isEmpty { return bars }
        }

        // Snapshot fallback: `usageRows` is exactly what CodexBar's widget renders.
        guard let entry else { return [] }
        return (entry.usageRows ?? []).compactMap { row in
            let window = row.window ?? entry.window(named: row.id)
            guard let used = window?.usedPercent ?? row.percentLeft.map({ 100 - $0 }) else { return nil }
            return AIUsageBar(
                id: row.id, title: row.title, usedPercent: used,
                resetsAt: window?.resetsAt, resetDescription: window?.resetDescription,
                windowMinutes: window?.windowMinutes,
                expectedPercent: nil, paceSummary: nil, willLastToReset: nil, etaSeconds: nil
            )
        }
    }

    // MARK: Logos

    /// CodexBar's monochrome provider logos (template images), loaded once via the helper.
    @Published private(set) var icons: [String: NSImage] = [:]
    private var requestedIcons: Set<String> = []

    private func loadIcons(for ids: [String]) {
        for id in ids where !requestedIcons.contains(id) {
            requestedIcons.insert(id)
            Task {
                guard let data = await XPCHelperClient.shared.codexBarIcon(provider: id),
                      let image = NSImage(data: data) else { return }
                image.isTemplate = true
                icons[id] = image
            }
        }
    }

    // MARK: Accounts

    private var lastActiveSwap: String?

    /// Stores new per-account data and announces claude-swap switches in the notch.
    private func ingest(_ payload: CodexBarAccountsPayload) {
        let active = payload.claudeSwap?.active
        if let previous = lastActiveSwap, let active, active != previous, Defaults[.showAccountSwapPeek] {
            let info = payload.claudeSwap?.accounts[active]
            let name = info?.email.flatMap { $0.split(separator: "@").first.map(String.init) } ?? "account \(active)"
            let kind = info?.organizationName.map { $0.hasSuffix("'s Organization") ? "Personal" : "Team" }
            let coordinator = BoringViewCoordinator.shared
            coordinator.accountSwapMessage = "Claude → \(name)" + (kind.map { " · \($0)" } ?? "")
            coordinator.toggleSneakPeek(status: true, type: .accountSwap, duration: 3)
        }
        if let active { lastActiveSwap = active }
        accountsPayload = payload
    }

    /// "soon" = the reset is usable today or tomorrow (countdown / Today / Tomorrow label).
    static func pickingGroup(for row: AIAccountUsage, now: Date = Date()) -> String {
        guard let reset = row.weekly?.resetsAt,
              AIUsageFormat.usableDayOffset(reset, now: now) <= 1 else { return "later" }
        return "soon"
    }

    /// Ordering for "which account should I use next":
    ///  1. resets usable today/tomorrow → top, soonest first (that quota refreshes anyway, burn it)
    ///  2. everything else → least used first (most headroom)
    static func sortForPicking(_ rows: [AIAccountUsage], now: Date = Date()) -> [AIAccountUsage] {
        func key(_ row: AIAccountUsage) -> (Int, Double) {
            if pickingGroup(for: row, now: now) == "soon", let reset = row.weekly?.resetsAt {
                return (0, reset.timeIntervalSince(now))
            }
            return (1, row.weekly?.usedPercent ?? 101)
        }
        return rows.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            if ka != kb { return ka < kb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func bar(_ id: String, _ title: String, _ window: CodexBarRateWindow?) -> AIUsageBar? {
        guard let window, let used = window.usedPercent else { return nil }
        return AIUsageBar(
            id: id, title: title, usedPercent: used, resetsAt: window.resetsAt,
            resetDescription: window.resetDescription, windowMinutes: window.windowMinutes,
            expectedPercent: nil, paceSummary: nil, willLastToReset: nil, etaSeconds: nil
        )
    }

    /// 5h / 7d / scoped-7d bars for one claude-swap account.
    private static func claudeBars(_ record: CodexBarAccountsPayload.ClaudeRetained) -> [AIUsageBar] {
        var bars = [bar("secondary", "Weekly", record.secondary)].compactMap { $0 }
        for extra in record.extraRateWindows ?? [] {
            if let b = bar(extra.id, extra.title, extra.window) { bars.append(b) }
        }
        return bars
    }

    private static func activeAccountBars(provider: String, payload: CodexBarAccountsPayload?) -> [AIUsageBar] {
        if provider == "codex", let record = payload?.codex?.first {
            return [bar("primary", "Limit", record.primary), bar("secondary", "Weekly", record.secondary), bar("tertiary", "Limit", record.tertiary)]
                .compactMap { $0 }
        }
        // Only the account claude-swap says is active; never guess with another account's bars.
        guard provider == "claude", let active = payload?.claudeSwapAccounts.first(where: \.isActive) else { return [] }
        return claudeBars(active.usage)
    }

    private static func buildAccounts(providers: [AIProviderUsage], payload: CodexBarAccountsPayload?) -> [AIAccountUsage] {
        var rows: [AIAccountUsage] = []
        let staleAfter: TimeInterval = 6 * 3600

        for provider in providers {
            switch provider.id {
            // One row per claude-swap account. Without claude-swap (or when its list and
            // CodexBar's records don't match) this falls through to the single login below.
            case "claude" where !(payload?.claudeSwapAccounts.isEmpty ?? true):
                for account in payload?.claudeSwapAccounts ?? [] {
                    let id = account.number
                    let record = account.usage
                    let info = account.info
                    let bars = claudeBars(record)
                    let weeklyBars = bars.filter(\.isWeekly)
                    let binding = weeklyBars.max { $0.usedPercent < $1.usedPercent }
                    let org = info.organizationName
                    let badge = org.map { $0.hasSuffix("'s Organization") ? "Personal" : "Team" }
                    let stale = record.usesLastKnownUsage == true
                        || (record.updatedAt.map { Date().timeIntervalSince($0) > staleAfter } ?? false)
                    rows.append(AIAccountUsage(
                        id: "claude-\(id)", provider: "claude",
                        label: info.email ?? "Account \(id)", badge: badge,
                        isActive: account.isActive, isStale: stale,
                        weekly: binding,
                        allModels: weeklyBars.first { !$0.isFable },
                        fable: weeklyBars.first { $0.isFable },
                        session: liveSession(bar("primary", "Session", record.primary))
                    ))
                }

            case "codex" where !(payload?.codex ?? []).isEmpty:
                for record in payload?.codex ?? [] {
                    let all = [bar("primary", "Limit", record.primary), bar("secondary", "Weekly", record.secondary), bar("tertiary", "Limit", record.tertiary)]
                        .compactMap { $0 }
                    let bars = all.filter { $0.windowMinutes != 300 }
                    rows.append(AIAccountUsage(
                        id: "codex-\(record.email ?? UUID().uuidString)", provider: "codex",
                        label: record.email ?? "Codex", badge: record.plan.map(prettyPlan),
                        isActive: (payload?.codex?.count ?? 0) == 1 || record.email == provider.account, isStale: false,
                        weekly: bars.filter(\.isWeekly).max { $0.usedPercent < $1.usedPercent } ?? bars.first,
                        session: liveSession(all.first { $0.windowMinutes == 300 })
                    ))
                }

            default:
                // Single-login providers: use the provider's own bars.
                // Weekly if there is one; otherwise the binding limit (e.g. Cursor's Third Party).
                let weekly = provider.bars.filter(\.isWeekly).max { $0.usedPercent < $1.usedPercent }
                    ?? provider.bars.max { $0.usedPercent < $1.usedPercent }
                rows.append(AIAccountUsage(
                    id: provider.id, provider: provider.id,
                    label: provider.account ?? provider.displayName, badge: provider.plan,
                    isActive: true, isStale: false,
                    weekly: weekly
                ))
            }
        }
        return rows
    }

    /// A 5h window only matters while it's running (has a future reset) and has been used.
    private static func liveSession(_ bar: AIUsageBar?, now: Date = Date()) -> AIUsageBar? {
        guard let bar, bar.windowMinutes == 300, bar.usedPercent > 0,
              let reset = bar.resetsAt, reset > now else { return nil }
        return bar
    }

    private static func defaultTitle(slot: String, minutes: Int?) -> String {
        switch minutes {
        case 300: return "Session"
        case 10080: return "Weekly"
        case .some(let m) where m >= 40000: return "Monthly"
        default: return slot.capitalized
        }
    }

    private static func prettyPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        default: return raw
        }
    }
}

// MARK: - Formatting helpers shared by the views

enum AIUsageFormat {
    static func currency(_ value: Double?, compact: Bool = false) -> String {
        guard let value else { return "—" }
        if compact && value >= 10_000 {
            return String(format: "$%.1fk", value / 1000)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }

    static func tokens(_ value: Double?) -> String {
        guard let value else { return "—" }
        switch value {
        case 1e9...: return String(format: "%.1fB", value / 1e9)
        case 1e6...: return String(format: "%.0fM", value / 1e6)
        case 1e3...: return String(format: "%.0fK", value / 1e3)
        default: return String(Int(value))
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "2d 20h", "6h 35m", "12m"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(1, m))m"
    }

    static func resetText(for bar: AIUsageBar, now: Date = Date()) -> String? {
        if let resetsAt = bar.resetsAt {
            return "Resets in " + duration(resetsAt.timeIntervalSince(now))
        }
        return bar.resetDescription
    }

    /// Resets at or after this hour don't leave enough of the workday to use the quota.
    static let workdayCutoffHour = 15

    /// Reset label for the account list, phrased as *the day you can use it*:
    /// within 6h → countdown ("2h 15m"); before 15:00 → that day ("Today", "Tomorrow",
    /// "Thu"); at/after 15:00 → the next day. More than a week out → date ("Nov 27").
    /// Pass `usable: false` for a plain calendar day (e.g. when a projection stalls).
    /// Days from today until the reset can actually be used (after-15:00 resets count as the next day).
    static func usableDayOffset(_ date: Date, now: Date = Date(), usable: Bool = true) -> Int {
        if date.timeIntervalSince(now) <= 6 * 3600 { return 0 }
        let calendar = Calendar.current
        // Round to the minute: sources report the same reset as 14:59:59 or 15:00:00.3.
        let date = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        var day = calendar.startOfDay(for: date)
        if usable, calendar.component(.hour, from: date) >= workdayCutoffHour {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 99
    }

    static func resetLabel(_ date: Date, now: Date = Date(), usable: Bool = true) -> String {
        let remaining = date.timeIntervalSince(now)
        if remaining <= 6 * 3600 { return duration(remaining) }
        let calendar = Calendar.current
        let days = usableDayOffset(date, now: now, usable: usable)
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? date
        switch days {
        case ...0: return "Today"
        case 1: return "Tomorrow"
        default:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(days <= 7 ? "EEE" : "MMMd")
            return formatter.string(from: day)
        }
    }

    /// Exact reset moment for tooltips: "Tue 15:00" (or "Nov 27 20:59").
    static func exactReset(_ date: Date, now: Date = Date()) -> String {
        let days = date.timeIntervalSince(now) / 86400
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(days < 6.5 ? "EEE HH:mm" : "MMMd HH:mm")
        return formatter.string(from: date)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "just now" }
        return duration(delta) + " ago"
    }
}
