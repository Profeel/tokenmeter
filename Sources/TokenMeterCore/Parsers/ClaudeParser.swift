import Foundation

public struct ClaudeParser: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)) {
        self.baseDirectory = baseDirectory
    }

    public func parse(since: Date? = nil) -> [UsageRecord] {
        let projectsDir = baseDirectory.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectsDir.path),
              let enumerator = FileManager.default.enumerator(
                  at: projectsDir,
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var records: [UsageRecord] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if let since,
               let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = vals.contentModificationDate,
               mtime < since {
                continue
            }
            records.append(contentsOf: parseFile(url, since: since))
        }
        return records
    }

    public func parseFile(_ fileURL: URL, since: Date? = nil) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let fallbackSessionId = fileURL.deletingPathExtension().lastPathComponent
        var dedupByMsgId: [String: UsageRecord] = [:]
        var anonymousRecords: [UsageRecord] = []

        content.enumerateLines { line, _ in
            guard !line.isEmpty, line.contains("\"usage\"") else { return }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usageObj = msg["usage"] as? [String: Any] else {
                return
            }

            let model = (msg["model"] as? String) ?? "claude-unknown"
            if model == "<synthetic>" { return }

            let input = Self.int64Val(usageObj["input_tokens"])
            let output = Self.int64Val(usageObj["output_tokens"])
            let cacheRead = Self.int64Val(usageObj["cache_read_input_tokens"])
            let cacheWrite = Self.int64Val(usageObj["cache_creation_input_tokens"])

            guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { return }

            let ts = Formatters.parseISO8601(obj["timestamp"] as? String) ?? Date(timeIntervalSince1970: 0)
            if let since, ts < since { return }

            let sessionId = (obj["sessionId"] as? String) ?? fallbackSessionId
            let record = UsageRecord(
                agent: .claude,
                profile: "default",
                sessionId: sessionId,
                model: model,
                provider: "anthropic",
                baseURL: nil,
                timestamp: ts,
                usage: TokenUsage(
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    reasoningTokens: 0,
                    apiCalls: 1,
                    reportedCostUSD: nil
                )
            )

            if let msgId = msg["id"] as? String, !msgId.isEmpty {
                if let existing = dedupByMsgId[msgId] {
                    if record.usage.totalTokens >= existing.usage.totalTokens {
                        dedupByMsgId[msgId] = record
                    }
                } else {
                    dedupByMsgId[msgId] = record
                }
            } else {
                anonymousRecords.append(record)
            }
        }

        return Array(dedupByMsgId.values) + anonymousRecords
    }

    private static func int64Val(_ any: Any?) -> Int64 {
        if let n = any as? NSNumber { return n.int64Value }
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        return 0
    }
}
