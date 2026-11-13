import SwiftUI
import TokenMeterCore

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public var selectedWindow: TimeWindow = .today
    @Published public var snapshot: MeterSnapshot
    @Published public var probes: [EndpointProbeResult] = []
    @Published public var isRefreshingUsage: Bool = false
    @Published public var isProbing: Bool = false
    @Published public var selectedTab: Int = 0 // 0 = 概览, 1 = 模型, 2 = 端点

    public var onMenuTitleChange: ((String) -> Void)?

    private let engine = TokenMeterEngine()
    private let discovery = EndpointDiscovery()
    private let prober = EndpointProber()

    public init() {
        let cfg = TokenMeterConfig.load()
        self.snapshot = MeterSnapshot(
            window: .today,
            generatedAt: Date(),
            totalUsage: TokenUsage(),
            totalEstimatedCostUSD: 0,
            agentBreakdowns: [],
            modelBreakdowns: [],
            dailyBurn: [],
            dailyBudgetUSD: cfg.dailyBudgetUSD,
            budgetAlertRatio: cfg.budgetAlertRatio
        )
    }

    public func switchWindow(_ window: TimeWindow) {
        selectedWindow = window
        refreshUsage()
    }

    public func refreshAll() {
        refreshUsage()
        refreshProbes()
    }

    public func refreshUsage() {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        let window = selectedWindow
        let cfg = TokenMeterConfig.load()
        let eng = engine

        Task.detached(priority: .userInitiated) {
            let snap = eng.buildSnapshot(window: window, config: cfg)
            let todaySnap = window == .today ? snap : eng.buildSnapshot(window: .today, config: cfg)
            await MainActor.run {
                self.snapshot = snap
                self.isRefreshingUsage = false
                self.updateMenuTitle(todaySnap: todaySnap)
            }
        }
    }

    public func refreshProbes() {
        guard !isProbing else { return }
        isProbing = true
        let cfg = TokenMeterConfig.load()
        let eps = discovery.discover(config: cfg)
        let pr = prober

        Task.detached(priority: .utility) {
            let results = await pr.probeAll(endpoints: eps, config: cfg)
            await MainActor.run {
                self.probes = results
                self.isProbing = false
                self.updateMenuTitle(todaySnap: nil)
            }
        }
    }

    private func updateMenuTitle(todaySnap: MeterSnapshot?) {
        let baseSnap = todaySnap ?? snapshot
        let hasRateLimit = probes.contains { $0.status == .rateLimited }
        let overBudget = baseSnap.window == .today && baseSnap.budgetUsageRatio >= baseSnap.budgetAlertRatio && baseSnap.totalEstimatedCostUSD > 0
        let prefix = hasRateLimit ? "⚠️" : (overBudget ? "🔥" : "⚡")
        let tok = Formatters.compactTokens(baseSnap.totalUsage.totalTokens)
        let usd = Formatters.usd(baseSnap.totalEstimatedCostUSD)
        onMenuTitleChange?("\(prefix) \(tok) · \(usd)")
    }
}

public struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    var onQuit: () -> Void

    public var body: some View {
        VStack(spacing: 12) {
            headerView
            windowPicker
            heroCard
            tabSelector

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    if viewModel.selectedTab == 0 {
                        overviewSection
                    } else if viewModel.selectedTab == 1 {
                        modelsSection
                    } else {
                        endpointsSection
                    }
                }
                .padding(.vertical, 2)
            }

            footerView
        }
        .padding(14)
        .frame(width: 400, height: 560)
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text("TokenMeter")
                        .font(.system(size: 15, weight: .bold))
                    Text("跨 Agent 消耗 · 上游健康监测")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                viewModel.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isRefreshingUsage || viewModel.isProbing)
            .help("刷新日志与端点状态")
        }
    }

    private var windowPicker: some View {
        Picker("时间窗口", selection: Binding(
            get: { viewModel.selectedWindow },
            set: { viewModel.switchWindow($0) }
        )) {
            ForEach(TimeWindow.allCases) { win in
                Text(win.label).tag(win)
            }
        }
        .pickerStyle(.segmented)
    }

    private var heroCard: some View {
        let snap = viewModel.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(snap.window.label)估算费用")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(Formatters.usd(snap.totalEstimatedCostUSD))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("总 Tokens")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(Formatters.tokens(snap.totalUsage.totalTokens))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }

            HStack(spacing: 12) {
                statChip("输入", Formatters.tokens(snap.totalUsage.inputTokens), .blue)
                statChip("输出", Formatters.tokens(snap.totalUsage.outputTokens), .purple)
                statChip("缓存命中", "\(Formatters.tokens(snap.totalUsage.cacheReadTokens)) (\(Formatters.percent(snap.totalUsage.cacheHitRate)))", .green)
            }

            if snap.window == .today && snap.dailyBudgetUSD > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("日预算进度")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Formatters.usd(snap.totalEstimatedCostUSD)) / \(Formatters.usd(snap.dailyBudgetUSD))")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                    }
                    ProgressView(value: min(1.0, snap.budgetUsageRatio))
                        .tint(snap.budgetUsageRatio >= snap.budgetAlertRatio ? .orange : .green)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statChip(_ title: String, _ val: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
            Text(val)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabSelector: some View {
        Picker("视图", selection: $viewModel.selectedTab) {
            Text("Agent (\(viewModel.snapshot.agentBreakdowns.count))").tag(0)
            Text("模型 (\(viewModel.snapshot.modelBreakdowns.count))").tag(1)
            Text("端点 (\(viewModel.probes.count))").tag(2)
        }
        .pickerStyle(.segmented)
    }

    private var overviewSection: some View {
        VStack(spacing: 8) {
            if !viewModel.snapshot.dailyBurn.isEmpty && viewModel.selectedWindow != .today {
                dailyBarChart(viewModel.snapshot.dailyBurn.suffix(14))
            }

            if viewModel.snapshot.agentBreakdowns.isEmpty {
                emptyState("当前时间窗口内暂无本地 Agent 会话记录")
            } else {
                ForEach(viewModel.snapshot.agentBreakdowns) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.agent.symbolName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.orange)
                            .frame(width: 28, height: 28)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.agent.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text("\(item.sessionCount) 会话")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Text("主力: \(item.topModel ?? "-") · \(Formatters.relativeTime(item.lastActiveAt))")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatters.usd(item.estimatedCostUSD))
                                .font(.system(size: 13, weight: .bold))
                                .monospacedDigit()
                            Text(Formatters.tokens(item.usage.totalTokens))
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func dailyBarChart(_ points: ArraySlice<DailyBurnPoint>) -> some View {
        let maxTokens = max(1, points.map(\.totalTokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("每日消耗趋势")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(points)) { pt in
                    let h = max(4.0, (Double(pt.totalTokens) / Double(maxTokens)) * 42.0)
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(0.8))
                            .frame(height: h)
                        Text(String(pt.dayKey.suffix(2)))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(pt.dayKey): \(Formatters.tokens(pt.totalTokens)) (\(Formatters.usd(pt.estimatedCostUSD)))")
                }
            }
            .frame(height: 58)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var modelsSection: some View {
        VStack(spacing: 6) {
            if viewModel.snapshot.modelBreakdowns.isEmpty {
                emptyState("暂无模型消耗明细")
            } else {
                ForEach(viewModel.snapshot.modelBreakdowns.prefix(25)) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.model)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text("\(m.agent.displayName) · 缓存 \(Formatters.percent(m.usage.cacheHitRate))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatters.usd(m.estimatedCostUSD))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                            Text(Formatters.tokens(m.usage.totalTokens))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var endpointsSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("自动发现本机 Agent 上游与本地推理端点")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                Spacer()
                Button(viewModel.isProbing ? "探测中…" : "立即探测") {
                    viewModel.refreshProbes()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(viewModel.isProbing)
            }

            if viewModel.probes.isEmpty {
                emptyState(viewModel.isProbing ? "正在探测端点延迟..." : "尚未探测到端点")
            } else {
                ForEach(viewModel.probes) { p in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorForStatus(p.status))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.endpoint.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(p.endpoint.baseURL)
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            if let rem = p.quotaRemainingUSD {
                                Text("余 \(Formatters.usd(rem))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.green)
                            } else {
                                Text(p.status.label)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(colorForStatus(p.status))
                            }
                            Text(String(format: "%.0f ms", p.latencyMs))
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func colorForStatus(_ s: EndpointStatus) -> Color {
        switch s {
        case .healthy: return .green
        case .authRequired: return .blue
        case .rateLimited: return .yellow
        case .degraded: return .orange
        case .down: return .red
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var footerView: some View {
        HStack {
            Text("更新于 \(Formatters.relativeTime(viewModel.snapshot.generatedAt))")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Button("配置") {
                let cfg = TokenMeterConfig.load()
                if !FileManager.default.fileExists(atPath: TokenMeterConfig.configFileURL.path) {
                    cfg.save()
                }
                NSWorkspace.shared.open(TokenMeterConfig.configDirectoryURL)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            Text("·").foregroundColor(.secondary)

            Button("退出") {
                onQuit()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }
}
