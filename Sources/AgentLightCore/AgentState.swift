public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case openCode = "opencode"
    case grokBuild = "grok-build"
    case hermes
    case openClaw = "openclaw"
    case antigravity
}

public enum AgentSessionStatus: Codable, Equatable, Sendable {
    case idle
    case working
    case toolRunning
    case outputting
    case waiting
    case complete
    case error
}

public struct AgentSessionKey: Codable, Hashable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String

    public init(provider: AgentProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

public enum AgentEventLifecycle: String, Codable, Sendable {
    case unspecified, begin, activity, endTurn, endSession
}

public struct AgentEvent: Equatable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let status: AgentSessionStatus
    public let turnID: String?
    public let lifecycle: AgentEventLifecycle
    public var owner: AgentProcessOwner?
    public var occurredAt: Double?

    public init(provider: AgentProvider, sessionID: String, status: AgentSessionStatus, turnID: String? = nil,
                lifecycle: AgentEventLifecycle = .unspecified, owner: AgentProcessOwner? = nil,
                occurredAt: Double? = nil) {
        self.provider = provider
        self.sessionID = sessionID
        self.status = status
        self.turnID = turnID
        self.lifecycle = lifecycle
        self.owner = owner
        self.occurredAt = occurredAt
    }
}

public struct AgentSessionRecord: Codable, Equatable, Sendable {
    public var status: AgentSessionStatus
    public var updatedAt: Int64
    public var owner: AgentProcessOwner? = nil
}

public struct AgentTurnLedger: Codable, Equatable, Sendable {
    var current: String?
    var closed: Set<String> = []
    var lastBegin: Double = 0
    var sessionEnded = false
    var continuationAllowed = false
    var lastEnd: Double = 0
}

public struct AgentStatePresentation: Equatable, Sendable {
    public let command: AgentLightCommand
    public let nextExpiration: Int64?
}

public struct AgentState: Codable, Equatable, Sendable {
    public static let completionRetention: Int64 = 15

    public var sessions: [AgentSessionKey: AgentSessionRecord]
    public var codexTurns: [String: AgentTurnLedger] = [:]

    public init(sessions: [AgentSessionKey: AgentSessionRecord] = [:]) {
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey { case sessions, codexTurns }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([AgentSessionKey: AgentSessionRecord].self, forKey: .sessions)
        codexTurns = try container.decodeIfPresent([String: AgentTurnLedger].self, forKey: .codexTurns) ?? [:]
    }

    public mutating func apply(_ event: AgentEvent, now: Int64) {
        prune(now: now)
        let key = AgentSessionKey(provider: event.provider, sessionID: event.sessionID)
        if event.provider == .codex, event.lifecycle != .unspecified {
            var ledger = codexTurns[event.sessionID] ?? AgentTurnLedger()
            let started = event.occurredAt ?? Double(now)
            switch event.lifecycle {
            case .begin:
                guard started >= ledger.lastBegin, started > ledger.lastEnd else { return }
                if let turn = event.turnID {
                    if ledger.closed.contains(turn) {
                        guard ledger.continuationAllowed, ledger.current == turn,
                              started > ledger.lastEnd else { return }
                        ledger.closed.remove(turn)
                    }
                    if let current = ledger.current, current != turn { ledger.closed.insert(current) }
                    ledger.current = turn
                }
                ledger.lastBegin = started
                ledger.sessionEnded = false
                ledger.continuationAllowed = false
            case .activity, .endTurn:
                guard !ledger.sessionEnded else { return }
                if let turn = event.turnID {
                    guard !ledger.closed.contains(turn), ledger.current == nil || ledger.current == turn else { return }
                    if ledger.current == nil { ledger.lastBegin = max(ledger.lastBegin, started) }
                    ledger.current = turn
                } else if ledger.current != nil {
                    // Unscoped activity cannot overwrite a tracked turn.
                    return
                }
                if event.lifecycle == .endTurn {
                    if let current = ledger.current { ledger.closed.insert(current) }
                    ledger.continuationAllowed = event.status == .complete
                    ledger.lastEnd = started
                }
            case .endSession:
                guard started >= ledger.lastBegin else { return }
                if let current = ledger.current { ledger.closed.insert(current) }
                ledger.sessionEnded = true
                ledger.continuationAllowed = false
            case .unspecified: break
            }
            codexTurns[event.sessionID] = ledger
        }
        if event.status == .idle {
            sessions.removeValue(forKey: key)
        } else {
            sessions[key] = AgentSessionRecord(status: event.status, updatedAt: now,
                owner: event.lifecycle == .begin ? event.owner : event.owner ?? sessions[key]?.owner)
        }
    }

    @discardableResult
    public mutating func reconcileCodexTurns(
        check: (String, String, Double) -> CodexTurnEvidence?
    ) -> Int {
        var removed = 0
        for (key, record) in sessions where key.provider == .codex {
            switch record.status {
            case .working, .toolRunning, .outputting, .waiting: break
            case .idle, .complete, .error: continue
            }
            guard var ledger = codexTurns[key.sessionID], let turn = ledger.current,
                  let evidence = check(key.sessionID, turn, ledger.lastBegin),
                  evidence.closedTurns.contains(turn), evidence.endedAt >= ledger.lastBegin else { continue }
            sessions.removeValue(forKey: key)
            ledger.closed.formUnion(evidence.closedTurns)
            ledger.lastEnd = max(ledger.lastEnd, evidence.endedAt)
            ledger.continuationAllowed = false
            codexTurns[key.sessionID] = ledger
            removed += 1
        }
        return removed
    }

    @discardableResult
    public mutating func reconcileOwners(check: (AgentProcessOwner) -> AgentOwnerStatus) -> Int {
        var removed = 0
        for (key, record) in sessions {
            switch record.status {
            case .working, .toolRunning, .outputting, .waiting: break
            case .idle, .complete, .error: continue
            }
            guard let owner = record.owner, check(owner) == .exited else { continue }
            sessions.removeValue(forKey: key)
            if key.provider == .codex {
                var ledger = codexTurns[key.sessionID] ?? AgentTurnLedger()
                if let turn = ledger.current { ledger.closed.insert(turn) }
                ledger.sessionEnded = true
                ledger.continuationAllowed = false
                codexTurns[key.sessionID] = ledger
            }
            removed += 1
        }
        return removed
    }

    public mutating func presentation(now: Int64) -> AgentStatePresentation {
        prune(now: now)
        let records = sessions.values
        let command: AgentLightCommand

        if records.contains(where: { $0.status == .error }) {
            command = .error
        } else if records.contains(where: { $0.status == .waiting }) {
            command = .waiting
        } else if records.contains(where: { $0.status == .toolRunning }) {
            command = .toolRunning
        } else if records.contains(where: { $0.status == .outputting }) {
            command = .outputting
        } else if records.contains(where: { $0.status == .working }) {
            command = .working
        } else if records.contains(where: { $0.status == .complete }) {
            command = .complete
        } else {
            command = .idle
        }

        return AgentStatePresentation(
            command: command,
            nextExpiration: records.compactMap(expiration).min()
        )
    }

    public mutating func displayCommand(now: Int64) -> AgentLightCommand {
        presentation(now: now).command
    }

    private mutating func prune(now: Int64) {
        sessions = sessions.filter { _, record in
            let age = max(0, now - record.updatedAt)
            switch record.status {
            case .idle: return false
            case .complete, .error: return age <= Self.completionRetention
            case .working, .toolRunning, .outputting, .waiting:
                return true
            }
        }
    }

    private func expiration(for record: AgentSessionRecord) -> Int64? {
        switch record.status {
        case .idle:
            return nil
        case .complete, .error:
            return record.updatedAt + Self.completionRetention + 1
        case .working, .toolRunning, .outputting, .waiting:
            return nil
        }
    }
}
