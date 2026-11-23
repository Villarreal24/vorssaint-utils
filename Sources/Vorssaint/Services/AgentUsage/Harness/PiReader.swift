// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Reads Pi and Gentle-Pi session logs, keeping only their Anthropic usage:
/// the replies and the billed `cache_warm` requests. Pi has no turns or
/// limits the island follows, so nothing but usage leaves a line, and no
/// prompt, reply or tool output is kept.
struct PiReader: AgentHarnessReader {
    var provider: AgentProvider { .pi }

    func parse(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        if AgentLogParser.contains(line, #""type":"session""#) { adopt(line, into: &state) }
        guard AgentLogParser.contains(line, #""usage""#),
              AgentLogParser.contains(line, #""role":"assistant""#) || AgentLogParser.contains(line, #""kind":"cache_warm""#),
              let json = AgentLogParser.object(line) else { return [] }
        let type = json["type"] as? String
        let usage: [String: Any]
        let source: [String: Any]
        let responseID: String
        switch type {
        case "message":
            guard let message = json["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let counted = message["usage"] as? [String: Any] else { return [] }
            (source, usage) = (message, counted)
            responseID = message["responseId"] as? String ?? ""
        case "usage":
            guard json["kind"] as? String == "cache_warm", let counted = json["usage"] as? [String: Any] else { return [] }
            (source, usage) = (json, counted)
            responseID = ""
        default:
            return []
        }
        guard source["provider"] as? String == "anthropic" else { return [] }
        let model = AgentLogParser.native(source["model"] as? String ?? "")
        guard !model.isEmpty, !model.hasPrefix("<") else { return [] }

        var billable = AgentBillable()
        // Pi's `output` already holds the reasoning tokens, as Claude's does.
        billable.tokens = AgentTokens(
            input: AgentLogParser.int(usage["input"]), cacheWrite: AgentLogParser.int(usage["cacheWrite"]),
            cacheRead: AgentLogParser.int(usage["cacheRead"]), output: AgentLogParser.int(usage["output"]),
            reasoning: AgentLogParser.int(usage["reasoning"]))
        billable.longCacheWrite = min(AgentLogParser.int(usage["cacheWrite1h"]), billable.tokens.cacheWrite)
        // An aborted reply writes zeros.
        guard billable.tokens.total > 0 else { return [] }

        let date = AgentLogParser.timestamp(json["timestamp"]) ?? AgentLogParser.timestamp(source["timestamp"]) ?? now
        // A fork, a reopened or a copied session repeats a reply under the
        // same identifiers; the prefix keeps them apart from any other agent's.
        let key: String
        if !responseID.isEmpty {
            key = "pi:response:\(responseID)"
        } else {
            key = "pi:entry:\(json["timestamp"] as? String ?? "\(date.timeIntervalSince1970)"):\(json["id"] as? String ?? state.session)"
        }
        let priced = AgentPricing.cost(billable, model: model)
        var record = AgentUsageRecord(provider: .pi, date: date, model: model, project: state.project, session: state.session,
                                      tokens: billable.tokens, cost: priced.cost, savings: priced.savings)
        // The recorded charge outranks the list price. A zero beside real
        // tokens is a model Pi had no price for, not a free reply.
        if let recorded = recordedCost(usage["cost"]), recorded > 0 {
            record.cost = recorded
            record.reportedCost = true
        }
        return [.usage(key: key, record: record, billable: billable)]
    }

    private func recordedCost(_ value: Any?) -> Double? {
        guard let total = (value as? [String: Any])?["total"] as? NSNumber,
              CFGetTypeID(total) != CFBooleanGetTypeID() else { return nil }
        let amount = total.doubleValue
        return amount.isFinite && amount >= 0 ? amount : nil
    }

    private func adopt(_ line: Data, into state: inout AgentLogState) {
        guard let json = AgentLogParser.object(line), json["type"] as? String == "session" else { return }
        if let session = json["id"] as? String, !session.isEmpty { state.session = AgentLogParser.native(session) }
        if let cwd = json["cwd"] as? String, !cwd.isEmpty { state.project = AgentLogParser.projectName(cwd) }
    }
}
