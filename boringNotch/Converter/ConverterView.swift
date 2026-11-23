//
//  ConverterView.swift
//  boringNotch
//
//  The Convert tab: drop → choose format/options → convert → drag results out.
//

import Defaults
import SwiftUI
import UniformTypeIdentifiers

private let fileDropTypes: [UTType] = [.fileURL, .item]

struct ConverterView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var model = ConverterViewModel.shared
    @State private var isTargeted = false

    var body: some View {
        Group {
            switch model.phase {
            case .empty: emptyState
            case .choosing: ConverterOptionsView(isTargeted: $isTargeted)
            case .converting: progressState
            case .done: ConverterResultsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: model.phase)
        .onDrop(of: fileDropTypes, isTargeted: $isTargeted) { providers in
            guard model.phase != .converting else { return false }
            vm.dropEvent = true
            model.load(providers)
            return true
        }
        .onChange(of: isTargeted) { _, targeted in
            vm.converterDropTargeting = targeted
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                isTargeted ? Color.effectiveAccent.opacity(0.9) : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isTargeted ? Color.effectiveAccent : .gray)
                        .scaleEffect(isTargeted ? 1.1 : 1)
                    Text("Drop files to convert")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundStyle(.gray)
                    Text("Images · PDF · Video · Audio · Documents — or click to choose")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.chooseFiles() }
    }

    // MARK: Progress

    private var progressState: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.02, model.progress))
                    .stroke(Color.effectiveAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: model.progress)
                Text("\(Int(model.progress * 100))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Converting \(model.convertibleFiles.count) file\(model.convertibleFiles.count == 1 ? "" : "s") to \(model.selectedFormat?.label ?? "…")")
                    .font(.system(size: 14, weight: .semibold))
                Text("Everything stays on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Options

private struct ConverterOptionsView: View {
    @ObservedObject private var model = ConverterViewModel.shared
    @Default(.converterOutputLocation) private var outputLocation
    @Binding var isTargeted: Bool

    private let columns = [GridItem(.adaptive(minimum: 56, maximum: 90), spacing: 6)]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            fileColumn.frame(width: 150)
            formatGrid.frame(maxWidth: .infinity)
            optionsColumn.frame(width: 132)
        }
    }

    // Files

    private var fileColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: -18) {
                ForEach(Array(model.files.prefix(3).enumerated()), id: \.offset) { index, url in
                    FileThumbnail(url: url, size: 40)
                        .rotationEffect(.degrees(Double(index) * 6 - 6))
                        .zIndex(Double(-index))
                }
            }
            .frame(height: 44)
            .padding(.leading, 4)

            Text(summary)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.files, id: \.self) { url in
                        HStack(spacing: 4) {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(ConversionCategory.classify(url) == nil ? .tertiary : .secondary)
                            Spacer(minLength: 2)
                            Button { model.remove(url) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 10))
                    }
                }
            }

            HStack(spacing: 10) {
                Button { model.chooseFiles() } label: { Label("Add", systemImage: "plus") }
                Button { model.reset() } label: { Label("Clear", systemImage: "trash") }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isTargeted ? Color.effectiveAccent.opacity(0.9) : .clear, style: StrokeStyle(lineWidth: 2, dash: [6]))
                )
        )
    }

    private var summary: String {
        let count = model.convertibleFiles.count
        let categories = model.categories
        var text: String
        if categories.count == 1, let only = categories.first {
            text = "\(count) \(only.label.lowercased())\(count == 1 ? "" : "s")"
        } else {
            text = "\(count) files · " + categories.map(\.label).sorted().joined(separator: " + ")
        }
        if !model.unsupportedFiles.isEmpty { text += " · \(model.unsupportedFiles.count) skipped" }
        return text
    }

    // Formats

    @ViewBuilder
    private var formatGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Convert to")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if model.availableFormats.isEmpty {
                Text(model.convertibleFiles.isEmpty
                     ? "These files can't be converted yet."
                     : "These files have no output format in common. Convert them in separate batches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.availableFormats) { format in
                        FormatTile(format: format, selected: model.selectedFormat == format) {
                            withAnimation(.smooth(duration: 0.15)) { model.selectedFormat = format }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // Options

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let format = model.selectedFormat {
                if format.usesQuality {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Text("\(Int(model.options.quality * 100))%").monospacedDigit()
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        Slider(value: $model.options.quality, in: 0.3...1)
                            .controlSize(.mini)
                    }
                }
                if format.usesResize {
                    optionRow("Size") {
                        Picker("", selection: $model.options.resize) {
                            ForEach(ResizeOption.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                if format.usesVideoQuality {
                    optionRow("Quality") {
                        Picker("", selection: $model.options.videoQuality) {
                            ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                if format == .imagePDF && model.convertibleFiles.count > 1 {
                    Toggle("Combine into one PDF", isOn: $model.options.combineIntoOne)
                        .font(.system(size: 10))
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                }
                if format.imageUTType != nil && model.categories == [.image] {
                    Toggle("Keep metadata", isOn: Binding(
                        get: { !model.options.stripMetadata },
                        set: { model.options.stripMetadata = !$0 }
                    ))
                    .font(.system(size: 10))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                }
            }

            Spacer(minLength: 0)

            Button(action: model.convert) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Convert")
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Capsule().fill(model.selectedFormat == nil ? Color.gray.opacity(0.3) : Color.effectiveAccent))
                .foregroundStyle(.white)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.selectedFormat == nil || model.convertibleFiles.isEmpty)

            Menu {
                Picker("Save to", selection: $outputLocation) {
                    ForEach(ConverterOutputLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("→ \(outputLocation.rawValue)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(maxWidth: .infinity)
        }
    }

    private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
        }
    }
}

private struct FormatTile: View {
    let format: OutputFormat
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(format.label)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                Text(format.subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.effectiveAccent.opacity(0.85) : Color.white.opacity(hovering ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.white.opacity(0.35) : .clear, lineWidth: 1)
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Results

private struct ConverterResultsView: View {
    @ObservedObject private var model = ConverterViewModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                let ok = model.successfulResults.count
                let failed = model.failedResults.count
                Label(
                    ok > 0 ? "\(ok) file\(ok == 1 ? "" : "s") ready" : "Conversion failed",
                    systemImage: ok > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ok > 0 ? Color.green : Color.orange)

                if failed > 0 {
                    Text(model.failedResults.first?.error ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.9))
                        .lineLimit(2)
                    if failed > 1 {
                        Text("+\(failed - 1) more failed")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Drag a result anywhere, or double-click to open.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let summary = model.saveSummary {
                    Label(summary, systemImage: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if ok > 0 {
                        Button("Show in Finder", action: model.revealResults)
                    }
                    Button("Again", action: model.convertAgain)
                    Button("Done", action: model.reset)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(width: 200, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.successfulResults) { result in
                        ResultTile(result: result)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct ResultTile: View {
    let result: ConverterViewModel.Result
    @ObservedObject private var model = ConverterViewModel.shared
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            FileThumbnail(url: result.temporary ?? result.delivered ?? result.source, size: 64)
                .scaleEffect(hovering ? 1.05 : 1)
            Text(result.delivered?.lastPathComponent ?? "")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 84)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture(count: 2) { model.open(result) }
        .onDrag {
            NSItemProvider(object: (result.delivered ?? result.temporary ?? result.source) as NSURL)
        }
        .help(result.delivered?.path ?? "")
    }
}

// MARK: - Thumbnail

struct FileThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: url.hasDirectoryPath
                      ? NSWorkspace.shared.icon(for: .folder)
                      : NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        .task(id: url) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            image = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: size, height: size))
        }
    }
}
