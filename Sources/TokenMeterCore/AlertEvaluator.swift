import Foundation

public struct MeterAlert: Sendable, Equatable {
    public enum Severity: String, Sendable {
        case info
        case warning
        case critical
    }

    public var id: String
    public var title: String
    public var body: String
    public var severity: Severity

    public init(id: String, title: String, body: String, severity: Severity) {
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
    }
}

public final class AlertEvaluator: @unchecked Sendable {
    private var lastFiredAt: [String: Date] = [:]
    private var previousWindowUsage: [String: Double] = [:]
    private var previousEndpointStatus: [String: EndpointStatus] = [:]
    private var hasQuotaBaseline = false

    public init() {}

    public func evaluate(
        todaySnapshot: MeterSnapshot?,
        quotas: [SubscriptionQuota],
        probes: [EndpointProbeResult],
        config: TokenMeterConfig,
        now: Date = Date()
    ) -> [MeterAlert] {
        guard config.enableNotifications else { return [] }
        var alerts: [MeterAlert] = []

        // 1. Daily budget threshold alerts (once per day per tier)
        if let snap = todaySnapshot, snap.window == .today, snap.dailyBudgetUSD > 0 {
            let day = Formatters.dayKey(now)
            let ratio = snap.budgetUsageRatio
            if ratio >= 1.0 {
                let key = "budget-100-\(day)"
                if shouldFire(key: key, cooldown: 86_400, now: now) {
                    alerts.append(MeterAlert(
                        id: key,
                        title: "TokenMeter · 今日预算已超额",
                        body: "今日估算费用 \(Formatters.usd(snap.totalEstimatedCostUSD))，已超过日预算 \(Formatters.usd(snap.dailyBudgetUSD))。",
                        severity: .critical
                    ))
                }
            } else if ratio >= snap.budgetAlertRatio {
                let key = "budget-warn-\(day)"
                if shouldFire(key: key, cooldown: 86_400, now: now) {
                    alerts.append(MeterAlert(
                        id: key,
                        title: "TokenMeter · 日预算接近上限",
                        body: "今日已用 \(Formatters.usd(snap.totalEstimatedCostUSD)) / \(Formatters.usd(snap.dailyBudgetUSD)) (\(Formatters.percent(ratio)))。",
                        severity: .warning
                    ))
                }
            }
        }

        // 2. Subscription quota transitions (high usage / exhausted / reset recovery)
        let warnThreshold = config.quotaAlertPercent
        for q in quotas {
            let acctSuffix = q.accountLabel.map { " (\($0))" } ?? ""
            for w in q.windows {
                let winKey = "\(q.id)::\(w.name)"
                let prev = previousWindowUsage[winKey]
                previousWindowUsage[winKey] = w.usedPercent

                guard hasQuotaBaseline, let prev else { continue }

                if prev < 98.0 && w.usedPercent >= 98.0 {
                    let alertKey = "quota-exhausted-\(winKey)"
                    if shouldFire(key: alertKey, cooldown: 3600, now: now) {
                        let rst = w.resetsAt.map { " · \(Formatters.resetCountdown($0, now: now))" } ?? ""
                        alerts.append(MeterAlert(
                            id: alertKey,
                            title: "订阅额度已耗尽 · \(q.name)",
                            body: "\(w.name)\(acctSuffix) 已达 \(String(format: "%.0f%%", w.usedPercent))\(rst)",
                            severity: .critical
                        ))
                    }
                } else if prev < warnThreshold && w.usedPercent >= warnThreshold {
                    let alertKey = "quota-warn-\(winKey)"
                    if shouldFire(key: alertKey, cooldown: 3600, now: now) {
                        let rst = w.resetsAt.map { " · \(Formatters.resetCountdown($0, now: now))" } ?? ""
                        alerts.append(MeterAlert(
                            id: alertKey,
                            title: "订阅额度预警 · \(q.name)",
                            body: "\(w.name)\(acctSuffix) 已用 \(String(format: "%.0f%%", w.usedPercent))\(rst)",
                            severity: .warning
                        ))
                    }
                } else if prev >= 95.0 && w.usedPercent <= 15.0 {
                    let alertKey = "quota-reset-\(winKey)"
                    if shouldFire(key: alertKey, cooldown: 3600, now: now) {
                        alerts.append(MeterAlert(
                            id: alertKey,
                            title: "订阅额度已重置恢复 · \(q.name)",
                            body: "\(w.name)\(acctSuffix) 已重置，当前仅用 \(String(format: "%.0f%%", w.usedPercent))。",
                            severity: .info
                        ))
                    }
                }
            }
        }
        if !quotas.isEmpty {
            hasQuotaBaseline = true
        }

        // 3. Upstream endpoint 429 / recovery alerts
        for p in probes {
            let key = p.endpoint.id
            let prev = previousEndpointStatus[key]
            previousEndpointStatus[key] = p.status

            if p.status == .rateLimited && prev != .rateLimited {
                let alertKey = "probe-429-\(key)"
                if shouldFire(key: alertKey, cooldown: 900, now: now) {
                    alerts.append(MeterAlert(
                        id: alertKey,
                        title: "上游端点 429 限流 · \(p.endpoint.name)",
                        body: "\(p.endpoint.baseURL) 返回 HTTP 429，建议切换备用通道。",
                        severity: .warning
                    ))
                }
            } else if prev == .rateLimited && p.status == .healthy {
                let alertKey = "probe-recover-\(key)"
                if shouldFire(key: alertKey, cooldown: 900, now: now) {
                    alerts.append(MeterAlert(
                        id: alertKey,
                        title: "上游端点已恢复 · \(p.endpoint.name)",
                        body: "\(p.endpoint.baseURL) 现已恢复正常 (\(Int(p.latencyMs))ms)。",
                        severity: .info
                    ))
                }
            }
        }

        return alerts
    }

    private func shouldFire(key: String, cooldown: TimeInterval, now: Date) -> Bool {
        if let last = lastFiredAt[key], now.timeIntervalSince(last) < cooldown {
            return false
        }
        lastFiredAt[key] = now
        return true
    }
}
