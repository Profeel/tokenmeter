import Foundation

public struct PiParser: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi", isDirectory: true)) {
        self.baseDirectory = baseDirectory
    }

    public func parse(since: Date? = nil) -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: baseDirectory.path),
              let enumerator = FileManager.default.enumerator(
                  at: baseDirectory,
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

        let sessionId = fileURL.deletingPathExtension().lastPathComponent
        var records: [UsageRecord] = []

        content.enumerateLines { line, _ in
            guard !line.isEmpty, line.contains("\"usage\"") else { return }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "message",
                  let msg = obj["message"] as? [String: Any],
                  msg["role"] as? String == "assistant",
                  let usageObj = msg["usage"] as? [String: Any] else {
                return
            }

            let input = Self.int64Val(usageObj["input"])
            let output = Self.int64Val(usageObj["output"])
            let cacheRead = Self.int64Val(usageObj["cacheRead"])
            let cacheWrite = Self.int64Val(usageObj["cacheWrite"])
            guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { return }

            let ts = Formatters.parseISO8601(obj["timestamp"] as? String) ?? Date(timeIntervalSince1970: 0)
            if let since, ts < since { return }

            let model = (msg["model"] as? String) ?? "pi-unknown"
            let provider = msg["provider"] as? String
            var costUSD: Double? = nil
            if let costObj = usageObj["cost"] as? [String: Any],
               let totalCost = (costObj["total"] as? NSNumber)?.doubleValue, totalCost > 0 {
                costUSD = totalCost
            }

            records.append(UsageRecord(
                agent: .pi,
                profile: "default",
                sessionId: sessionId,
                model: model,
                provider: provider,
                baseURL: nil,
                timestamp: ts,
                usage: TokenUsage(
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    reasoningTokens: 0,
                    apiCalls: 1,
                    reportedCostUSD: costUSD
                )
            ))
        }

        return records
    }

    private static func int64Val(_ any: Any?) -> Int64 {
        if let n = any as? NSNumber { return n.int64Value }
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        return 0
    }
}
