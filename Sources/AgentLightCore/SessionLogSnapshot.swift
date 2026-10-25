import Darwin
import Foundation

enum SessionLogSnapshot {
    static let tailLimit = 2 * 1024 * 1024

    static func inspect<Value>(url: URL, limit: Int = tailLimit,
        parse: (Data, Data) throws -> Value?) -> Value? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            var before = stat()
            guard fstat(handle.fileDescriptor, &before) == 0 else { return nil }
            let size = try handle.seekToEnd()
            guard size > 0 else { return nil }
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: 64 * 1024) ?? Data()
            let start = size > UInt64(limit) ? size - UInt64(limit) : 0
            try handle.seek(toOffset: start)
            var data = try handle.read(upToCount: limit) ?? Data()
            guard data.count == Int(size - start), data.last == 10 else { return nil }
            if start > 0 {
                guard let newline = data.firstIndex(of: 10) else { return nil }
                data = Data(data.suffix(from: data.index(after: newline)))
            }
            guard let value = try parse(header, data) else { return nil }
            var after = stat()
            guard lstat(url.path, &after) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  try handle.seekToEnd() == size else { return nil }
            return value
        } catch { return nil }
    }
}

final class SessionLogLocator {
    enum Naming { case rollout, session }
    private let roots: [URL]
    private let naming: Naming
    private var paths: [String: URL] = [:]
    private var missing: [String: TimeInterval] = [:]

    init(roots: [URL], naming: Naming) { self.roots = roots; self.naming = naming }

    func resolve(_ session: String) -> URL? {
        guard UUID(uuidString: session) != nil else { return nil }
        if let url = paths[session], FileManager.default.fileExists(atPath: url.path) { return url }
        let now = ProcessInfo.processInfo.systemUptime
        if let checked = missing[session], now - checked < 30 { return nil }
        var found: URL?
        var count = 0
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                if naming == .session, url.lastPathComponent == "subagents" {
                    files.skipDescendants()
                    continue
                }
                count += 1
                guard count <= 50_000 else { return nil }
                let matches = naming == .rollout
                    ? url.lastPathComponent.hasSuffix("-\(session).jsonl")
                    : url.lastPathComponent == "\(session).jsonl"
                guard matches else { continue }
                guard found == nil else { return nil }
                found = url
            }
        }
        if paths.count >= 128 { paths.removeAll() }
        if missing.count >= 128 { missing.removeAll() }
        if let found { paths[session] = found } else { missing[session] = now }
        return found
    }
}
