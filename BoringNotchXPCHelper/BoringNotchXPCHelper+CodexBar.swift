//
//  BoringNotchXPCHelper+CodexBar.swift
//  BoringNotchXPCHelper
//
//  CodexBar integration.
//
//  The main app is sandboxed, so it can neither read CodexBar's group container
//  nor spawn the `codexbar` CLI. This (unsandboxed) helper does both and hands the
//  raw JSON back over XPC. We deliberately do *not* re-implement any provider
//  fetching: CodexBar stays the single source of truth.
//

import AppKit
import Foundation

private let codexBarBundleID = "com.steipete.codexbar"
private let cliTimeout: TimeInterval = 45

extension BoringNotchXPCHelper {

    // MARK: - Widget snapshot

    /// Returns the contents of CodexBar's `widget-snapshot.json` (the same file its
    /// WidgetKit widgets read). It's refreshed by CodexBar on every poll.
    @objc func codexBarSnapshot(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(Self.locateSnapshot().flatMap { try? Data(contentsOf: $0) })
        }
    }

    private static func locateSnapshot() -> URL? {
        let fm = FileManager.default
        let groupRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)

        // Team prefix differs between distribution channels, so match by suffix.
        guard let entries = try? fm.contentsOfDirectory(atPath: groupRoot.path) else { return nil }
        let candidates = entries
            .filter { $0 == codexBarBundleID || $0.hasSuffix("." + codexBarBundleID) }
            .map { groupRoot.appendingPathComponent($0).appendingPathComponent("widget-snapshot.json") }
            .filter { fm.fileExists(atPath: $0.path) }

        // Prefer the most recently written snapshot.
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    // MARK: - CLI

    /// Runs `codexbar usage --provider <id> --json` and returns stdout.
    @objc func codexBarUsage(_ provider: String, with reply: @escaping (Data?) -> Void) {
        runCLI(provider: provider, arguments: ["usage", "--provider", provider, "--json"], reply: reply)
    }

    /// Runs `codexbar cost --provider <id> --json` (local log scan; cost/token history).
    /// Used when the widget snapshot isn't readable.
    @objc func codexBarCost(_ provider: String, with reply: @escaping (Data?) -> Void) {
        runCLI(provider: provider, arguments: ["cost", "--provider", provider, "--json"], reply: reply)
    }

    /// `~/.codexbar/config.json` — tells us which providers the user enabled in CodexBar.
    @objc func codexBarConfig(with reply: @escaping (Data?) -> Void) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/config.json")
        reply(try? Data(contentsOf: url))
    }

    /// Per-account usage CodexBar keeps on disk, merged with claude-swap's account
    /// directory (email/org/alias only). Dates stay as Apple reference-date seconds.
    ///   claude      – ~/Library/Application Support/CodexBar/claude-swap-retained-usage.json
    ///   claudeSwap  – ~/.claude-swap-backup/sequence.json (opaqueID → email)
    ///   codex       – ~/Library/Application Support/CodexBar/codex-account-snapshots.json
    @objc func codexBarAccounts(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = home.appendingPathComponent("Library/Application Support/CodexBar")
            func json(_ url: URL) -> Any? {
                (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
            var out: [String: Any] = [:]

            if let retained = json(support.appendingPathComponent("claude-swap-retained-usage.json")) as? [[String: Any]] {
                let keep: Set<String> = ["opaqueID", "primary", "secondary", "tertiary", "extraRateWindows", "updatedAt", "usesLastKnownUsage"]
                out["claude"] = retained.map { $0.filter { keep.contains($0.key) } }
            }
            if let sequence = json(home.appendingPathComponent(".claude-swap-backup/sequence.json")) as? [String: Any] {
                var accounts: [String: Any] = [:]
                for (number, value) in (sequence["accounts"] as? [String: Any]) ?? [:] {
                    guard let account = value as? [String: Any] else { continue }
                    accounts[number] = account.filter { ["email", "organizationName", "alias"].contains($0.key) }
                }
                out["claudeSwap"] = ["active": sequence["activeAccountNumber"] ?? NSNull(), "accounts": accounts]
            }
            if let codex = json(support.appendingPathComponent("codex-account-snapshots.json")) as? [String: Any],
               let records = codex["records"] as? [[String: Any]] {
                out["codex"] = records.compactMap { record -> [String: Any]? in
                    guard let snapshot = record["snapshot"] as? [String: Any] else { return nil }
                    var entry = snapshot.filter { ["primary", "secondary", "tertiary", "updatedAt"].contains($0.key) }
                    entry["email"] = snapshot["accountEmail"] ?? record["id"]
                    entry["plan"] = snapshot["loginMethod"]
                    return entry
                }
            }
            // `{}` when none of the files exist, so the app drops accounts that are gone;
            // nil stays reserved for "the helper couldn't answer".
            reply(try? JSONSerialization.data(withJSONObject: out))
        }
    }

    /// CodexBar's own monochrome provider logo (`ProviderIcon-<id>.svg`) — the one its
    /// menu-bar items use — so we show real logos without bundling any brand assets.
    @objc func codexBarIcon(_ provider: String, with reply: @escaping (Data?) -> Void) {
        guard provider.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBarBundleID)
        else { reply(nil); return }
        let url = app.appendingPathComponent("Contents/Resources/ProviderIcon-\(provider).svg")
        reply(try? Data(contentsOf: url))
    }

    private func runCLI(provider: String, arguments: [String], reply: @escaping (Data?) -> Void) {
        // Provider ids are simple slugs; refuse anything else so we never pass junk to the CLI.
        guard !provider.isEmpty,
              provider.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let cli = Self.locateCLI()
        else {
            reply(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            reply(Self.run(cli, arguments: arguments))
        }
    }

    /// XPC services start with a bare PATH (/usr/bin:/bin…). CodexBar shells out to
    /// provider CLIs (e.g. `claude`), so give it the user's login-shell PATH.
    private static let userEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []

        let accountShell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) }
        let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? accountShell ?? "/bin/zsh"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        probe.standardInput = FileHandle.nullDevice
        if (try? probe.run()) != nil {
            let killer = DispatchWorkItem { if probe.isRunning { probe.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            killer.cancel()
            if let path = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                paths += path.split(separator: ":").map(String.init)
            }
        }
        // Safety net for common install locations even if the shell probe failed.
        paths += [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        paths += (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)

        var seen = Set<String>()
        env["PATH"] = paths.filter { seen.insert($0).inserted }.joined(separator: ":")
        env["HOME"] = home
        // XPC services also lack USER/LOGNAME; CodexBar's Claude probe needs them
        // (without USER it reports "No available fetch strategy for claude").
        if let pw = getpwuid(getuid()) {
            let name = String(cString: pw.pointee.pw_name)
            env["USER"] = env["USER"] ?? name
            env["LOGNAME"] = env["LOGNAME"] ?? name
            if env["SHELL"] == nil { env["SHELL"] = String(cString: pw.pointee.pw_shell) }
        }
        return env
    }()

    private static func locateCLI() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBarBundleID) {
            candidates.append(app.appendingPathComponent("Contents/Helpers/CodexBarCLI"))
        }
        candidates += [
            URL(fileURLWithPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codexbar"),
            URL(fileURLWithPath: "/usr/local/bin/codexbar"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = userEnvironment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + cliTimeout, execute: killer)

        // Drain stdout before waiting so a large payload can't block on a full pipe.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        return data.isEmpty ? nil : data
    }
}
