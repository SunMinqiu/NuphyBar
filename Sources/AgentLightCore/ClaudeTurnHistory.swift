import Foundation

public struct ClaudeTurnEvidence: Sendable {
    public let endedAt: Double
    public let status: AgentSessionStatus

    public init(endedAt: Double, status: AgentSessionStatus) {
        self.endedAt = endedAt
        self.status = status
    }
}

public final class ClaudeTurnHistory: @unchecked Sendable {
    public static let shared = ClaudeTurnHistory()
    private let locator: SessionLogLocator
    private let limit: Int
    private let lock = NSLock()

    public init(home: URL? = nil, tailLimit: Int? = nil) {
        let claude = home ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        locator = SessionLogLocator(roots: [claude.appending(path: "projects")], naming: .session)
        limit = max(1024, tailLimit ?? SessionLogSnapshot.tailLimit)
    }

    public func completion(sessionID: String, transcriptPath: String?, notBefore: Double) -> ClaudeTurnEvidence? {
        lock.withLock {
            guard UUID(uuidString: sessionID) != nil else { return nil }
            if let transcriptPath, !transcriptPath.hasPrefix("/") { return nil }
            let hinted = transcriptPath.map { URL(fileURLWithPath: $0) }
            if let hinted, (!hinted.path.hasPrefix("/") || hinted.lastPathComponent != "\(sessionID).jsonl"
                || hinted.pathComponents.contains("subagents")) { return nil }
            guard let url = hinted ?? locator.resolve(sessionID) else { return nil }
            return SessionLogSnapshot.inspect(url: url, limit: limit) { _, data in
                let decoder = JSONDecoder()
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var chain: Set<String> = []
                var tools: Set<String> = []
                var latestActivity = notBefore
                var ending: ClaudeTurnEvidence?
                for line in data.split(separator: 10) {
                    let event = try decoder.decode(Entry.self, from: Data(line))
                    guard event.isSidechain != true else { continue }
                    switch event.type {
                    case "assistant", "user", "attachment", "api-request", "api-request-blob", "api-request-shape", "queue-operation":
                        guard event.sessionId == sessionID else { return nil }
                    default:
                        if ["last-prompt", "ai-title", "atis-latch", "file-history-snapshot"].contains(event.type) { continue }
                        if event.type == "system", ["turn_duration", "stop_hook_summary", "hook_progress"]
                            .contains(event.subtype ?? "") {
                            if let parent = event.parentUuid, let uuid = event.uuid, chain.contains(parent) {
                                chain.insert(uuid)
                            }
                            continue
                        }
                        ending = nil
                        continue
                    }
                    ending = nil
                    if event.type == "api-request-blob" { continue }
                    guard let timestamp = event.timestamp, let date = formatter.date(from: timestamp) else { return nil }
                    let time = date.timeIntervalSince1970
                    if event.type == "attachment" {
                        if let parent = event.parentUuid, let uuid = event.uuid, chain.contains(parent) {
                            chain.insert(uuid)
                        } else { chain = []; tools = [] }
                        latestActivity = max(latestActivity, time)
                        continue
                    }
                    if event.type == "api-request" || event.type == "api-request-shape" || event.type == "queue-operation" {
                        latestActivity = max(latestActivity, time)
                        continue
                    }
                    guard let uuid = event.uuid, let message = event.message else { return nil }
                    if event.type == "user" {
                        let results = message.blocks?.filter { $0.type == "tool_result" } ?? []
                        if results.isEmpty {
                            chain = [uuid]
                            tools = []
                        } else {
                            guard let parent = event.parentUuid, chain.contains(parent) else {
                                chain = []; tools = []
                                latestActivity = max(latestActivity, time)
                                continue
                            }
                            chain.insert(uuid)
                            for result in results {
                                guard let id = result.toolUseID else { return nil }
                                tools.remove(id)
                            }
                        }
                        latestActivity = max(latestActivity, time)
                        continue
                    }
                    guard let parent = event.parentUuid, chain.contains(parent),
                          let blocks = message.blocks else {
                        chain = []; tools = []
                        latestActivity = max(latestActivity, time)
                        continue
                    }
                    chain.insert(uuid)
                    for block in blocks where block.type == "tool_use" {
                        guard let id = block.id else { return nil }
                        tools.insert(id)
                    }
                    if time >= latestActivity, tools.isEmpty,
                       !blocks.contains(where: { $0.type == "tool_use" }) {
                        if event.isApiErrorMessage == true,
                           ["stop_sequence", "end_turn"].contains(message.stopReason ?? "") {
                            ending = ClaudeTurnEvidence(endedAt: time, status: .error)
                        } else if event.isApiErrorMessage != true, message.stopReason == "end_turn" {
                            ending = ClaudeTurnEvidence(endedAt: time, status: .complete)
                        }
                    }
                    latestActivity = max(latestActivity, time)
                }
                return ending
            }
        }
    }

    private struct Entry: Decodable {
        let type: String
        let timestamp: String?
        let sessionId: String?
        let uuid: String?
        let parentUuid: String?
        let subtype: String?
        let isSidechain: Bool?
        let isApiErrorMessage: Bool?
        let message: Message?
        enum CodingKeys: String, CodingKey {
            case type, timestamp, sessionId, uuid, parentUuid, subtype, isSidechain, isApiErrorMessage, message
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp)
            sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId)
            uuid = try values.decodeIfPresent(String.self, forKey: .uuid)
            parentUuid = try values.decodeIfPresent(String.self, forKey: .parentUuid)
            subtype = try values.decodeIfPresent(String.self, forKey: .subtype)
            isSidechain = try values.decodeIfPresent(Bool.self, forKey: .isSidechain)
            isApiErrorMessage = try values.decodeIfPresent(Bool.self, forKey: .isApiErrorMessage)
            message = ["assistant", "user"].contains(type)
                ? try values.decodeIfPresent(Message.self, forKey: .message) : nil
        }
    }

    private struct Message: Decodable {
        let stopReason: String?
        let blocks: [Block]?
        enum CodingKeys: String, CodingKey { case stopReason = "stop_reason"; case content }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
            if var contents = try? container.nestedUnkeyedContainer(forKey: .content) {
                var values: [Block] = []
                while !contents.isAtEnd { values.append(try contents.decode(Block.self)) }
                blocks = values
            } else { blocks = nil }
        }
    }

    private struct Block: Decodable {
        let type: String
        let id: String?
        let toolUseID: String?
        enum CodingKeys: String, CodingKey { case type, id; case toolUseID = "tool_use_id" }
    }
}
