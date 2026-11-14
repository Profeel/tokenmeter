import Foundation
import TokenMeterCore

@main
struct TokenMeterCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let cmd = filtered.first ?? "status"

        let engine = TokenMeterEngine()
        let config = TokenMeterConfig.load()

        switch cmd {
        case "help", "-h", "--help":
            printHelp()

        case "status", "today":
            await renderSnapshot(engine: engine, window: .today, config: config, jsonMode: jsonMode, includeProbe: cmd == "status")

        case "week", "7d":
            await renderSnapshot(engine: engine, window: .week, config: config, jsonMode: jsonMode, includeProbe: false)

        case "month", "30d":
            await renderSnapshot(engine: engine, window: .month, config: config, jsonMode: jsonMode, includeProbe: false)

        case "all":
            await renderSnapshot(engine: engine, window: .all, config: config, jsonMode: jsonMode, includeProbe: false)

        case "models":
            let winArg = filtered.dropFirst().first ?? "7d"
            let win = TimeWindow(rawValue: winArg) ?? .week
            let snap = engine.buildSnapshot(window: win, config: config)
            if jsonMode {
                printJSON(snap.modelBreakdowns)
            } else {
                print("\n📊 TokenMeter Top Models (\(win.label))")
                print(String(repeating: "─", count: 68))
                for m in snap.modelBreakdowns.prefix(20) {
                    let line = String(
                        format: "  %-28s %-10s %9s  %8s  %s",
                        (m.model as NSString).utf8String!,
                        (m.agent.displayName as NSString).utf8String!,
                        (Formatters.tokens(m.usage.totalTokens) as NSString).utf8String!,
                        (Formatters.usd(m.estimatedCostUSD) as NSString).utf8String!,
                        ("cache \(Formatters.percent(m.usage.cacheHitRate))" as NSString).utf8String!
                    )
                    print(line)
                }
                print("")
            }

        case "probe":
            let endpoints = EndpointDiscovery().discover(config: config)
            let results = await EndpointProber().probeAll(endpoints: endpoints, config: config)
            if jsonMode {
                printJSON(results)
            } else {
                print("\n🔌 TokenMeter Upstream Probe (\(results.count) endpoints)")
                print(String(repeating: "─", count: 72))
                for r in results {
                    let icon = statusIcon(r.status)
                    let codeStr = r.httpStatusCode.map { "HTTP \($0)" } ?? "ERR"
                    let msStr = String(format: "%5.0fms", r.latencyMs)
                    let extra: String
                    if let rem = r.quotaRemainingUSD {
                        extra = "余 \(Formatters.usd(rem))"
                    } else if let mc = r.modelCount {
                        extra = "\(mc) models"
                    } else {
                        extra = r.status.label
                    }
                    print("  \(icon) \(r.endpoint.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(codeStr.padding(toLength: 9, withPad: " ", startingAt: 0)) \(msStr)  \(extra)  [\(r.endpoint.baseURL)]")
                }
                print("")
            }

        case "quotas", "quota", "balance", "balances":
            let quotas = await QuotaTracker().fetchAll(config: config)
            if jsonMode {
                printJSON(quotas)
            } else {
                printQuotas(quotas)
            }

        case "init-config":
            if !FileManager.default.fileExists(atPath: TokenMeterConfig.configFileURL.path) {
                var sample = config
                if sample.balanceAccounts.isEmpty {
                    sample.balanceAccounts = [
                        BalanceAccountConfig(vendor: .deepSeek, name: "DeepSeek", apiKey: "sk-your-deepseek-key"),
                        BalanceAccountConfig(vendor: .oneAPI, name: "OneAPI 主站", baseURL: "https://your-oneapi.example.com", apiKey: "your-system-token", userId: 1)
                    ]
                }
                sample.save()
                print("✓ 已生成示例配置: \(TokenMeterConfig.configFileURL.path)")
            } else {
                print("配置文件已存在: \(TokenMeterConfig.configFileURL.path)")
            }

        case "watch":
            print("按 Ctrl+C 退出实时监控 (每 10 秒刷新)...")
            while true {
                print("\u{001B}[2J\u{001B}[H", terminator: "")
                await renderSnapshot(engine: engine, window: .today, config: config, jsonMode: false, includeProbe: true)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }

        default:
            fputs("未知命令: \(cmd)\n", stderr)
            printHelp()
            exit(1)
        }
    }

    static func renderSnapshot(
        engine: TokenMeterEngine,
        window: TimeWindow,
        config: TokenMeterConfig,
        jsonMode: Bool,
        includeProbe: Bool
    ) async {
        let snap = engine.buildSnapshot(window: window, config: config)
        var probes: [EndpointProbeResult] = []
        var quotas: [SubscriptionQuota] = []
        if includeProbe {
            async let pTask = EndpointProber().probeAll(endpoints: EndpointDiscovery().discover(config: config), config: config)
            async let qTask = QuotaTracker().fetchAll(config: config)
            probes = await pTask
            quotas = await qTask
        }

        if jsonMode {
            struct CombinedReport: Codable {
                let snapshot: MeterSnapshot
                let quotas: [SubscriptionQuota]
                let endpoints: [EndpointProbeResult]
            }
            printJSON(CombinedReport(snapshot: snap, quotas: quotas, endpoints: probes))
            return
        }

        print("\n⚡ TokenMeter — 跨 Agent 消耗与端点健康看板 (\(window.label))")
        print(String(repeating: "═", count: 72))
        print("  总 Tokens:  \(Formatters.tokens(snap.totalUsage.totalTokens))  (输入 \(Formatters.tokens(snap.totalUsage.inputTokens)) · 输出 \(Formatters.tokens(snap.totalUsage.outputTokens)) · 缓存命中 \(Formatters.tokens(snap.totalUsage.cacheReadTokens)) [\(Formatters.percent(snap.totalUsage.cacheHitRate))])")
        print("  估算费用:   \(Formatters.usd(snap.totalEstimatedCostUSD))\(window == .today ? "  / 日预算 \(Formatters.usd(snap.dailyBudgetUSD)) (\(Formatters.percent(snap.budgetUsageRatio)))" : "")")
        print("")

        if snap.agentBreakdowns.isEmpty {
            print("  (当前窗口内暂无本地 Agent 会话消耗记录)")
        } else {
            print("  [Agent 维度]")
            for a in snap.agentBreakdowns {
                let name = a.agent.displayName.padding(toLength: 13, withPad: " ", startingAt: 0)
                let tok = Formatters.tokens(a.usage.totalTokens).padding(toLength: 10, withPad: " ", startingAt: 0)
                let cost = Formatters.usd(a.estimatedCostUSD).padding(toLength: 8, withPad: " ", startingAt: 0)
                let top = (a.topModel ?? "-").padding(toLength: 22, withPad: " ", startingAt: 0)
                print("    • \(name) \(tok) \(cost)  \(a.sessionCount) 会话  主力: \(top)  (\(Formatters.relativeTime(a.lastActiveAt)))")
            }
        }

        if !snap.modelBreakdowns.isEmpty {
            print("\n  [Top 模型]")
            for m in snap.modelBreakdowns.prefix(6) {
                let mName = m.model.padding(toLength: 28, withPad: " ", startingAt: 0)
                let tok = Formatters.tokens(m.usage.totalTokens).padding(toLength: 10, withPad: " ", startingAt: 0)
                let cost = Formatters.usd(m.estimatedCostUSD).padding(toLength: 8, withPad: " ", startingAt: 0)
                print("    • \(mName) \(tok) \(cost)  [\(m.agent.displayName)]")
            }
        }

        if !quotas.isEmpty {
            printQuotas(quotas, embedded: true)
        }

        if !probes.isEmpty {
            print("\n  [上游端点探针]")
            for p in probes {
                let icon = statusIcon(p.status)
                let name = p.endpoint.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                let ms = String(format: "%4.0fms", p.latencyMs)
                let note = p.quotaRemainingUSD.map { "余 \(Formatters.usd($0))" }
                    ?? p.modelCount.map { "\($0) models" }
                    ?? p.status.label
                print("    \(icon) \(name) \(ms)  \(note)  (\(p.endpoint.baseURL))")
            }
        }
        print("")
    }

    static func printQuotas(_ quotas: [SubscriptionQuota], embedded: Bool = false) {
        if !embedded {
            print("\n💳 TokenMeter 订阅用量与账户余额 (\(quotas.count))")
            print(String(repeating: "═", count: 72))
        } else {
            print("\n  [订阅用量与账户余额]")
        }
        if quotas.isEmpty {
            print("  (未检测到订阅或余额配置，可运行 `tokenmeter init-config` 添加 API 余额查询)")
        } else {
            for q in quotas {
                let planPart = q.plan.map { " [\($0)]" } ?? ""
                let acctPart = q.accountLabel.map { " (\($0))" } ?? ""
                let balPart = q.balanceText.map { "  💰 \($0)" } ?? ""
                print("    ▸ \(q.name)\(planPart)\(acctPart)\(balPart)")
                for w in q.windows {
                    let bar = progressBar(percent: w.usedPercent, width: 16)
                    let pctStr = String(format: "已用%5.1f%% (剩%5.1f%%)", w.usedPercent, w.remainingPercent)
                    let disp = w.display.map { " [\($0)]" } ?? ""
                    let rst = w.resetsAt.map { " · \(Formatters.resetCountdown($0))" } ?? ""
                    print("        \(w.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(bar) \(pctStr)\(disp)\(rst)")
                }
            }
        }
        if !embedded { print("") }
    }

    static func progressBar(percent: Double, width: Int) -> String {
        let clamped = min(100, max(0, percent))
        let filled = Int((clamped / 100.0 * Double(width)).rounded())
        let empty = max(0, width - filled)
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    static func statusIcon(_ s: EndpointStatus) -> String {
        switch s {
        case .healthy: return "🟢"
        case .authRequired: return "🔵"
        case .rateLimited: return "🟡"
        case .degraded: return "🟠"
        case .down: return "🔴"
        }
    }

    static func printJSON<T: Encodable>(_ val: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(val), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    static func printHelp() {
        print("""
        TokenMeter — 跨 AI Coding Agent 本地消耗与上游端点健康监控

        用法:
          tokenmeter status [--json]      查看今日消耗 + 订阅余额 + 上游端点探针 (默认)
          tokenmeter quotas [--json]      查看各订阅用量比例、重置倒计时与 API 余额
          tokenmeter today  [--json]      仅看今日消耗汇总
          tokenmeter week   [--json]      最近 7 天消耗汇总
          tokenmeter month  [--json]      最近 30 天消耗汇总
          tokenmeter all    [--json]      全部历史消耗汇总
          tokenmeter models [today|7d|30d|all] [--json]
          tokenmeter probe  [--json]      探测全部已发现端点的连通性、延迟与 429 状态
          tokenmeter watch                每 10 秒自动刷新终端实时看板
          tokenmeter init-config          生成 ~/.tokenmeter/config.json 配置文件
        """)
    }
}
