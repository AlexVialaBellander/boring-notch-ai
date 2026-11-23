//
//  ConverterViewModel.swift
//  boringNotch
//
//  State for the Convert tab: drop → pick format/options → convert → results.
//

import AppKit
import Combine
import Defaults
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ConverterViewModel: ObservableObject {
    static let shared = ConverterViewModel()

    enum Phase: Equatable {
        case empty
        case choosing
        case converting
        case done
    }

    struct Result: Identifiable {
        let id = UUID()
        let source: URL
        /// Copy inside our temp folder (always readable; used for thumbnails).
        let temporary: URL?
        /// Where the user will find it.
        let delivered: URL?
        let error: String?
    }

    @Published private(set) var files: [URL] = []
    @Published private(set) var phase: Phase = .empty
    @Published var selectedFormat: OutputFormat?
    @Published var options = ConversionOptions()
    @Published private(set) var progress: Double = 0
    @Published private(set) var results: [Result] = []
    @Published private(set) var isLoadingDrop = false
    /// Human-readable "where did my files go" line for the results screen.
    @Published private(set) var saveSummary: String?

    private var conversionTask: Task<Void, Never>?
    private var workDirectory: URL?

    private init() {
        Self.purgeStaleWorkDirectories()
    }

    // MARK: Derived

    var categories: Set<ConversionCategory> { Set(files.compactMap(ConversionCategory.classify)) }

    var unsupportedFiles: [URL] { files.filter { ConversionCategory.classify($0) == nil } }

    var convertibleFiles: [URL] { files.filter { ConversionCategory.classify($0) != nil } }

    var availableFormats: [OutputFormat] {
        let formats = OutputFormat.formats(for: categories)
        // Merging only makes sense for several files.
        return convertibleFiles.count > 1 ? formats : formats.filter { !$0.isMerging }
    }

    var hasWork: Bool { phase != .empty }

    var successfulResults: [Result] { results.filter { $0.delivered != nil } }

    var failedResults: [Result] { results.filter { $0.error != nil } }

    // MARK: Intake

    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoadingDrop = true
        Task {
            var urls: [URL] = []
            for provider in providers {
                var url = await provider.extractFileURL()
                if url == nil { url = await provider.extractItem() }
                if let url, url.isFileURL { urls.append(url) }
            }
            self.isLoadingDrop = false
            self.add(urls)
        }
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if phase == .done { reset() }
        guard phase != .converting else { return }

        let existing = Set(files.map(\.standardizedFileURL))
        files += urls.filter { !existing.contains($0.standardizedFileURL) && !$0.hasDirectoryPath }
        phase = files.isEmpty ? .empty : .choosing
        pickDefaultFormat()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        if files.isEmpty { reset() } else { pickDefaultFormat() }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose files to convert"
        panel.level = .popUpMenu
        SharingStateManager.shared.preventNotchClose = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                SharingStateManager.shared.preventNotchClose = false
                if response == .OK { self?.add(panel.urls) }
            }
        }
    }

    private func pickDefaultFormat() {
        let formats = availableFormats
        if let selected = selectedFormat, formats.contains(selected) { return }
        // Prefer a format that actually changes the first file.
        let first = convertibleFiles.first
        selectedFormat = formats.first { format in
            guard let first else { return true }
            return !format.isSameFormat(as: first) && !format.isMerging
        } ?? formats.first
    }

    // MARK: Convert

    func convert() {
        guard let format = selectedFormat, !convertibleFiles.isEmpty, phase == .choosing else { return }
        let sources = convertibleFiles
        let options = self.options
        let location = Defaults[.converterOutputLocation]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boringNotch-converter-\(UUID().uuidString.prefix(8))", isDirectory: true)
        workDirectory = dir

        phase = .converting
        progress = 0
        results = []

        conversionTask = Task { [weak self] in
            let outcomes = await FileConverterService.convert(sources, to: format, options: options, workDirectory: dir) { value in
                Task { @MainActor in self?.progress = value }
            }
            guard !Task.isCancelled else { return }

            guard let self, !Task.isCancelled else { return }
            var delivery = Delivery(location: location)
            var results: [Result] = []
            for outcome in outcomes {
                if let error = outcome.error {
                    results.append(Result(source: outcome.source, temporary: nil, delivered: nil, error: error))
                    continue
                }
                for output in outcome.outputs {
                    let delivered = await delivery.deliver(output, source: outcome.source)
                    results.append(Result(
                        source: outcome.source, temporary: output, delivered: delivered,
                        error: delivered == nil ? "Couldn't save \(output.lastPathComponent) — drag it out from here instead" : nil
                    ))
                }
            }

            guard !Task.isCancelled else { return }
            self.saveSummary = delivery.summary
            self.results = results
            self.progress = 1
            self.phase = .done
            self.conversionTask = nil
        }
    }

    func cancel() {
        conversionTask?.cancel()
        conversionTask = nil
        phase = files.isEmpty ? .empty : .choosing
        progress = 0
    }

    /// Back to the options screen with the same files (e.g. to try another format).
    func convertAgain() {
        results = []
        saveSummary = nil
        progress = 0
        phase = files.isEmpty ? .empty : .choosing
    }

    func reset() {
        conversionTask?.cancel()
        conversionTask = nil
        files = []
        results = []
        saveSummary = nil
        progress = 0
        phase = .empty
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
    }

    // MARK: Results

    func revealResults() {
        let urls = successfulResults.compactMap(\.delivered)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ result: Result) {
        guard let url = result.delivered else { return }
        if !NSWorkspace.shared.open(url), let temporary = result.temporary {
            NSWorkspace.shared.open(temporary)
        }
    }

    // MARK: Delivery

    /// Per-batch delivery state, so we ask for folder access at most once per folder.
    private struct Delivery {
        let location: ConverterOutputLocation
        private var declined: Set<String> = []
        private var destinations: [String: Int] = [:]

        init(location: ConverterOutputLocation) { self.location = location }

        @MainActor
        mutating func deliver(_ output: URL, source: URL) async -> URL? {
            let downloads = ConverterViewModel.realHomeDirectory.appendingPathComponent("Downloads", isDirectory: true)
            let preferred = location == .nextToOriginal ? source.deletingLastPathComponent() : downloads

            if let url = ConverterFolderAccess.copy(output, into: preferred) {
                note(preferred); return url
            }
            // First time saving into this folder: ask once, then retry.
            if location == .nextToOriginal, !declined.contains(preferred.path) {
                if await ConverterFolderAccess.requestAccess(to: preferred),
                   let url = ConverterFolderAccess.copy(output, into: preferred) {
                    note(preferred); return url
                }
                declined.insert(preferred.path)
            }
            // Fallback: Downloads (covered by the sandbox entitlement).
            if preferred != downloads, let url = ConverterFolderAccess.copy(output, into: downloads) {
                note(downloads); return url
            }
            return nil
        }

        private mutating func note(_ dir: URL) { destinations[dir.path, default: 0] += 1 }

        var summary: String? {
            guard !destinations.isEmpty else { return nil }
            let names = destinations.keys.sorted().map { path -> String in
                let url = URL(fileURLWithPath: path)
                return url.lastPathComponent == "Downloads" && location == .downloads ? "Downloads" : "“\(url.lastPathComponent)”"
            }
            return "Saved to " + names.joined(separator: ", ")
        }
    }

    /// `NSHomeDirectory()` points inside the sandbox container; we want the user's real home.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func purgeStaleWorkDirectories() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("boringNotch-converter-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
