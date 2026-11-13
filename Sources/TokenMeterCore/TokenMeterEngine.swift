import Foundation

public struct TokenMeterEngine: Sendable {
    public let hermes: HermesParser
    public let codex: CodexParser
    public let claude: ClaudeParser
    public let pi: PiParser
    public let opencode: OpenCodeParser
    public let pricing: PricingCatalog

    public init(
        hermes: HermesParser = HermesParser(),
        codex: CodexParser = CodexParser(),
        claude: ClaudeParser = ClaudeParser(),
        pi: PiParser = PiParser(),
        opencode: OpenCodeParser = OpenCodeParser(),
        pricing: PricingCatalog = .shared
    ) {
        self.hermes = hermes
        self.codex = codex
        self.claude = claude
        self.pi = pi
        self.opencode = opencode
        self.pricing = pricing
    }

    public func collectRecords(since: Date? = nil) -> [UsageRecord] {
        var all: [UsageRecord] = []
        all.append(contentsOf: hermes.parse(since: since))
        all.append(contentsOf: codex.parse(since: since))
        all.append(contentsOf: claude.parse(since: since))
        all.append(contentsOf: pi.parse(since: since))
        all.append(contentsOf: opencode.parse(since: since))
        return all
    }

    public func buildSnapshot(
        window: TimeWindow,
        config: TokenMeterConfig = .load(),
        now: Date = Date()
    ) -> MeterSnapshot {
        let since = window.startDate(relativeTo: now)
        let records = collectRecords(since: since)
        return aggregate(records: records, window: window, config: config, now: now)
    }

    public func aggregate(
        records: [UsageRecord],
        window: TimeWindow,
        config: TokenMeterConfig = .load(),
        now: Date = Date()
    ) -> MeterSnapshot {
        let since = window.startDate(relativeTo: now)
        let filtered = records.filter { rec in
            if let since { return rec.timestamp >= since }
            return true
        }

        var totalUsage = TokenUsage()
        var totalCostUSD = 0.0

        var agentUsage: [AgentKind: TokenUsage] = [:]
        var agentCosts: [AgentKind: Double] = [:]
        var agentSessions: [AgentKind: Set<String>] = [:]
        var agentLastActive: [AgentKind: Date] = [:]
        var agentModelTokens: [AgentKind: [String: Int64]] = [:]

        struct ModelKey: Hashable {
            let agent: AgentKind
            let model: String
        }
        var modelUsages: [ModelKey: TokenUsage] = [:]
        var modelCosts: [ModelKey: Double] = [:]
        var modelEstimatedFlags: [ModelKey: Bool] = [:]

        var dailyMap: [String: (date: Date, tokens: Int64, cost: Double)] = [:]
        let calendar = Calendar.current

        for rec in filtered {
            let costEval = pricing.estimateCostUSD(model: rec.model, usage: rec.usage, overrides: config.modelPriceOverrides)

            totalUsage = totalUsage + rec.usage
            totalCostUSD += costEval.cost

            agentUsage[rec.agent] = (agentUsage[rec.agent] ?? TokenUsage()) + rec.usage
            agentCosts[rec.agent] = (agentCosts[rec.agent] ?? 0) + costEval.cost
            agentSessions[rec.agent, default: []].insert(rec.sessionId)
            if let prev = agentLastActive[rec.agent] {
                if rec.timestamp > prev { agentLastActive[rec.agent] = rec.timestamp }
            } else {
                agentLastActive[rec.agent] = rec.timestamp
            }

            let shortModel = pricing.shortDisplayModel(rec.model)
            var mTokens = agentModelTokens[rec.agent] ?? [:]
            mTokens[shortModel] = (mTokens[shortModel] ?? 0) + rec.usage.totalTokens
            agentModelTokens[rec.agent] = mTokens

            let mk = ModelKey(agent: rec.agent, model: shortModel)
            modelUsages[mk] = (modelUsages[mk] ?? TokenUsage()) + rec.usage
            modelCosts[mk] = (modelCosts[mk] ?? 0) + costEval.cost
            modelEstimatedFlags[mk] = (modelEstimatedFlags[mk] ?? false) || costEval.estimated

            let dKey = Formatters.dayKey(rec.timestamp, calendar: calendar)
            let dayStart = calendar.startOfDay(for: rec.timestamp)
            var entry = dailyMap[dKey] ?? (date: dayStart, tokens: 0, cost: 0)
            entry.tokens += rec.usage.totalTokens
            entry.cost += costEval.cost
            dailyMap[dKey] = entry
        }

        let agentBreakdowns: [AgentBreakdown] = AgentKind.allCases.compactMap { kind in
            guard let u = agentUsage[kind] else { return nil }
            let topModel = agentModelTokens[kind]?.max(by: { $0.value < $1.value })?.key
            return AgentBreakdown(
                agent: kind,
                usage: u,
                estimatedCostUSD: agentCosts[kind] ?? 0,
                sessionCount: agentSessions[kind]?.count ?? 0,
                lastActiveAt: agentLastActive[kind],
                topModel: topModel
            )
        }.sorted { $0.usage.totalTokens > $1.usage.totalTokens }

        let modelBreakdowns: [ModelBreakdown] = modelUsages.map { key, usage in
            ModelBreakdown(
                model: key.model,
                agent: key.agent,
                usage: usage,
                estimatedCostUSD: modelCosts[key] ?? 0,
                isCostEstimated: modelEstimatedFlags[key] ?? true
            )
        }.sorted { $0.estimatedCostUSD == $1.estimatedCostUSD ? $0.usage.totalTokens > $1.usage.totalTokens : $0.estimatedCostUSD > $1.estimatedCostUSD }

        let dailyBurn: [DailyBurnPoint] = dailyMap.map { key, val in
            DailyBurnPoint(dayKey: key, date: val.date, totalTokens: val.tokens, estimatedCostUSD: val.cost)
        }.sorted { $0.date < $1.date }

        return MeterSnapshot(
            window: window,
            generatedAt: now,
            totalUsage: totalUsage,
            totalEstimatedCostUSD: totalCostUSD,
            agentBreakdowns: agentBreakdowns,
            modelBreakdowns: modelBreakdowns,
            dailyBurn: dailyBurn,
            dailyBudgetUSD: config.dailyBudgetUSD,
            budgetAlertRatio: config.budgetAlertRatio
        )
    }
}
