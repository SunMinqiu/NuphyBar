import Darwin
import Foundation

public struct CodexTurnEvidence: Sendable {
    public let closedTurns: Set<String>
    public let endedAt: Double

    public init(closedTurns: Set<String>, endedAt: Double) {
        self.closedTurns = closedTurns
        self.endedAt = endedAt
    }
}

/// Extracts lifecycle metadata from a bounded local rollout tail.
public final class CodexTurnHistory: @unchecked Sendable {
    public static let shared = CodexTurnHistory()
    private let roots: [URL]
    private let tailLimit: Int
    private let lock = NSLock()
    private var paths: [String: URL] = [:]
    private var missing: [String: TimeInterval] = [:]

    public init(home: URL? = nil, tailLimit: Int = 2 * 1024 * 1024) {
        let codex = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        roots = [codex.appending(path: "sessions"), codex.appending(path: "archived_sessions")]
        self.tailLimit = max(1024, tailLimit)
    }

    public func completion(sessionID: String, turnID: String, beganAt: Double) -> CodexTurnEvidence? {
        lock.withLock {
            guard UUID(uuidString: sessionID) != nil, !turnID.isEmpty,
                  let url = resolve(sessionID), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            do {
                var before = stat()
                guard fstat(handle.fileDescriptor, &before) == 0 else { return nil }
                let size = try handle.seekToEnd()
                guard size > 0 else { return nil }
                try handle.seek(toOffset: 0)
                let header = try handle.read(upToCount: 64 * 1024) ?? Data()
                guard let newline = header.firstIndex(of: 10),
                      let meta = try? JSONDecoder().decode(Envelope.self, from: header.prefix(upTo: newline)),
                      meta.type == "session_meta", meta.payload.id == sessionID else { return nil }
                let start = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
                try handle.seek(toOffset: start)
                var data = try handle.read(upToCount: tailLimit) ?? Data()
                guard data.count == Int(size - start), data.last == 10 else { return nil }
                if start > 0 {
                    guard let newline = data.firstIndex(of: 10) else { return nil }
                    data = Data(data.suffix(from: data.index(after: newline)))
                }
                var open: Set<String> = []
                var closed: Set<String> = []
                var matchingEnd: Double?
                var lastTime: Double = 0
                var lastWasEnd = false
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let decoder = JSONDecoder()
                for line in data.split(separator: 10) {
                    let event = try decoder.decode(Envelope.self, from: Data(line))
                    guard event.type == "event_msg" else { continue }
                    guard let kind = event.payload.type else { return nil }
                    let relevant = ["task_started", "task_complete", "turn_aborted"].contains(kind)
                    if !relevant {
                        // Unknown lifecycle schemas cannot establish that work has ended.
                        if kind.hasPrefix("task_") || kind.hasPrefix("turn_") { return nil }
                        continue
                    }
                    guard let turn = event.payload.turnID, !turn.isEmpty,
                          let timestamp = event.timestamp,
                          let date = formatter.date(from: timestamp), date.timeIntervalSince1970 >= lastTime else { return nil }
                    lastTime = date.timeIntervalSince1970
                    if kind == "task_started" {
                        open.insert(turn)
                        closed.remove(turn)
                        if turn == turnID { matchingEnd = nil }
                        lastWasEnd = false
                    } else {
                        open.remove(turn)
                        closed.insert(turn)
                        if turn == turnID { matchingEnd = lastTime }
                        lastWasEnd = true
                    }
                }
                // An append during inspection requires a fresh snapshot, not a cleanup.
                var after = stat()
                guard lstat(url.path, &after) == 0,
                      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                      before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      try handle.seekToEnd() == size, open.isEmpty, lastWasEnd,
                      let matchingEnd, matchingEnd >= beganAt else { return nil }
                return CodexTurnEvidence(closedTurns: closed, endedAt: lastTime)
            } catch {
                return nil
            }
        }
    }

    private func resolve(_ session: String) -> URL? {
        if let url = paths[session], FileManager.default.fileExists(atPath: url.path) { return url }
        let now = ProcessInfo.processInfo.systemUptime
        if let checked = missing[session], now - checked < 30 { return nil }
        var found: URL?
        var count = 0
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                count += 1
                guard count <= 50_000 else { return nil }
                guard url.lastPathComponent.hasSuffix("-\(session).jsonl") else { continue }
                guard found == nil else { return nil }
                found = url
            }
        }
        if paths.count >= 128 { paths.removeAll() }
        if missing.count >= 128 { missing.removeAll() }
        if let found { paths[session] = found } else { missing[session] = now }
        return found
    }

    private struct Envelope: Decodable {
        let type: String
        let timestamp: String?
        let payload: Metadata
    }

    private struct Metadata: Decodable {
        let type: String?
        let id: String?
        let turnID: String?
        enum CodingKeys: String, CodingKey {
            case type, id
            case turnID = "turn_id"
        }
    }
}
