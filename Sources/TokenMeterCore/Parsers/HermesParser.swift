import Foundation

public struct HermesParser: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)) {
        self.baseDirectory = baseDirectory
    }

    public func parse(since: Date? = nil) -> [UsageRecord] {
        var dbPaths: [(profile: String, url: URL)] = []
        let mainDB = baseDirectory.appendingPathComponent("state.db")
        if FileManager.default.fileExists(atPath: mainDB.path) {
            dbPaths.append(("default", mainDB))
        }

        let profilesDir = baseDirectory.appendingPathComponent("profiles", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in entries {
                let db = dir.appendingPathComponent("state.db")
                if FileManager.default.fileExists(atPath: db.path) {
                    dbPaths.append((dir.lastPathComponent, db))
                }
            }
        }

        var records: [UsageRecord] = []
        let minTs = since?.timeIntervalSince1970 ?? 0

        for (profile, dbURL) in dbPaths {
            guard let reader = try? SQLiteReader(path: dbURL.path) else { continue }
            var coveredSessions = Set<String>()

            // Primary source: session_model_usage (per-model breakdown within each session)
            let smuSQL = """
            SELECT session_id, model, billing_provider, billing_base_url,
                   api_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
                   estimated_cost_usd, actual_cost_usd, COALESCE(last_seen, first_seen, 0) as ts
            FROM session_model_usage
            WHERE COALESCE(last_seen, first_seen, 0) >= ?
              AND (input_tokens > 0 OR output_tokens > 0 OR cache_read_tokens > 0)
            """
            try? reader.query(smuSQL, bind: [minTs]) { stmt in
                let sessionId = SQLiteReader.text(stmt, 0) ?? "unknown"
                let model = SQLiteReader.text(stmt, 1) ?? "unknown"
                let provider = SQLiteReader.text(stmt, 2)
                let baseURL = SQLiteReader.text(stmt, 3)
                let apiCalls = SQLiteReader.int64(stmt, 4)
                let input = SQLiteReader.int64(stmt, 5)
                let output = SQLiteReader.int64(stmt, 6)
                let cacheRead = SQLiteReader.int64(stmt, 7)
                let cacheWrite = SQLiteReader.int64(stmt, 8)
                let reasoning = SQLiteReader.int64(stmt, 9)
                let estCost = SQLiteReader.double(stmt, 10)
                let actCost = SQLiteReader.double(stmt, 11)
                let ts = SQLiteReader.double(stmt, 12) ?? 0

                coveredSessions.insert(sessionId)
                let reportedCost: Double?
                if let a = actCost, a > 0 {
                    reportedCost = a
                } else if let e = estCost, e > 0 {
                    reportedCost = e
                } else {
                    reportedCost = nil
                }

                records.append(UsageRecord(
                    agent: .hermes,
                    profile: profile,
                    sessionId: sessionId,
                    model: model,
                    provider: provider,
                    baseURL: baseURL,
                    timestamp: Date(timeIntervalSince1970: ts),
                    usage: TokenUsage(
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite,
                        reasoningTokens: reasoning,
                        apiCalls: apiCalls,
                        reportedCostUSD: reportedCost
                    )
                ))
            }

            // Fallback: sessions that weren't recorded in session_model_usage
            let sessSQL = """
            SELECT id, COALESCE(model, 'unknown'), billing_provider, billing_base_url,
                   COALESCE(api_call_count, 0), input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
                   estimated_cost_usd, actual_cost_usd, COALESCE(last_activity_at, ended_at, started_at, 0) as ts
            FROM sessions
            WHERE COALESCE(last_activity_at, ended_at, started_at, 0) >= ?
              AND (input_tokens > 0 OR output_tokens > 0 OR cache_read_tokens > 0)
            """
            try? reader.query(sessSQL, bind: [minTs]) { stmt in
                let sessionId = SQLiteReader.text(stmt, 0) ?? "unknown"
                if coveredSessions.contains(sessionId) { return }
                let model = SQLiteReader.text(stmt, 1) ?? "unknown"
                let provider = SQLiteReader.text(stmt, 2)
                let baseURL = SQLiteReader.text(stmt, 3)
                let apiCalls = SQLiteReader.int64(stmt, 4)
                let input = SQLiteReader.int64(stmt, 5)
                let output = SQLiteReader.int64(stmt, 6)
                let cacheRead = SQLiteReader.int64(stmt, 7)
                let cacheWrite = SQLiteReader.int64(stmt, 8)
                let reasoning = SQLiteReader.int64(stmt, 9)
                let estCost = SQLiteReader.double(stmt, 10)
                let actCost = SQLiteReader.double(stmt, 11)
                let ts = SQLiteReader.double(stmt, 12) ?? 0

                let reportedCost: Double?
                if let a = actCost, a > 0 {
                    reportedCost = a
                } else if let e = estCost, e > 0 {
                    reportedCost = e
                } else {
                    reportedCost = nil
                }

                records.append(UsageRecord(
                    agent: .hermes,
                    profile: profile,
                    sessionId: sessionId,
                    model: model,
                    provider: provider,
                    baseURL: baseURL,
                    timestamp: Date(timeIntervalSince1970: ts),
                    usage: TokenUsage(
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite,
                        reasoningTokens: reasoning,
                        apiCalls: apiCalls,
                        reportedCostUSD: reportedCost
                    )
                ))
            }
        }

        return records
    }
}
