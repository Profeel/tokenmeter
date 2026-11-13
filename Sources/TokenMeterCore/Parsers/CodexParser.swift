import Foundation

public struct CodexParser: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)) {
        self.baseDirectory = baseDirectory
    }

    public func parse(since: Date? = nil) -> [UsageRecord] {
        var jsonlFiles: [URL] = []
        for sub in ["sessions", "archived_sessions"] {
            let dir = baseDirectory.appendingPathComponent(sub, isDirectory: true)
            jsonlFiles.append(contentsOf: collectJSONLFiles(in: dir, modifiedAfter: since))
        }

        // Deduplicate by filename if the same rollout exists in both sessions and archived_sessions
        var seenFileNames = Set<String>()
        var records: [UsageRecord] = []

        for fileURL in jsonlFiles {
            let key = fileURL.lastPathComponent
            if seenFileNames.contains(key) { continue }
            seenFileNames.insert(key)
            records.append(contentsOf: parseFile(fileURL, since: since))
        }
        return records
    }

    public func parseFile(_ fileURL: URL, since: Date? = nil) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let sessionId = fileURL.deletingPathExtension().lastPathComponent
        var currentModel = "codex-unknown"
        var prevTotalInput: Int64 = 0
        var prevTotalCached: Int64 = 0
        var prevTotalOutput: Int64 = 0
        var prevTotalReasoning: Int64 = 0
        var prevTotalSum: Int64 = -1

        var outRecords: [UsageRecord] = []

        content.enumerateLines { line, _ in
            guard !line.isEmpty else { return }
            let needsTurnContext = line.contains("\"turn_context\"")
            let needsTokenCount = line.contains("\"token_count\"")
            guard needsTurnContext || needsTokenCount else { return }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else {
                return
            }

            if type == "turn_context",
               let payload = obj["payload"] as? [String: Any],
               let model = payload["model"] as? String, !model.isEmpty {
                currentModel = model
                return
            }

            guard type == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any] else {
                return
            }

            let totInput = Self.int64Val(totalUsage["input_tokens"])
            let totCached = Self.int64Val(totalUsage["cached_input_tokens"])
            let totOutput = Self.int64Val(totalUsage["output_tokens"])
            let totReasoning = Self.int64Val(totalUsage["reasoning_output_tokens"])
            let totSum = Self.int64Val(totalUsage["total_tokens"])

            // Deduplicate identical cumulative snapshots (Codex often emits duplicate token_count lines)
            if totSum == prevTotalSum && totInput == prevTotalInput && totOutput == prevTotalOutput {
                return
            }

            let deltaInputTotal: Int64
            let deltaCached: Int64
            let deltaOutput: Int64
            let deltaReasoning: Int64

            if totSum > prevTotalSum && prevTotalSum >= 0 {
                deltaInputTotal = max(0, totInput - prevTotalInput)
                deltaCached = max(0, totCached - prevTotalCached)
                deltaOutput = max(0, totOutput - prevTotalOutput)
                deltaReasoning = max(0, totReasoning - prevTotalReasoning)
            } else if let lastUsage = info["last_token_usage"] as? [String: Any] {
                deltaInputTotal = Self.int64Val(lastUsage["input_tokens"])
                deltaCached = Self.int64Val(lastUsage["cached_input_tokens"])
                deltaOutput = Self.int64Val(lastUsage["output_tokens"])
                deltaReasoning = Self.int64Val(lastUsage["reasoning_output_tokens"])
            } else {
                deltaInputTotal = totInput
                deltaCached = totCached
                deltaOutput = totOutput
                deltaReasoning = totReasoning
            }

            prevTotalInput = totInput
            prevTotalCached = totCached
            prevTotalOutput = totOutput
            prevTotalReasoning = totReasoning
            prevTotalSum = totSum

            let uncachedInput = max(0, deltaInputTotal - deltaCached)
            guard uncachedInput > 0 || deltaCached > 0 || deltaOutput > 0 else { return }

            let ts = Formatters.parseISO8601(obj["timestamp"] as? String) ?? Date(timeIntervalSince1970: 0)
            if let since, ts < since { return }

            outRecords.append(UsageRecord(
                agent: .codex,
                profile: "default",
                sessionId: sessionId,
                model: currentModel,
                provider: "openai",
                baseURL: nil,
                timestamp: ts,
                usage: TokenUsage(
                    inputTokens: uncachedInput,
                    outputTokens: deltaOutput,
                    cacheReadTokens: deltaCached,
                    cacheWriteTokens: 0,
                    reasoningTokens: deltaReasoning,
                    apiCalls: 1,
                    reportedCostUSD: nil
                )
            ))
        }

        return outRecords
    }

    private func collectJSONLFiles(in dir: URL, modifiedAfter: Date?) -> [URL] {
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(
                  at: dir,
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if let modifiedAfter,
               let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = vals.contentModificationDate,
               mtime < modifiedAfter {
                continue
            }
            result.append(url)
        }
        return result
    }

    private static func int64Val(_ any: Any?) -> Int64 {
        if let n = any as? NSNumber { return n.int64Value }
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        return 0
    }
}
