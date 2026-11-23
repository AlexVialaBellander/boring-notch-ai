//
//  ConverterFolderAccess.swift
//  boringNotch
//
//  Sandbox-correct write access for converter output.
//
//  Dropping a file only grants the app access to *that file*, not its folder.
//  To save "next to the original" we ask once (NSOpenPanel / Powerbox, pre-pointed
//  at the right folder) and persist a security-scoped bookmark. Granting a parent
//  folder (e.g. your home folder) covers everything below it.
//

import AppKit
import Foundation

@MainActor
enum ConverterFolderAccess {
    private static let defaultsKey = "converterFolderBookmarks"

    /// Copies `file` into `directory` (never overwriting) using any access we
    /// already hold. Returns the destination, or nil if we lack access.
    static func copy(_ file: URL, into directory: URL, name: String? = nil) -> URL? {
        let scopes = grantedScopes(covering: directory)
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }

        let destination = uniqueDestination(in: directory, name: name ?? file.lastPathComponent, isDirectory: file.hasDirectoryPath)
        do {
            try FileManager.default.copyItem(at: file, to: destination)
            return destination
        } catch {
            NSLog("Converter: copy to \(directory.path) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Shows a folder picker pre-pointed at `directory` and remembers the grant.
    static func requestAccess(to directory: URL) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        panel.prompt = "Allow"
        panel.title = "Save converted files here"
        panel.message = "boringNotch needs permission to save into “\(directory.lastPathComponent)”. Choose this folder — or a parent such as your home folder to allow saving anywhere inside it."
        panel.level = .popUpMenu

        SharingStateManager.shared.preventNotchClose = true
        defer { SharingStateManager.shared.preventNotchClose = false }
        NSApp.activate(ignoringOtherApps: true)

        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let granted = panel.url else { return false }

        if let bookmark = try? granted.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
            stored.append(bookmark)
            UserDefaults.standard.set(stored, forKey: defaultsKey)
        }
        return isAncestor(granted, of: directory)
    }

    // MARK: - Private

    /// Starts every stored scope that covers `directory`. Caller must stop them.
    private static func grantedScopes(covering directory: URL) -> [URL] {
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var started: [URL] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
                  isAncestor(url, of: directory),
                  url.startAccessingSecurityScopedResource()
            else { continue }
            started.append(url)
        }
        return started
    }

    private static func isAncestor(_ ancestor: URL, of url: URL) -> Bool {
        let a = ancestor.standardizedFileURL.resolvingSymlinksInPath().path
        let b = url.standardizedFileURL.resolvingSymlinksInPath().path
        return b == a || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    private static func uniqueDestination(in directory: URL, name: String, isDirectory: Bool) -> URL {
        // Folder names like "v1.2 (PNG)" have no real extension.
        let base = isDirectory ? name : (name as NSString).deletingPathExtension
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}
