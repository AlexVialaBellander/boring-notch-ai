//
//  FileConverterService.swift
//  boringNotch
//
//  Local, sandbox-friendly conversions using only system frameworks.
//  Every conversion writes into a private temp folder; delivery to the
//  user's chosen location happens afterwards in ConverterViewModel.
//

import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ConversionError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn't read \(name)"
        case .unsupported(let message): return message
        case .failed(let message): return message
        }
    }
}

struct ConversionOutcome: Identifiable {
    let id = UUID()
    let source: URL
    var outputs: [URL] = []
    var error: String?
}

enum FileConverterService {

    typealias Progress = @Sendable (Double) -> Void

    /// Converts `sources` into `format`. Returns one outcome per source (or a single
    /// outcome for merging formats). Never throws: failures are reported per file.
    static func convert(
        _ sources: [URL],
        to format: OutputFormat,
        options: ConversionOptions,
        workDirectory: URL,
        progress: @escaping Progress
    ) async -> [ConversionOutcome] {
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        // Many-to-one conversions.
        if format == .pdfMerge || (format == .imagePDF && options.combineIntoOne && sources.count > 1) {
            var outcome = ConversionOutcome(source: sources[0])
            do {
                let name = sources.count > 1 ? "\(sources[0].deletingPathExtension().lastPathComponent) + \(sources.count - 1) more" : sources[0].deletingPathExtension().lastPathComponent
                let output = uniqueURL(in: workDirectory, base: name, ext: "pdf")
                try await withScopedAccess(sources) {
                    if format == .pdfMerge {
                        try mergePDFs(sources, to: output)
                    } else {
                        try imagesToPDF(sources, options: options, to: output)
                    }
                }
                outcome.outputs = [output]
            } catch {
                outcome.error = error.localizedDescription
            }
            progress(1)
            return [outcome]
        }

        var outcomes: [ConversionOutcome] = []
        for (index, source) in sources.enumerated() {
            var outcome = ConversionOutcome(source: source)
            let base = Double(index) / Double(sources.count)
            let span = 1 / Double(sources.count)
            do {
                outcome.outputs = try await withScopedAccess([source]) {
                    try await convertOne(source, to: format, options: options, in: workDirectory) { fraction in
                        progress(base + span * fraction)
                    }
                }
            } catch {
                outcome.error = error.localizedDescription
            }
            outcomes.append(outcome)
            progress(base + span)
        }
        return outcomes
    }

    // MARK: - Dispatch

    private static func convertOne(_ source: URL, to format: OutputFormat, options: ConversionOptions, in dir: URL, progress: @escaping Progress) async throws -> [URL] {
        let base = source.deletingPathExtension().lastPathComponent
        guard let category = ConversionCategory.classify(source),
              OutputFormat.formats(for: category).contains(format) else {
            throw ConversionError.unsupported("\(source.lastPathComponent) can't become \(format.label)")
        }

        switch format {
        case .jpeg, .png, .heic, .webp, .tiff, .gif, .bmp:
            let output = uniqueURL(in: dir, base: base, ext: format.fileExtension)
            try convertImage(source, to: format, options: options, output: output)
            return [output]

        case .imagePDF:
            let output = uniqueURL(in: dir, base: base, ext: "pdf")
            try imagesToPDF([source], options: options, to: output)
            return [output]

        case .pdfToPNG, .pdfToJPEG:
            return try pdfToImages(source, format: format, options: options, in: dir)

        case .pdfToText:
            guard let document = PDFDocument(url: source) else { throw ConversionError.unreadable(source.lastPathComponent) }
            let output = uniqueURL(in: dir, base: base, ext: "txt")
            try (document.string ?? "").write(to: output, atomically: true, encoding: .utf8)
            return [output]

        case .mp4, .hevc, .mov, .extractAudio, .m4a:
            let output = uniqueURL(in: dir, base: base, ext: format.fileExtension)
            try await exportAV(source, format: format, quality: options.videoQuality, output: output, progress: progress)
            return [output]

        case .wav, .aiff:
            let output = uniqueURL(in: dir, base: base, ext: format.fileExtension)
            try await exportPCM(source, fileType: format == .wav ? .wav : .aiff, output: output, progress: progress)
            return [output]

        case .videoGIF:
            let output = uniqueURL(in: dir, base: base, ext: "gif")
            try await videoToGIF(source, quality: options.videoQuality, output: output, progress: progress)
            return [output]

        case .docx, .rtf, .html, .txt, .odt, .docPDF:
            let output = uniqueURL(in: dir, base: base, ext: format.fileExtension)
            try await convertDocument(source, to: format, output: output)
            return [output]

        case .pdfMerge:
            throw ConversionError.unsupported("Merge needs several PDFs")
        }
    }

    // MARK: - Images

    /// Decodes an image with EXIF orientation baked in, optionally downscaled.
    static func loadImage(_ url: URL, maxPixel: Int?) -> (image: CGImage, properties: [CFString: Any])? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let native = max(width, height)
            // Never upscale; the thumbnail API is also what applies EXIF orientation for us.
            let target = min(maxPixel ?? native, native)
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, target),
            ]
            if native > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                return (image, props)
            }
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return (image, props)
            }
        }
        // Fallback for formats ImageIO can't decode but AppKit can (e.g. SVG).
        if let nsImage = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: nsImage.size)
            if let maxPixel, max(rect.width, rect.height) > CGFloat(maxPixel) {
                let scale = CGFloat(maxPixel) / max(rect.width, rect.height)
                rect.size = CGSize(width: rect.width * scale, height: rect.height * scale)
            } else {
                // Vector sources: render at 2x for a crisp raster.
                rect.size = CGSize(width: rect.width * 2, height: rect.height * 2)
            }
            if let image = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return (image, [:])
            }
        }
        return nil
    }

    private static func convertImage(_ source: URL, to format: OutputFormat, options: ConversionOptions, output: URL) throws {
        guard let type = format.imageUTType else { throw ConversionError.unsupported("Unsupported image format") }
        guard let (decoded, sourceProps) = loadImage(source, maxPixel: options.resize.maxPixel) else {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        let image = (type == .jpeg || type == .bmp) ? flattenAlpha(decoded) : decoded
        try writeImage(image, type: type, quality: format.usesQuality ? options.quality : nil, metadata: options.stripMetadata ? nil : sourceProps, to: output)
    }

    private static func writeImage(_ image: CGImage, type: UTType, quality: Double?, metadata: [CFString: Any]?, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.unsupported("This Mac can't write \(type.preferredFilenameExtension?.uppercased() ?? "that format")")
        }
        var props: [CFString: Any] = [:]
        if let metadata {
            props = metadata
            // Orientation and size were baked in when decoding.
            props.removeValue(forKey: kCGImagePropertyOrientation)
            props.removeValue(forKey: kCGImagePropertyPixelWidth)
            props.removeValue(forKey: kCGImagePropertyPixelHeight)
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failed("Couldn't encode \(output.lastPathComponent)")
        }
    }

    /// JPEG/BMP have no alpha; composite onto white instead of the default black.
    private static func flattenAlpha(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private static func imagesToPDF(_ sources: [URL], options: ConversionOptions, to output: URL) throws {
        let document = PDFDocument()
        for source in sources {
            guard let (image, _) = loadImage(source, maxPixel: options.resize.maxPixel) else {
                throw ConversionError.unreadable(source.lastPathComponent)
            }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            guard let page = PDFPage(image: nsImage) else { throw ConversionError.failed("Couldn't create a PDF page") }
            document.insert(page, at: document.pageCount)
        }
        guard document.write(to: output) else { throw ConversionError.failed("Couldn't write PDF") }
    }

    // MARK: - PDF

    private static func pdfToImages(_ source: URL, format: OutputFormat, options: ConversionOptions, in dir: URL) throws -> [URL] {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        guard let type = format.imageUTType else { throw ConversionError.unsupported("Unsupported image format") }
        let base = source.deletingPathExtension().lastPathComponent
        // Several pages → collect them in "<name> (PNG)/" so they land as one folder next to the original.
        let multiPage = document.pageCount > 1
        let pageDir = multiPage ? uniqueURL(in: dir, base: "\(base) (\(format.label))", ext: "") : dir
        if multiPage { try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true) }
        var outputs: [URL] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 144 dpi by default; honour the resize option on the long edge.
            var scale: CGFloat = 2
            if let maxPixel = options.resize.maxPixel {
                scale = min(scale, CGFloat(maxPixel) / max(bounds.width, bounds.height))
            }
            let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { continue }

            let name = multiPage ? "Page \(index + 1)" : base
            let output = uniqueURL(in: pageDir, base: name, ext: format.fileExtension)
            try writeImage(image, type: type, quality: format.usesQuality ? options.quality : nil, metadata: nil, to: output)
            outputs.append(output)
        }
        if outputs.isEmpty { throw ConversionError.failed("No pages rendered") }
        return multiPage ? [pageDir] : outputs
    }

    private static func mergePDFs(_ sources: [URL], to output: URL) throws {
        let merged = PDFDocument()
        for source in sources {
            guard let document = PDFDocument(url: source) else { throw ConversionError.unreadable(source.lastPathComponent) }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard merged.pageCount > 0, merged.write(to: output) else { throw ConversionError.failed("Couldn't write merged PDF") }
    }

    // MARK: - Audio / video

    private static func exportAV(_ source: URL, format: OutputFormat, quality: VideoQuality, output: URL, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: source)
        let preset: String
        let fileType: AVFileType
        switch format {
        case .mp4, .mov:
            preset = [.high: AVAssetExportPresetHighestQuality, .medium: AVAssetExportPreset1920x1080, .low: AVAssetExportPreset1280x720][quality]!
            fileType = format == .mov ? .mov : .mp4
        case .hevc:
            preset = quality == .high ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHEVC1920x1080
            fileType = .mp4
        default:
            preset = AVAssetExportPresetAppleM4A
            fileType = .m4a
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.unsupported("Can't convert \(source.lastPathComponent) to \(format.label)")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = fileType != .m4a

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poller.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }

        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw ConversionError.failed(session.error?.localizedDescription ?? "Export failed")
        }
    }

    private static func exportPCM(_ source: URL, fileType: AVFileType, output: URL, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ConversionError.unsupported("\(source.lastPathComponent) has no audio") }
        let duration = try await asset.load(.duration).seconds

        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: fileType == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else { throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read audio") }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "boringNotch.converter.pcm")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if duration > 0 {
                            progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration))
                        }
                        input.append(buffer)
                    } else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ConversionError.failed(writer.error?.localizedDescription ?? "Couldn't write audio")
        }
    }

    private static func videoToGIF(_ source: URL, quality: VideoQuality, output: URL, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw ConversionError.unreadable(source.lastPathComponent) }

        let (fps, maxWidth): (Double, CGFloat) = switch quality {
        case .high: (15, 640)
        case .medium: (12, 480)
        case .low: (10, 320)
        }
        // GIFs get huge fast; cap at 30s.
        let clip = min(duration, 30)
        let frameCount = max(1, Int(clip * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ConversionError.failed("Couldn't create GIF")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(destination, image, frameProps)
            progress(Double(index + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("Couldn't encode GIF") }
    }

    // MARK: - Documents

    private static func convertDocument(_ source: URL, to format: OutputFormat, output: URL) async throws {
        let text = try loadAttributedString(source)
        let range = NSRange(location: 0, length: text.length)

        switch format {
        case .txt:
            try text.string.write(to: output, atomically: true, encoding: .utf8)
        case .docPDF:
            try await MainActor.run { try renderPDF(text, to: output) }
        default:
            let type: NSAttributedString.DocumentType = switch format {
            case .docx: .officeOpenXML
            case .rtf: .rtf
            case .html: .html
            case .odt: .openDocument
            default: .plain
            }
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: output)
        }
    }

    private static func loadAttributedString(_ url: URL) throws -> NSAttributedString {
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            return try renderMarkdown(String(contentsOf: url, encoding: .utf8))
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
    }

    /// Foundation parses Markdown into presentation intents that AppKit's writers ignore,
    /// so map blocks/inline styles onto real fonts + paragraph breaks ourselves.
    private static func renderMarkdown(_ markdown: String) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
        let output = NSMutableAttributedString()
        let bodySize: CGFloat = 12
        var lastBlock: Int?

        for run in parsed.runs {
            // Paragraph break whenever we enter a new block.
            let block = run.presentationIntent?.components.first?.identity
            if let lastBlock, block != lastBlock { output.append(NSAttributedString(string: "\n\n")) }
            lastBlock = block

            var size = bodySize
            var traits: NSFontDescriptor.SymbolicTraits = []
            var prefix = ""
            for component in run.presentationIntent?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    size = [24, 20, 17, 15, 13, 12][min(max(level, 1), 6) - 1]
                    traits.insert(.bold)
                case .listItem(let ordinal):
                    if prefix.isEmpty { prefix = "• " }
                    _ = ordinal
                case .codeBlock:
                    traits.insert(.monoSpace)
                default: break
                }
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                if inline.contains(.code) { traits.insert(.monoSpace) }
            }

            let base = NSFont.systemFont(ofSize: size)
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(descriptor: descriptor, size: size) ?? base,
            ]
            if let link = run.link { attributes[.link] = link }
            if inlineStrikethrough(run) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

            let text = String(parsed[run.range].characters)
            let startsBlock = output.length == 0 || output.string.hasSuffix("\n")
            output.append(NSAttributedString(string: (startsBlock ? prefix : "") + text, attributes: attributes))
        }
        return output
    }

    private static func inlineStrikethrough(_ run: AttributedString.Runs.Run) -> Bool {
        run.inlinePresentationIntent?.contains(.strikethrough) ?? false
    }

    @MainActor
    private static func renderPDF(_ text: NSAttributedString, to output: URL) throws {
        let paper = NSSize(width: 612, height: 792) // US Letter
        let margin: CGFloat = 54
        let printInfo = NSPrintInfo()
        printInfo.paperSize = paper
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - margin * 2, height: paper.height - margin * 2))
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .white
        textView.textStorage?.setAttributedString(text)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.failed("Couldn't render PDF")
        }
    }

    // MARK: - Helpers

    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(name, isDirectory: true) : dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var candidate = make(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }

    private static func withScopedAccess<T>(_ urls: [URL], _ body: () async throws -> T) async rethrows -> T {
        let started = urls.map { $0.startAccessingSecurityScopedResource() }
        defer {
            for (url, didStart) in zip(urls, started) where didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await body()
    }
}
