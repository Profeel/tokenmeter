import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case hermes = "hermes"
    case codex = "codex"
    case claude = "claude"
    case pi = "pi"
    case opencode = "opencode"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hermes: return "Hermes"
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .pi: return "Pi Agent"
        case .opencode: return "OpenCode"
        }
    }

    public var symbolName: String {
        switch self {
        case .hermes: return "flame.fill"
        case .codex: return "terminal.fill"
        case .claude: return "sparkles"
        case .pi: return "cpu.fill"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

public enum TimeWindow: String, Codable, CaseIterable, Sendable, Identifiable {
    case today = "today"
    case week = "7d"
    case month = "30d"
    case all = "all"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "今日"
        case .week: return "7天"
        case .month: return "30天"
        case .all: return "全部"
        }
    }

    public func startDate(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))
        case .month:
            return calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))
        case .all:
            return nil
        }
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var reasoningTokens: Int64
    public var apiCalls: Int64
    public var reportedCostUSD: Double?

    public init(
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        reasoningTokens: Int64 = 0,
        apiCalls: Int64 = 0,
        reportedCostUSD: Double? = nil
    ) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.apiCalls = max(0, apiCalls)
        self.reportedCostUSD = reportedCostUSD
    }

    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    public var uncachedInputTokens: Int64 {
        // Note: In OpenAI/Codex format, input_tokens often includes cached_input_tokens.
        // We normalize parsers so inputTokens = non-cached input, cacheReadTokens = cached input.
        inputTokens
    }

    public var cacheHitRate: Double {
        let totalIn = inputTokens + cacheReadTokens
        guard totalIn > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(totalIn)
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        let cost: Double?
        if let lc = lhs.reportedCostUSD, let rc = rhs.reportedCostUSD {
            cost = lc + rc
        } else {
            cost = lhs.reportedCostUSD ?? rhs.reportedCostUSD
        }
        return TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            apiCalls: lhs.apiCalls + rhs.apiCalls,
            reportedCostUSD: cost
        )
    }
}

public struct UsageRecord: Codable, Sendable {
    public var agent: AgentKind
    public var profile: String
    public var sessionId: String
    public var model: String
    public var provider: String?
    public var baseURL: String?
    public var timestamp: Date
    public var usage: TokenUsage

    public init(
        agent: AgentKind,
        profile: String = "default",
        sessionId: String,
        model: String,
        provider: String? = nil,
        baseURL: String? = nil,
        timestamp: Date,
        usage: TokenUsage
    ) {
        self.agent = agent
        self.profile = profile
        self.sessionId = sessionId
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.timestamp = timestamp
        self.usage = usage
    }
}

public struct AgentBreakdown: Codable, Sendable, Identifiable {
    public var id: String { agent.rawValue }
    public var agent: AgentKind
    public var usage: TokenUsage
    public var estimatedCostUSD: Double
    public var sessionCount: Int
    public var lastActiveAt: Date?
    public var topModel: String?

    public init(
        agent: AgentKind,
        usage: TokenUsage,
        estimatedCostUSD: Double,
        sessionCount: Int,
        lastActiveAt: Date? = nil,
        topModel: String? = nil
    ) {
        self.agent = agent
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionCount = sessionCount
        self.lastActiveAt = lastActiveAt
        self.topModel = topModel
    }
}

public struct ModelBreakdown: Codable, Sendable, Identifiable {
    public var id: String { "\(agent.rawValue)::\(model)" }
    public var model: String
    public var agent: AgentKind
    public var usage: TokenUsage
    public var estimatedCostUSD: Double
    public var isCostEstimated: Bool

    public init(
        model: String,
        agent: AgentKind,
        usage: TokenUsage,
        estimatedCostUSD: Double,
        isCostEstimated: Bool
    ) {
        self.model = model
        self.agent = agent
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
        self.isCostEstimated = isCostEstimated
    }
}

public struct DailyBurnPoint: Codable, Sendable, Identifiable {
    public var id: String { dayKey }
    public var dayKey: String
    public var date: Date
    public var totalTokens: Int64
    public var estimatedCostUSD: Double

    public init(dayKey: String, date: Date, totalTokens: Int64, estimatedCostUSD: Double) {
        self.dayKey = dayKey
        self.date = date
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public enum EndpointStatus: String, Codable, Sendable {
    case healthy = "healthy"
    case authRequired = "auth_required"
    case rateLimited = "rate_limited"
    case degraded = "degraded"
    case down = "down"

    public var label: String {
        switch self {
        case .healthy: return "正常"
        case .authRequired: return "可达(需鉴权)"
        case .rateLimited: return "429 限流"
        case .degraded: return "异常"
        case .down: return "不可达"
        }
    }
}

public struct DiscoveredEndpoint: Codable, Sendable, Identifiable {
    public var id: String { "\(name)::\(baseURL)" }
    public var name: String
    public var baseURL: String
    public var source: String
    public var kind: EndpointKind

    public init(name: String, baseURL: String, source: String, kind: EndpointKind) {
        self.name = name
        self.baseURL = baseURL
        self.source = source
        self.kind = kind
    }

    public enum EndpointKind: String, Codable, Sendable {
        case openAI = "openai"
        case anthropic = "anthropic"
        case ollama = "ollama"
        case oneAPI = "oneapi"
    }
}

public struct EndpointProbeResult: Codable, Sendable, Identifiable {
    public var id: String { endpoint.id }
    public var endpoint: DiscoveredEndpoint
    public var status: EndpointStatus
    public var httpStatusCode: Int?
    public var latencyMs: Double
    public var modelCount: Int?
    public var quotaRemainingUSD: Double?
    public var quotaUsedUSD: Double?
    public var errorMessage: String?
    public var checkedAt: Date

    public init(
        endpoint: DiscoveredEndpoint,
        status: EndpointStatus,
        httpStatusCode: Int? = nil,
        latencyMs: Double,
        modelCount: Int? = nil,
        quotaRemainingUSD: Double? = nil,
        quotaUsedUSD: Double? = nil,
        errorMessage: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.endpoint = endpoint
        self.status = status
        self.httpStatusCode = httpStatusCode
        self.latencyMs = latencyMs
        self.modelCount = modelCount
        self.quotaRemainingUSD = quotaRemainingUSD
        self.quotaUsedUSD = quotaUsedUSD
        self.errorMessage = errorMessage
        self.checkedAt = checkedAt
    }
}

public struct MeterSnapshot: Codable, Sendable {
    public var window: TimeWindow
    public var generatedAt: Date
    public var totalUsage: TokenUsage
    public var totalEstimatedCostUSD: Double
    public var agentBreakdowns: [AgentBreakdown]
    public var modelBreakdowns: [ModelBreakdown]
    public var dailyBurn: [DailyBurnPoint]
    public var dailyBudgetUSD: Double
    public var budgetAlertRatio: Double

    public init(
        window: TimeWindow,
        generatedAt: Date,
        totalUsage: TokenUsage,
        totalEstimatedCostUSD: Double,
        agentBreakdowns: [AgentBreakdown],
        modelBreakdowns: [ModelBreakdown],
        dailyBurn: [DailyBurnPoint],
        dailyBudgetUSD: Double,
        budgetAlertRatio: Double
    ) {
        self.window = window
        self.generatedAt = generatedAt
        self.totalUsage = totalUsage
        self.totalEstimatedCostUSD = totalEstimatedCostUSD
        self.agentBreakdowns = agentBreakdowns
        self.modelBreakdowns = modelBreakdowns
        self.dailyBurn = dailyBurn
        self.dailyBudgetUSD = dailyBudgetUSD
        self.budgetAlertRatio = budgetAlertRatio
    }

    public var budgetUsageRatio: Double {
        guard dailyBudgetUSD > 0 else { return 0 }
        return totalEstimatedCostUSD / dailyBudgetUSD
    }
}

public struct OneAPIConfig: Codable, Sendable {
    public var name: String
    public var baseURL: String
    public var accessToken: String
    public var userId: Int?

    public init(name: String, baseURL: String, accessToken: String, userId: Int? = nil) {
        self.name = name
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userId = userId
    }
}

public enum QuotaKind: String, Codable, Sendable {
    case subscription = "subscription"
    case apiBalance = "api_balance"
    case rateLimit = "rate_limit"
}

public struct QuotaWindow: Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var usedPercent: Double
    public var remainingPercent: Double
    public var resetsAt: Date?
    public var display: String?
    public var unit: String?

    public init(
        name: String,
        usedPercent: Double,
        remainingPercent: Double? = nil,
        resetsAt: Date? = nil,
        display: String? = nil,
        unit: String? = nil
    ) {
        self.name = name
        self.usedPercent = min(100, max(0, usedPercent))
        self.remainingPercent = min(100, max(0, remainingPercent ?? (100.0 - usedPercent)))
        self.resetsAt = resetsAt
        self.display = display
        self.unit = unit
    }
}

public struct SubscriptionQuota: Codable, Sendable, Identifiable {
    public var id: String { "\(source)::\(provider)::\(accountLabel ?? "default")" }
    public var provider: String
    public var name: String
    public var kind: QuotaKind
    public var plan: String?
    public var accountLabel: String?
    public var balanceText: String?
    public var usedUSD: Double?
    public var remainingUSD: Double?
    public var windows: [QuotaWindow]
    public var source: String
    public var updatedAt: Date

    public init(
        provider: String,
        name: String,
        kind: QuotaKind,
        plan: String? = nil,
        accountLabel: String? = nil,
        balanceText: String? = nil,
        usedUSD: Double? = nil,
        remainingUSD: Double? = nil,
        windows: [QuotaWindow] = [],
        source: String,
        updatedAt: Date = Date()
    ) {
        self.provider = provider
        self.name = name
        self.kind = kind
        self.plan = plan
        self.accountLabel = accountLabel
        self.balanceText = balanceText
        self.usedUSD = usedUSD
        self.remainingUSD = remainingUSD
        self.windows = windows
        self.source = source
        self.updatedAt = updatedAt
    }

    public var maxUsedPercent: Double {
        windows.map(\.usedPercent).max() ?? 0
    }
}

public enum BalanceVendor: String, Codable, CaseIterable, Sendable {
    case oneAPI = "oneapi"
    case newAPI = "newapi"
    case deepSeek = "deepseek"
    case openRouter = "openrouter"
    case moonshot = "moonshot"
    case siliconFlow = "siliconflow"
}

public struct BalanceAccountConfig: Codable, Sendable {
    public var vendor: BalanceVendor
    public var name: String
    public var baseURL: String?
    public var apiKey: String
    public var userId: Int?

    public init(vendor: BalanceVendor, name: String, baseURL: String? = nil, apiKey: String, userId: Int? = nil) {
        self.vendor = vendor
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.userId = userId
    }
}

public struct TokenMeterConfig: Codable, Sendable {
    public var dailyBudgetUSD: Double
    public var budgetAlertRatio: Double
    public var quotaAlertPercent: Double
    public var enableNotifications: Bool
    public var refreshIntervalSeconds: Int
    public var probeIntervalSeconds: Int
    public var gatewayQuotaURLs: [String]
    public var customEndpoints: [DiscoveredEndpoint]
    public var oneAPIAccounts: [OneAPIConfig]
    public var balanceAccounts: [BalanceAccountConfig]
    public var modelPriceOverrides: [String: ModelPrice]

    public init(
        dailyBudgetUSD: Double = 20.0,
        budgetAlertRatio: Double = 0.8,
        quotaAlertPercent: Double = 85.0,
        enableNotifications: Bool = true,
        refreshIntervalSeconds: Int = 30,
        probeIntervalSeconds: Int = 60,
        gatewayQuotaURLs: [String] = ["http://127.0.0.1:3425/v1/magpie/quotas"],
        customEndpoints: [DiscoveredEndpoint] = [],
        oneAPIAccounts: [OneAPIConfig] = [],
        balanceAccounts: [BalanceAccountConfig] = [],
        modelPriceOverrides: [String: ModelPrice] = [:]
    ) {
        self.dailyBudgetUSD = dailyBudgetUSD
        self.budgetAlertRatio = budgetAlertRatio
        self.quotaAlertPercent = quotaAlertPercent
        self.enableNotifications = enableNotifications
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.probeIntervalSeconds = probeIntervalSeconds
        self.gatewayQuotaURLs = gatewayQuotaURLs
        self.customEndpoints = customEndpoints
        self.oneAPIAccounts = oneAPIAccounts
        self.balanceAccounts = balanceAccounts
        self.modelPriceOverrides = modelPriceOverrides
    }

    enum CodingKeys: String, CodingKey {
        case dailyBudgetUSD, budgetAlertRatio, quotaAlertPercent, enableNotifications
        case refreshIntervalSeconds, probeIntervalSeconds
        case gatewayQuotaURLs, customEndpoints, oneAPIAccounts, balanceAccounts, modelPriceOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .dailyBudgetUSD) ?? 20.0
        budgetAlertRatio = try c.decodeIfPresent(Double.self, forKey: .budgetAlertRatio) ?? 0.8
        quotaAlertPercent = try c.decodeIfPresent(Double.self, forKey: .quotaAlertPercent) ?? 85.0
        enableNotifications = try c.decodeIfPresent(Bool.self, forKey: .enableNotifications) ?? true
        refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 30
        probeIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .probeIntervalSeconds) ?? 60
        gatewayQuotaURLs = try c.decodeIfPresent([String].self, forKey: .gatewayQuotaURLs) ?? ["http://127.0.0.1:3425/v1/magpie/quotas"]
        customEndpoints = try c.decodeIfPresent([DiscoveredEndpoint].self, forKey: .customEndpoints) ?? []
        oneAPIAccounts = try c.decodeIfPresent([OneAPIConfig].self, forKey: .oneAPIAccounts) ?? []
        balanceAccounts = try c.decodeIfPresent([BalanceAccountConfig].self, forKey: .balanceAccounts) ?? []
        modelPriceOverrides = try c.decodeIfPresent([String: ModelPrice].self, forKey: .modelPriceOverrides) ?? [:]
    }

    public static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tokenmeter", isDirectory: true)
    }

    public static var configFileURL: URL {
        configDirectoryURL.appendingPathComponent("config.json")
    }

    public static func load() -> TokenMeterConfig {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(TokenMeterConfig.self, from: data) else {
            return TokenMeterConfig()
        }
        return cfg
    }

    public func save() {
        let dir = Self.configDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.configFileURL, options: .atomic)
        }
    }
}

public struct ModelPrice: Codable, Sendable {
    /// Price in USD per 1,000,000 tokens
    public var inputPer1M: Double
    public var outputPer1M: Double
    public var cacheReadPer1M: Double
    public var cacheWritePer1M: Double

    public init(inputPer1M: Double, outputPer1M: Double, cacheReadPer1M: Double? = nil, cacheWritePer1M: Double? = nil) {
        self.inputPer1M = inputPer1M
        self.outputPer1M = outputPer1M
        self.cacheReadPer1M = cacheReadPer1M ?? (inputPer1M * 0.1)
        self.cacheWritePer1M = cacheWritePer1M ?? (inputPer1M * 1.25)
    }

    public func estimateCost(for usage: TokenUsage) -> Double {
        let m = 1_000_000.0
        return (Double(usage.inputTokens) / m) * inputPer1M
            + (Double(usage.outputTokens) / m) * outputPer1M
            + (Double(usage.cacheReadTokens) / m) * cacheReadPer1M
            + (Double(usage.cacheWriteTokens) / m) * cacheWritePer1M
    }
}
