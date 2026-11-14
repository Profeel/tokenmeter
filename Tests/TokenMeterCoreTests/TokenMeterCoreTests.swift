import XCTest
import SQLite3
@testable import TokenMeterCore

final class TokenMeterCoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testCodexParserDeduplicatesCumulativeTokenCounts() throws {
        let sessionsDir = tmpDir.appendingPathComponent("sessions/2026/11/14", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let file = sessionsDir.appendingPathComponent("rollout-test.jsonl")

        let lines = [
            #"{"timestamp":"2026-11-14T01:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-terra"}}"#,
            #"{"timestamp":"2026-11-14T01:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100}}}}"#,
            // Duplicate snapshot emitted by Codex
            #"{"timestamp":"2026-11-14T01:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100}}}}"#,
            // Second turn
            #"{"timestamp":"2026-11-14T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":500,"output_tokens":150,"reasoning_output_tokens":30,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"cached_input_tokens":300,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":550}}}}"#
        ].joined(separator: "\n")

        try lines.write(to: file, atomically: true, encoding: .utf8)

        let records = CodexParser(baseDirectory: tmpDir).parse()
        XCTAssertEqual(records.count, 2)
        let totalInput = records.reduce(Int64(0)) { $0 + $1.usage.inputTokens }
        let totalCacheRead = records.reduce(Int64(0)) { $0 + $1.usage.cacheReadTokens }
        let totalOutput = records.reduce(Int64(0)) { $0 + $1.usage.outputTokens }
        // Input in Codex includes cached_input_tokens, so uncached input = 1500 - 500 = 1000
        XCTAssertEqual(totalInput, 1000)
        XCTAssertEqual(totalCacheRead, 500)
        XCTAssertEqual(totalOutput, 150)
        XCTAssertEqual(records.first?.model, "gpt-6.1-terra")
    }

    func testClaudeParserDeduplicatesStreamingMessageId() throws {
        let projDir = tmpDir.appendingPathComponent("projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let file = projDir.appendingPathComponent("sess1.jsonl")

        let lines = [
            #"{"timestamp":"2026-11-14T02:00:00Z","sessionId":"s1","message":{"id":"msg_1","model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":500,"cache_creation_input_tokens":200}}}"#,
            #"{"timestamp":"2026-11-14T02:00:02Z","sessionId":"s1","message":{"id":"msg_1","model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":80,"cache_read_input_tokens":500,"cache_creation_input_tokens":200}}}"#,
            #"{"timestamp":"2026-11-14T02:00:03Z","sessionId":"s1","message":{"id":"msg_syn","model":"<synthetic>","usage":{"input_tokens":10,"output_tokens":10}}}"#
        ].joined(separator: "\n")

        try lines.write(to: file, atomically: true, encoding: .utf8)

        let records = ClaudeParser(baseDirectory: tmpDir).parse()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].usage.outputTokens, 80)
        XCTAssertEqual(records[0].usage.cacheReadTokens, 500)
        XCTAssertEqual(records[0].usage.cacheWriteTokens, 200)
    }

    func testPiParserReadsTokensAndCost() throws {
        let sessDir = tmpDir.appendingPathComponent("agent/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessDir, withIntermediateDirectories: true)
        let file = sessDir.appendingPathComponent("pi1.jsonl")

        let line = #"{"type":"message","id":"m1","timestamp":"2026-11-14T03:00:00Z","message":{"role":"assistant","provider":"magpie","model":"claude-sonnet-5-5","usage":{"input":120,"output":45,"cacheRead":1000,"cacheWrite":250,"totalTokens":1415,"cost":{"total":0.0125}}}}"#
        try line.write(to: file, atomically: true, encoding: .utf8)

        let records = PiParser(baseDirectory: tmpDir).parse()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].usage.inputTokens, 120)
        XCTAssertEqual(records[0].usage.outputTokens, 45)
        XCTAssertEqual(records[0].usage.reportedCostUSD ?? 0, 0.0125, accuracy: 0.00001)
    }

    func testHermesAndOpenCodeSQLiteParsers() throws {
        let hermesDB = tmpDir.appendingPathComponent("state.db")
        try executeSQL(at: hermesDB.path, sql: """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT, billing_provider TEXT, billing_base_url TEXT, api_call_count INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, estimated_cost_usd REAL, actual_cost_usd REAL, started_at REAL, ended_at REAL, last_activity_at REAL);
        CREATE TABLE session_model_usage (session_id TEXT, model TEXT, billing_provider TEXT, billing_base_url TEXT, api_call_count INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, estimated_cost_usd REAL, actual_cost_usd REAL, first_seen REAL, last_seen REAL);
        INSERT INTO session_model_usage VALUES ('hs1', 'antigravity/gemini-4-hydrogen', 'custom', 'http://127.0.0.1:3425/v1', 5, 10000, 2000, 50000, 0, 500, 0.0, 0.0, 1794586500.0, 1794586590.0);
        """)

        let hRecords = HermesParser(baseDirectory: tmpDir).parse()
        XCTAssertEqual(hRecords.count, 1)
        XCTAssertEqual(hRecords[0].usage.inputTokens, 10000)
        XCTAssertEqual(hRecords[0].usage.cacheReadTokens, 50000)

        let ocDB = tmpDir.appendingPathComponent("opencode.db")
        try executeSQL(at: ocDB.path, sql: """
        CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, tokens_reasoning INTEGER, cost REAL, time_created INTEGER, time_updated INTEGER);
        INSERT INTO session VALUES ('oc1', '{"id":"auto/glm-5.3","providerID":"magpie"}', 4000, 300, 0, 0, 0, 0.05, 1794586500000, 1794586590000);
        """)

        let ocRecords = OpenCodeParser(databaseURL: ocDB).parse()
        XCTAssertEqual(ocRecords.count, 1)
        XCTAssertEqual(ocRecords[0].model, "auto/glm-5.3")
        XCTAssertEqual(ocRecords[0].usage.reportedCostUSD ?? 0, 0.05, accuracy: 0.0001)
    }

    func testEngineAggregationAndPricing() {
        let now = Date()
        let recs = [
            UsageRecord(agent: .codex, sessionId: "c1", model: "gpt-6.1-terra", timestamp: now, usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 100_000, cacheReadTokens: 0)),
            UsageRecord(agent: .hermes, sessionId: "h1", model: "antigravity/gemini-4-hydrogen", timestamp: now, usage: TokenUsage(inputTokens: 100_000, outputTokens: 10_000, cacheReadTokens: 1_000_000))
        ]
        let snap = TokenMeterEngine().aggregate(records: recs, window: .today, now: now)
        XCTAssertEqual(snap.agentBreakdowns.count, 2)
        XCTAssertGreaterThan(snap.totalEstimatedCostUSD, 4.0)
        XCTAssertEqual(snap.totalUsage.totalTokens, 2_210_000)
    }

    func testQuotaTrackerParsesMultiSubscriptionWindows() {
        let json = """
        {
          "data": [
            {
              "provider": "codex",
              "name": "Codex",
              "kind": "subscription",
              "plan": "prolite",
              "user": "dev@example.com",
              "windows": [
                {"name": "7 days", "used": 33, "remaining": 67, "resetsAt": "2026-11-20T08:59:09+08:00"}
              ]
            },
            {
              "provider": "opendesign",
              "name": "Open Design",
              "kind": "subscription",
              "plan": "Design Plan Go",
              "user": "dev@example.com",
              "balance": "$1.00",
              "windows": [
                {"name": "5 hours", "used": 0, "remaining": 100, "display": "0 / 50k credits"},
                {"name": "7 days", "used": 52.7, "remaining": 47.3, "display": "79k / 150k credits"}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = QuotaTracker().parseGatewayQuotasJSON(data: json)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].windows.first?.usedPercent ?? 0, 33, accuracy: 0.01)
        XCTAssertEqual(parsed[1].balanceText, "$1.00")
        XCTAssertEqual(parsed[1].windows.count, 2)
        XCTAssertEqual(parsed[1].windows[1].usedPercent, 52.7, accuracy: 0.01)
    }

    func testAlertEvaluatorFiresThresholdResetAnd429WithDeduplication() {
        let evaluator = AlertEvaluator()
        let cfg = TokenMeterConfig(dailyBudgetUSD: 20, budgetAlertRatio: 0.8, quotaAlertPercent: 85, enableNotifications: true)
        let t0 = Date()

        // Baseline run: quota already at 50%, healthy endpoint
        let q0 = [SubscriptionQuota(provider: "codex", name: "Codex", kind: .subscription, windows: [QuotaWindow(name: "7 days", usedPercent: 50)], source: "gateway")]
        let ep = DiscoveredEndpoint(name: "gw", baseURL: "http://127.0.0.1:3425/v1", source: "hermes", kind: .openAI)
        let p0 = [EndpointProbeResult(endpoint: ep, status: .healthy, httpStatusCode: 200, latencyMs: 12)]
        XCTAssertTrue(evaluator.evaluate(todaySnapshot: nil, quotas: q0, probes: p0, config: cfg, now: t0).isEmpty)

        // Crosses 85% and hits 429
        let q1 = [SubscriptionQuota(provider: "codex", name: "Codex", kind: .subscription, windows: [QuotaWindow(name: "7 days", usedPercent: 88)], source: "gateway")]
        let p1 = [EndpointProbeResult(endpoint: ep, status: .rateLimited, httpStatusCode: 429, latencyMs: 25)]
        let alerts1 = evaluator.evaluate(todaySnapshot: nil, quotas: q1, probes: p1, config: cfg, now: t0.addingTimeInterval(60))
        XCTAssertEqual(alerts1.count, 2)

        // Repeated check should not re-fire
        let alerts2 = evaluator.evaluate(todaySnapshot: nil, quotas: q1, probes: p1, config: cfg, now: t0.addingTimeInterval(120))
        XCTAssertTrue(alerts2.isEmpty)

        // Exhausts to 99%, then resets back to 5% -> fires exhaust then reset recovery
        let q2 = [SubscriptionQuota(provider: "codex", name: "Codex", kind: .subscription, windows: [QuotaWindow(name: "7 days", usedPercent: 99)], source: "gateway")]
        let alerts3 = evaluator.evaluate(todaySnapshot: nil, quotas: q2, probes: p0, config: cfg, now: t0.addingTimeInterval(180))
        XCTAssertTrue(alerts3.contains(where: { $0.id.hasPrefix("quota-exhausted-") }))
        XCTAssertTrue(alerts3.contains(where: { $0.id.hasPrefix("probe-recover-") }))

        let q3 = [SubscriptionQuota(provider: "codex", name: "Codex", kind: .subscription, windows: [QuotaWindow(name: "7 days", usedPercent: 5)], source: "gateway")]
        let alerts4 = evaluator.evaluate(todaySnapshot: nil, quotas: q3, probes: p0, config: cfg, now: t0.addingTimeInterval(240))
        XCTAssertTrue(alerts4.contains(where: { $0.id.hasPrefix("quota-reset-") }))
    }

    private func executeSQL(at path: String, sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(errMsg)
            XCTFail(msg)
        }
    }
}
