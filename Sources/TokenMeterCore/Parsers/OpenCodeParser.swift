import Foundation

public struct OpenCodeParser: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db")) {
        self.databaseURL = databaseURL
    }

    public func parse(since: Date? = nil) -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let reader = try? SQLiteReader(path: databaseURL.path) else {
            return []
        }

        let minMs = Int64((since?.timeIntervalSince1970 ?? 0) * 1000.0)
        let sql = """
        SELECT id, COALESCE(model, 'opencode-unknown'),
               COALESCE(tokens_input, 0), COALESCE(tokens_output, 0),
               COALESCE(tokens_cache_read, 0), COALESCE(tokens_cache_write, 0),
               COALESCE(tokens_reasoning, 0), cost, COALESCE(time_updated, time_created, 0)
        FROM session
        WHERE COALESCE(time_updated, time_created, 0) >= ?
          AND (COALESCE(tokens_input, 0) > 0 OR COALESCE(tokens_output, 0) > 0 OR COALESCE(tokens_cache_read, 0) > 0)
        """

        var records: [UsageRecord] = []
        try? reader.query(sql, bind: [minMs]) { stmt in
            let sessionId = SQLiteReader.text(stmt, 0) ?? "unknown"
            let rawModel = SQLiteReader.text(stmt, 1) ?? "opencode-unknown"
            let input = SQLiteReader.int64(stmt, 2)
            let output = SQLiteReader.int64(stmt, 3)
            let cacheRead = SQLiteReader.int64(stmt, 4)
            let cacheWrite = SQLiteReader.int64(stmt, 5)
            let reasoning = SQLiteReader.int64(stmt, 6)
            let cost = SQLiteReader.double(stmt, 7)
            let timeMs = SQLiteReader.int64(stmt, 8)

            var modelId = rawModel
            var providerId: String? = nil
            if rawModel.hasPrefix("{"),
               let mData = rawModel.data(using: .utf8),
               let mObj = try? JSONSerialization.jsonObject(with: mData) as? [String: Any] {
                if let id = mObj["id"] as? String { modelId = id }
                providerId = mObj["providerID"] as? String
            }

            let reportedCost: Double? = (cost ?? 0) > 0 ? cost : nil
            records.append(UsageRecord(
                agent: .opencode,
                profile: "default",
                sessionId: sessionId,
                model: modelId,
                provider: providerId,
                baseURL: nil,
                timestamp: Date(timeIntervalSince1970: Double(timeMs) / 1000.0),
                usage: TokenUsage(
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    reasoningTokens: reasoning,
                    apiCalls: 1,
                    reportedCostUSD: reportedCost
                )
            ))
        }

        return records
    }
}
