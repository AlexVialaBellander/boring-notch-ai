//
//  CodexBarStrip.swift
//  boringNotch
//
//  Slim row under the closed notch, like CodexBar's menu-bar items
//  (logo + %) but aggregated across every account per provider.
//  Adds height only — the notch never gets wider.
//

import SwiftUI

struct CodexBarStrip: View {
    static let height: CGFloat = 14

    let stats: [CodexBarManager.StripStat]
    @ObservedObject private var manager = CodexBarManager.shared

    var body: some View {
        HStack(spacing: 10) {
            ForEach(stats) { stat in
                HStack(spacing: 3) {
                    ProviderLogo(provider: stat.provider, size: 10)
                        .foregroundStyle(Color.white.opacity(0.9))
                    Text(AIUsageFormat.percent(stat.usedPercent))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(stat.usedPercent >= 90 ? Color.red.opacity(0.95) : Color.white.opacity(0.85))
                }
                .help("\(AIProviderStyle.name(for: stat.provider)): \(AIUsageFormat.percent(stat.usedPercent)) used on average across \(stat.accounts) account\(stat.accounts == 1 ? "" : "s")")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

}

/// CodexBar's real provider logo; a coloured dot until it has loaded.
struct ProviderLogo: View {
    let provider: String
    var size: CGFloat = 10
    @ObservedObject private var manager = CodexBarManager.shared

    var body: some View {
        if let image = manager.icons[provider] {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(AIProviderStyle.tint(for: provider))
                .frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
        }
    }
}
