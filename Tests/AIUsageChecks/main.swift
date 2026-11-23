// Checks for how the Usage tab reads CodexBar's and claude-swap's files when they are
// missing, partial or malformed: the helper's merge, then the app's decoding and matching.
// No test target needed:
//
//   swiftc -o /tmp/ai-usage-checks boringNotch/AIUsage/CodexBarModels.swift \
//     BoringNotchXPCHelper/BoringNotchXPCHelper+CodexBar.swift Tests/AIUsageChecks/main.swift && /tmp/ai-usage-checks

import Foundation

/// Stand-in for the XPC service class, so its CodexBar extension compiles here.
final class BoringNotchXPCHelper: NSObject {}

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print(condition ? "ok   \(name)" : "FAIL \(name)")
    if !condition { failures += 1 }
}

func payload(_ json: String) -> CodexBarAccountsPayload? {
    try? CodexBarDecoding.referenceDateDecoder.decode(CodexBarAccountsPayload.self, from: Data(json.utf8))
}

let swapTwo = #""claudeSwap": {"active": 2, "accounts": {"1": {"email": "a@x.com", "organizationName": "A's Organization"}, "2": {"email": "b@x.com", "organizationName": "Acme"}}}"#
let weekly = #"{"usedPercent": 40, "windowMinutes": 10080, "resetsAt": 816000000}"#
let codex = #""codex": [{"email": "c@x.com", "plan": "pro", "secondary": \#(weekly)}]"#

// Everything present and well-formed.
do {
    let p = payload(#"{"claude": [{"opaqueID": "2", "secondary": \#(weekly)}, {"opaqueID": "1", "secondary": \#(weekly)}], \#(swapTwo), \#(codex)}"#)
    let accounts = p?.claudeSwapAccounts ?? []
    check(accounts.map(\.number) == ["1", "2"], "healthy: one row per account, in claude-swap order")
    check(accounts.first(where: \.isActive)?.number == "2", "healthy: active account marked")
    check(accounts.first?.info.email == "a@x.com", "healthy: email from claude-swap")
    check(p?.codex?.count == 1, "healthy: codex account kept")
}

// claude-swap not installed: CodexBar's leftover records must not become accounts.
do {
    let p = payload(#"{"claude": [{"opaqueID": "1", "secondary": \#(weekly)}], \#(codex)}"#)
    check(p != nil, "no claude-swap: still decodes")
    check(p?.claudeSwapAccounts.isEmpty == true, "no claude-swap: falls back to the single Claude login")
    check(p?.codex?.count == 1, "no claude-swap: codex unaffected")
}

// claude-swap installed but CodexBar has no per-account usage for it.
check(payload("{\(swapTwo)}")?.claudeSwapAccounts.isEmpty == true, "no CodexBar records: falls back")

// Neither file exists: the helper sends {}.
do {
    let p = payload("{}")
    check(p != nil && p?.claudeSwapAccounts.isEmpty == true && p?.codex == nil, "empty reply: decodes to nothing")
}

// Records and accounts that don't line up.
do {
    let p = payload(#"{"claude": [{"opaqueID": "7", "secondary": \#(weekly)}, {"opaqueID": "8"}], \#(swapTwo)}"#)
    check(p?.claudeSwapAccounts.isEmpty == true, "no matching numbers: falls back")
    let q = payload(#"{"claude": [{"opaqueID": "1", "secondary": \#(weekly)}, {"opaqueID": "9", "secondary": \#(weekly)}], \#(swapTwo)}"#)
    check(q?.claudeSwapAccounts.map(\.number) == ["1"], "account removed from claude-swap: its record is dropped")
}

// Other versions writing numbers as strings or the reverse.
do {
    let p = payload(#"{"claude": [{"opaqueID": 2, "secondary": \#(weekly)}], "claudeSwap": {"active": "2", "accounts": {"2": {"email": "b@x.com"}}}}"#)
    check(p?.claudeSwapAccounts.first?.number == "2", "3 vs \"3\": still matched")
    check(p?.claudeSwapAccounts.first?.isActive == true, "3 vs \"3\": still active")
}

// Malformed parts only lose themselves.
do {
    let p = payload(#"{"claude": [42, {"opaqueID": "1", "secondary": "broken", "extraRateWindows": [{"id": "x"}, {"id": "fable", "title": "Fable", "window": \#(weekly)}]}], "claudeSwap": {"active": null, "accounts": {"1": {"email": 5}, "2": "junk"}}, \#(codex)}"#)
    let accounts = p?.claudeSwapAccounts ?? []
    check(accounts.map(\.number) == ["1"], "malformed: bad records skipped, good one kept")
    check(accounts.first?.usage.secondary == nil, "malformed: bad window dropped, record kept")
    check(accounts.first?.usage.extraRateWindows?.map(\.id) == ["fable"], "malformed: bad extra window dropped")
    check(accounts.first?.info.email == nil, "malformed: bad email dropped, account kept")
    check(accounts.first?.isActive == false, "malformed: no active account")
    check(p?.codex?.count == 1, "malformed: codex unaffected")
}
do {
    let p = payload(#"{"claude": "garbage", "claudeSwap": [1, 2], \#(codex)}"#)
    check(p?.codex?.count == 1 && p?.claudeSwapAccounts.isEmpty == true, "wrong shapes: codex survives, Claude falls back")
}

// A duplicated record keeps the newest reading.
do {
    let p = payload(#"{"claude": [{"opaqueID": "1", "updatedAt": 100, "secondary": {"usedPercent": 10}}, {"opaqueID": "1", "updatedAt": 200, "secondary": {"usedPercent": 90}}], \#(swapTwo)}"#)
    check(p?.claudeSwapAccounts.count == 1, "duplicate record: one row")
    check(p?.claudeSwapAccounts.first?.usage.secondary?.usedPercent == 90, "duplicate record: newest wins")
}

// End to end: files as the helper reads them, through its merge, into the app.
func throughHelper(retained: String?, sequence: String?, codex: String?) -> (merged: [String: Any], payload: CodexBarAccountsPayload?) {
    func parse(_ text: String?) -> Any? { text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } }
    let merged = BoringNotchXPCHelper.mergeAccountFiles(retained: parse(retained), sequence: parse(sequence), codex: parse(codex))
    let data = try! JSONSerialization.data(withJSONObject: merged)
    return (merged, try? CodexBarDecoding.referenceDateDecoder.decode(CodexBarAccountsPayload.self, from: data))
}
let sequenceFile = #"{"activeAccountNumber": 2, "accounts": {"1": {"email": "a@x.com", "alias": "work", "uuid": "u1"}, "2": {"email": "b@x.com"}, "3": "junk"}}"#
let codexFile = #"{"records": [{"id": "c", "snapshot": {"accountEmail": "c@x.com", "loginMethod": "pro", "secondary": \#(weekly)}}, "junk"]}"#
do {
    let r = throughHelper(retained: #"[{"opaqueID": "1", "secondary": \#(weekly)}, {"opaqueID": "2", "secondary": \#(weekly)}, null, 7]"#,
                          sequence: sequenceFile, codex: codexFile)
    check(r.payload?.claudeSwapAccounts.map(\.number) == ["1", "2"], "helper: a bad retained record doesn't drop the others")
    check(r.payload?.codex?.map(\.email) == ["c@x.com"], "helper: a bad codex record doesn't drop the others")
    check(r.payload?.claudeSwapAccounts.first(where: \.isActive)?.number == "2", "helper: active account carried through")
    let accounts = (r.merged["claudeSwap"] as? [String: Any])?["accounts"] as? [String: [String: Any]]
    check(accounts?["1"].map { Set($0.keys) } == ["email"], "helper: only email and organisation leave claude-swap's file")
}
do {
    let r = throughHelper(retained: nil, sequence: nil, codex: nil)
    check(r.merged.isEmpty && r.payload != nil && r.payload?.claudeSwapAccounts.isEmpty == true, "helper: no files gives {} and no accounts")
    let s = throughHelper(retained: #"{"not": "a list"}"#, sequence: "[1, 2]", codex: #"{"records": "nope"}"#)
    check(s.merged.isEmpty && s.payload?.codex == nil, "helper: wrong file shapes are ignored")
}

// Not an object at all.
check(payload("[]") == nil, "not an object: rejected (the app keeps its last good reading)")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
