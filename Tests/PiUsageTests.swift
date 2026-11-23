// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Pi and Gentle-Pi usage counts with Claude's API value, history and models,
/// and with nothing that describes the Claude account.
enum PiUsageTests {
    private static let now = AgentTimestamp.parse("2026-11-23T18:00:00.000Z")!
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let header = #"{"type":"session","version":3,"id":"pi-session-1","timestamp":"2026-11-23T14:00:00.000Z","cwd":"/Users/me/code/shop"}"#

    private static func message(id: String, response: String?, model: String = "claude-sonnet-5-5", at time: String = "2026-11-23T15:00:00.000Z",
                                input: Int = 4, output: Int = 100, read: Int = 1000, write: Int = 500,
                                cost: String = #""cost":{"total":1.5}"#, provider: String = "anthropic") -> String {
        let responseField = response.map { #","responseId":"\#($0)""# } ?? ""
        return #"{"type":"message","id":"\#(id)","parentId":"x","timestamp":"\#(time)","message":{"role":"assistant","provider":"\#(provider)","model":"\#(model)","usage":{"input":\#(input),"output":\#(output),"cacheRead":\#(read),"cacheWrite":\#(write),"reasoning":30,\#(cost)},"stopReason":"toolUse"\#(responseField)}}"#
    }

    private static func warm(id: String, model: String = "claude-sonnet-5-5", at time: String = "2026-11-23T15:10:00.000Z",
                             cost: String = #""cost":{"total":0.11}"#) -> String {
        #"{"type":"usage","id":"\#(id)","parentId":"x","timestamp":"\#(time)","kind":"cache_warm","provider":"anthropic","model":"\#(model)","usage":{"input":2,"output":1,"cacheRead":900,"cacheWrite":0,\#(cost)}}"#
    }

    private static func parse(_ lines: [String], into store: AgentUsageStore, file: String, state: inout AgentLogState) {
        for text in lines {
            let entries = PiReader().parse(Data(text.utf8), state: &state, now: now)
            store.apply(entries, file: file, provider: .pi, tracksTurns: false, modified: now, now: now)
        }
    }

    private static func claude(_ store: AgentUsageStore, key: String, model: String, cost: Double, output: Int, at date: Date? = nil) {
        let tokens = AgentTokens(input: 10, cacheWrite: 0, cacheRead: 0, output: output)
        let record = AgentUsageRecord(provider: .claude, date: date ?? now.addingTimeInterval(-3 * 3600), model: model,
                                      project: "shop", session: "c1", tokens: tokens, cost: cost, savings: 0)
        store.apply([.usage(key: key, record: record, billable: AgentBillable(tokens: tokens))], file: "/claude/c1.jsonl",
                    provider: .claude, tracksTurns: true, modified: now, now: now)
    }

    private static func snapshot(_ store: AgentUsageStore) -> AgentUsageSnapshot {
        store.snapshot(plans: [:], providers: [.claude, .pi], now: now, calendar: calendar)
    }

    static func run(_ suite: TestSuite) {
        let close = { (a: Double, b: Double) in abs(a - b) < 1e-9 }

        // The reported case: Claude Code $10.39 plus Pi $2.11 is $12.50 in one card.
        let store = AgentUsageStore()
        claude(store, key: "claude:a:1", model: "claude-sonnet-5-5", cost: 10.39, output: 700)
        var state = AgentLogState()
        parse([header,
               message(id: "m1", response: "msg_1", cost: #""cost":{"total":1.5}"#),
               warm(id: "w1", cost: #""cost":{"total":0.11}"#),
               message(id: "m2", response: "msg_2", model: "claude-opus-5-5", cost: #""cost":{"total":0.5}"#)],
              into: store, file: "/pi/a.jsonl", state: &state)
        var today = snapshot(store).usage(.today)
        suite.expect(close(today.total.cost, 12.5), "Claude Code and Pi add up to one API value: \(today.total.cost)")
        suite.expect(today.total.tokens.total == (10 + 700) + (4 + 100 + 1000 + 500) + (2 + 1 + 900) + (4 + 100 + 1000 + 500),
                     "tokens from both agents are summed exactly, reasoning not counted twice: \(today.total.tokens.total)")
        suite.expect(today.byProvider[.claude]?.cost == today.total.cost && today.byProvider[.pi] == nil,
                     "Pi shows under Claude's card, not as an agent of its own")
        suite.expect(snapshot(store).days.last?.byProvider[.claude].map { close($0.cost, 12.5) } == true,
                     "the trend counts Pi with Claude")
        suite.expect(today.projects.first { $0.name == "shop" }.map { close($0.totals.cost, 12.5) } == true,
                     "projects count Pi's folder")

        // Models: the same model joins, other versions stay apart.
        claude(store, key: "claude:a:2", model: "claude-opus-4-1", cost: 1, output: 10)
        today = snapshot(store).usage(.today)
        let names = today.models.map(\.name)
        suite.expect(names.filter { $0 == AgentPricing.displayName("claude-sonnet-5-5") }.count == 1,
                     "the same Sonnet from both agents is one row: \(names)")
        suite.expect(AgentPricing.displayName("claude-opus-5-5") != AgentPricing.displayName("claude-opus-4-1")
                     && names.contains(AgentPricing.displayName("claude-opus-5-5"))
                     && names.contains(AgentPricing.displayName("claude-opus-4-1")), "Opus versions stay separate: \(names)")
        suite.expect(today.models.first { $0.name == AgentPricing.displayName("claude-sonnet-5-5") }
                        .map { close($0.totals.cost, 10.39 + 1.5 + 0.11) } == true, "the Sonnet row holds both agents' cost")

        // Periods: a record from last month is outside today and the week.
        let old = AgentUsageStore()
        parse([header, message(id: "o1", response: "msg_old", at: "2026-10-30T15:00:00.000Z")], into: old, file: "/pi/old.jsonl", state: &state)
        let oldSnapshot = snapshot(old)
        suite.expect(oldSnapshot.usage(.today).total.cost == 0 && oldSnapshot.usage(.week).total.cost == 0,
                     "an old Pi reply is outside today and the week")
        let week = AgentUsageStore()
        parse([header, message(id: "w1", response: "msg_wk", at: "2026-11-19T15:00:00.000Z")], into: week, file: "/pi/week.jsonl", state: &state)
        let weekSnapshot = snapshot(week)
        suite.expect(weekSnapshot.usage(.today).total.cost == 0 && close(weekSnapshot.usage(.week).total.cost, 1.5)
                     && close(weekSnapshot.usage(.month).total.cost, 1.5), "a reply from four days ago counts for the week and month")

        // Duplicates: a copied, reopened or forked session counts once.
        let dup = AgentUsageStore()
        var other = AgentLogState()
        parse([header, message(id: "m1", response: "msg_1")], into: dup, file: "/pi/a.jsonl", state: &state)
        parse([header, message(id: "m1", response: "msg_1"), message(id: "m9", response: nil), warm(id: "w1")],
              into: dup, file: "/pi/fork.jsonl", state: &other)
        parse([warm(id: "w1")], into: dup, file: "/pi/fork2.jsonl", state: &other)
        suite.expect(dup.records.count == 3, "copied replies and warm-ups count once: \(dup.records.count)")
        suite.expect(close(snapshot(dup).usage(.today).total.cost, 1.5 + 1.5 + 0.11), "duplicates add no cost")

        // Two agents' replies never collapse into each other, even with the same ids and model.
        let both = AgentUsageStore()
        let tokens = AgentTokens(input: 4, cacheWrite: 500, cacheRead: 1000, output: 100)
        both.apply([.usage(key: "claude:msg_1:", record: AgentUsageRecord(provider: .claude, date: now.addingTimeInterval(-3600),
                       model: "claude-sonnet-5-5", project: "shop", session: "c", tokens: tokens, cost: 2, savings: 0),
                       billable: AgentBillable(tokens: tokens))], file: "/claude/c.jsonl", provider: .claude, tracksTurns: true,
                   modified: now, now: now)
        parse([header, message(id: "m1", response: "msg_1")], into: both, file: "/pi/a.jsonl", state: &state)
        suite.expect(both.records.count == 2 && close(snapshot(both).usage(.today).total.cost, 3.5),
                     "the same model and response id from another agent stays separate")

        // Other providers and empty replies are not counted.
        let skipped = AgentUsageStore()
        parse([header, message(id: "x1", response: "r", provider: "openai"),
               message(id: "x2", response: "r2", input: 0, output: 0, read: 0, write: 0, cost: #""cost":{"total":0}"#)],
              into: skipped, file: "/pi/s.jsonl", state: &state)
        suite.expect(skipped.records.isEmpty, "only billed Anthropic replies count")

        // Costs: recorded wins; missing or invalid falls back to the catalog, then to partial USD.
        let costs = AgentUsageStore()
        parse([header,
               message(id: "c1", response: "c1", model: "pi-unlisted-model", cost: #""cost":{"total":0.75}"#),
               message(id: "c2", response: "c2", model: "pi-unlisted-model", cost: #""cost":{"total":-1}"#),
               message(id: "c3", response: "c3", model: "pi-unlisted-model", cost: #""cost":{"total":"high"}"#),
               message(id: "c4", response: "c4", model: "pi-unlisted-model", cost: #""note":1"#),
               message(id: "c5", response: "c5", model: "pi-unlisted-model", cost: #""cost":{"total":0}"#)],
              into: costs, file: "/pi/c.jsonl", state: &state)
        suite.expect(costs.records.map(\.cost) == [0.75, nil, nil, nil, nil], "recorded cost is kept and unusable ones stay unpriced: \(costs.records.map(\.cost))")
        let partial = snapshot(costs).usage(.today)
        suite.expect(!partial.fullyPriced && close(partial.total.cost, 0.75) && partial.total.tokens.total == 5 * 1604,
                     "unpriced replies keep their tokens and mark the USD as partial")
        let listed = AgentUsageStore()
        parse([header, message(id: "k1", response: "k1", cost: #""note":1"#)], into: listed, file: "/pi/k.jsonl", state: &state)
        var listBill = AgentBillable(); listBill.tokens = AgentTokens(input: 4, cacheWrite: 500, cacheRead: 1000, output: 100)
        suite.expect(listed.records.first?.cost == AgentPricing.cost(listBill, model: "claude-sonnet-5-5").cost
                     && listed.records.first?.reportedCost == false, "a missing cost uses the catalog when it knows the model")

        // Restart and repricing keep the recorded cost.
        let saved = AgentUsageArchive.encode(.init(providers: [.claude, .pi], store: store.saved, cursors: []), build: "1.0-1")
        let restored = AgentUsageArchive.decode(saved, build: "1.0-1")
        suite.expect(restored != nil && restored?.store == store.saved, "Pi records survive the archive round trip")
        if let restored {
            let resumed = AgentUsageStore(saved: restored.store)
            resumed.reprice()
            let piCost = resumed.records.filter { $0.provider == .pi }.reduce(0.0) { $0 + ($1.cost ?? 0) }
            suite.expect(close(piCost, 2.11) && resumed.records.filter { $0.provider == .pi }.allSatisfy(\.reportedCost),
                         "a relaunch with new prices keeps what Pi recorded: \(piCost)")
        }
        store.reprice()
        suite.expect(close(store.records.filter { $0.provider == .pi }.reduce(0.0) { $0 + ($1.cost ?? 0) }, 2.11),
                     "repricing leaves recorded costs alone")

        // Nothing about the account or the present changes.
        let alone = AgentUsageStore()
        claude(alone, key: "claude:a:1", model: "claude-sonnet-5-5", cost: 10.39, output: 700)
        let before = snapshot(alone)
        let mixed = AgentUsageStore()
        claude(mixed, key: "claude:a:1", model: "claude-sonnet-5-5", cost: 10.39, output: 700)
        parse([header, message(id: "n1", response: "n1", at: "2026-11-23T17:50:00.000Z")], into: mixed, file: "/pi/n.jsonl", state: &state)
        let after = snapshot(mixed)
        suite.expect(before.claudeBlock == after.claudeBlock && before.burnRate == after.burnRate
                     && before.lastActivity == after.lastActivity && before.live == after.live && before.limits == after.limits,
                     "Pi leaves the Claude window, burn rate, activity, live turns and limits alone")
        suite.expect(AgentClaudeAppUsage.sessionStart(mixed.records, samples: []) == AgentClaudeAppUsage.sessionStart(alone.records, samples: []),
                     "Pi does not place the Claude session start")
        let plain = snapshot(alone).usage(.today)
        suite.expect(close(plain.total.cost, 10.39) && plain.total.tokens.total == 710, "without Pi sessions Claude's numbers are unchanged")

        // Incremental reads: a log read in two steps counts each reply once.
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorss-pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "2026-11-23T14-00-00-000Z_pi.jsonl")
        let incremental = AgentUsageStore()
        let cursor = AgentLogCursor(path: log.path, provider: .pi)
        func readMore() {
            AgentLogReader.readAppended(cursor) { line in
                let entries = PiReader().parse(line, state: &cursor.state, now: now)
                incremental.apply(entries, file: cursor.path, provider: .pi, tracksTurns: cursor.tracksTurns,
                                  parent: cursor.parent, modified: cursor.modified, now: now)
            }
        }
        try? Data(([header, message(id: "i1", response: "i1")].joined(separator: "\n") + "\n").utf8).write(to: log)
        readMore()
        let half = message(id: "i2", response: "i2")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data((String(half.prefix(60))).utf8))
            try? handle.close()
        }
        readMore()
        suite.expect(incremental.records.count == 1, "a reply still being written waits for its line to end")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data((String(half.dropFirst(60)) + "\n").utf8))
            try? handle.close()
        }
        readMore()
        suite.expect(incremental.records.count == 2 && close(snapshot(incremental).usage(.today).total.cost, 3.0)
                     && incremental.records.allSatisfy { $0.project == "shop" && $0.session == "pi-session-1" },
                     "appended replies are read once with the session's folder")

        // Roots: the three default folders, each read only when Claude is on.
        let home = URL(fileURLWithPath: "/tmp/vorss-home-none")
        let roots = AgentLogRoot.piRoots(home: home).map { $0.url.path }
        suite.expect(roots.count == 3 && roots[0].hasSuffix(".local/share/gentle-shell/install/agent/sessions")
                     && roots[1].hasSuffix(".gentle-shell/agent/sessions") && roots[2].hasSuffix(".pi/agent/sessions"),
                     "Gentle-Pi and Pi session folders are the only ones read: \(roots)")
        let domain = "com.vorssaint.tests.pi-usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        suite.expect(NotchAgentSupport.readers(in: defaults).contains(.pi) && !NotchAgentSupport.providers(in: defaults).contains(.pi),
                     "Pi is read with Claude but has no switch of its own")
        defaults.set(false, forKey: DefaultsKey.notchAgentsClaude)
        suite.expect(!NotchAgentSupport.readers(in: defaults).contains(.pi), "Pi is not read once Claude is off")
    }
}
