//
//  ConversionFormat.swift
//  boringNotch
//
//  What can be converted into what. Inspired by Open Tangerine
//  (https://github.com/sintaxerrorpvtltd/Open-Tangerine) but implemented purely
//  with system frameworks (ImageIO, PDFKit, AVFoundation, AppKit text system)
//  so it works inside the app sandbox without bundling ffmpeg.
//

import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ConversionCategory: String {
    case image, pdf, video, audio, document

    var label: String {
        switch self {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        }
    }

    var icon: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        }
    }

    static func classify(_ url: URL) -> ConversionCategory? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased())
                ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        else { return nil }

        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if OutputFormat.documentInputTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return nil
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Hashable {
    // Images
    case jpeg, png, heic, webp, tiff, gif, bmp, imagePDF
    // PDF
    case pdfToPNG, pdfToJPEG, pdfToText, pdfMerge
    // Video
    case mp4, hevc, mov, videoGIF, extractAudio
    // Audio
    case m4a, wav, aiff
    // Documents
    case docx, rtf, html, txt, odt, docPDF

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jpeg, .pdfToJPEG: return "JPEG"
        case .png, .pdfToPNG: return "PNG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        case .tiff: return "TIFF"
        case .gif, .videoGIF: return "GIF"
        case .bmp: return "BMP"
        case .imagePDF, .docPDF: return "PDF"
        case .pdfToText, .txt: return "Text"
        case .pdfMerge: return "Merge"
        case .mp4: return "MP4"
        case .hevc: return "HEVC"
        case .mov: return "MOV"
        case .extractAudio: return "Audio"
        case .m4a: return "M4A"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .docx: return "Word"
        case .rtf: return "RTF"
        case .html: return "HTML"
        case .odt: return "ODT"
        }
    }

    var subtitle: String {
        switch self {
        case .jpeg: return "Small, lossy"
        case .png: return "Lossless"
        case .heic: return "Smallest"
        case .webp: return "Web"
        case .tiff: return "Print"
        case .gif: return "Legacy"
        case .bmp: return "Raw"
        case .imagePDF: return "Document"
        case .pdfToPNG: return "Each page"
        case .pdfToJPEG: return "Each page"
        case .pdfToText: return "Extract"
        case .pdfMerge: return "One PDF"
        case .mp4: return "H.264"
        case .hevc: return "H.265"
        case .mov: return "QuickTime"
        case .videoGIF: return "Animated"
        case .extractAudio: return "M4A only"
        case .m4a: return "AAC"
        case .wav: return "PCM"
        case .aiff: return "PCM"
        case .docx: return ".docx"
        case .rtf: return "Rich text"
        case .html: return "Web page"
        case .txt: return "Plain"
        case .odt: return "OpenDoc"
        case .docPDF: return "Paginated"
        }
    }

    var icon: String {
        switch self {
        case .jpeg, .png, .heic, .webp, .tiff, .bmp, .pdfToPNG, .pdfToJPEG: return "photo"
        case .gif, .videoGIF: return "square.stack.3d.forward.dottedline"
        case .imagePDF, .docPDF: return "doc.richtext"
        case .pdfToText, .txt: return "text.alignleft"
        case .pdfMerge: return "rectangle.stack.badge.plus"
        case .mp4, .hevc, .mov: return "film"
        case .extractAudio, .m4a, .wav, .aiff: return "waveform"
        case .docx, .rtf, .odt: return "doc.text"
        case .html: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg, .pdfToJPEG: return "jpg"
        case .png, .pdfToPNG: return "png"
        case .heic: return "heic"
        case .webp: return "webp"
        case .tiff: return "tiff"
        case .gif, .videoGIF: return "gif"
        case .bmp: return "bmp"
        case .imagePDF, .docPDF, .pdfMerge: return "pdf"
        case .pdfToText, .txt: return "txt"
        case .mp4, .hevc: return "mp4"
        case .mov: return "mov"
        case .extractAudio, .m4a: return "m4a"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .docx: return "docx"
        case .rtf: return "rtf"
        case .html: return "html"
        case .odt: return "odt"
        }
    }

    /// ImageIO destination type for raster outputs.
    var imageUTType: UTType? {
        switch self {
        case .jpeg, .pdfToJPEG: return .jpeg
        case .png, .pdfToPNG: return .png
        case .heic: return .heic
        case .webp: return .webP
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        default: return nil
        }
    }

    var usesQuality: Bool {
        switch self {
        case .jpeg, .heic, .webp, .pdfToJPEG: return true
        default: return false
        }
    }

    var usesResize: Bool {
        switch self {
        case .jpeg, .png, .heic, .webp, .tiff, .gif, .bmp, .imagePDF, .pdfToPNG, .pdfToJPEG: return true
        default: return false
        }
    }

    var usesVideoQuality: Bool {
        switch self {
        case .mp4, .hevc, .mov, .videoGIF: return true
        default: return false
        }
    }

    /// Formats that produce one output from many inputs.
    var isMerging: Bool { self == .pdfMerge }

    static func formats(for category: ConversionCategory) -> [OutputFormat] {
        switch category {
        case .image:
            return [.jpeg, .png, .heic, .webp, .tiff, .gif, .bmp, .imagePDF].filter { format in
                guard let type = format.imageUTType else { return true }
                return writableImageTypes.contains(type.identifier)
            }
        case .pdf: return [.pdfToPNG, .pdfToJPEG, .pdfToText, .pdfMerge]
        case .video: return [.mp4, .hevc, .mov, .videoGIF, .extractAudio]
        case .audio: return [.m4a, .wav, .aiff]
        case .document: return [.docx, .rtf, .html, .txt, .odt, .docPDF]
        }
    }

    /// Formats valid for *every* file in a mixed selection.
    static func formats(for categories: Set<ConversionCategory>) -> [OutputFormat] {
        guard let first = categories.first else { return [] }
        var result = formats(for: first)
        for category in categories.dropFirst() {
            let allowed = Set(formats(for: category))
            result = result.filter { allowed.contains($0) }
        }
        return result
    }

    /// Whether converting `source` into this format would be a no-op.
    func isSameFormat(as source: URL) -> Bool {
        let ext = source.pathExtension.lowercased()
        switch self {
        case .jpeg: return ext == "jpg" || ext == "jpeg"
        case .tiff: return ext == "tif" || ext == "tiff"
        case .mp4, .hevc, .pdfMerge, .docPDF, .imagePDF, .pdfToPNG, .pdfToJPEG, .pdfToText, .videoGIF, .extractAudio:
            return false
        default: return ext == fileExtension
        }
    }

    private static let writableImageTypes: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    static let documentInputTypes: [UTType] = [
        .rtf, .rtfd, .flatRTFD, .html, .plainText,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
        UTType("net.daringfireball.markdown"),
        UTType("com.apple.webarchive"),
    ].compactMap { $0 }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case high, medium, low
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ResizeOption: Int, CaseIterable, Identifiable {
    case original = 0
    case px4096 = 4096
    case px2048 = 2048
    case px1080 = 1080
    case px512 = 512

    var id: Int { rawValue }
    var label: String { self == .original ? "Original" : "\(rawValue)px" }
    var maxPixel: Int? { self == .original ? nil : rawValue }
}

struct ConversionOptions: Equatable {
    var quality: Double = 0.85
    var resize: ResizeOption = .original
    var videoQuality: VideoQuality = .high
    var stripMetadata: Bool = true
    /// Images → a single multi-page PDF instead of one PDF per image.
    var combineIntoOne: Bool = false
}
