import Foundation

public struct QuotaTracker: Sendable {
    public init() {}

    public func fetchAll(config: TokenMeterConfig = .load()) async -> [SubscriptionQuota] {
        await withTaskGroup(of: [SubscriptionQuota].self) { group in
            for urlStr in config.gatewayQuotaURLs {
                group.addTask {
                    await self.fetchGatewayQuotas(urlString: urlStr)
                }
            }

            // Legacy oneAPIAccounts
            for one in config.oneAPIAccounts {
                let acct = BalanceAccountConfig(
                    vendor: .oneAPI,
                    name: one.name,
                    baseURL: one.baseURL,
                    apiKey: one.accessToken,
                    userId: one.userId
                )
                group.addTask {
                    if let q = await self.fetchBalanceAccount(acct) {
                        return [q]
                    }
                    return []
                }
            }

            // Configured direct vendor balance accounts
            for acct in config.balanceAccounts {
                group.addTask {
                    if let q = await self.fetchBalanceAccount(acct) {
                        return [q]
                    }
                    return []
                }
            }

            var results: [SubscriptionQuota] = []
            for await batch in group {
                results.append(contentsOf: batch)
            }

            // Fallback: direct Codex session rate_limits if no Codex subscription was reported by gateway
            if !results.contains(where: { $0.provider.lowercased() == "codex" }) {
                if let directCodex = readDirectCodexRateLimit() {
                    results.append(directCodex)
                }
            }

            return results.sorted { a, b in
                if a.kind != b.kind {
                    return kindOrder(a.kind) < kindOrder(b.kind)
                }
                return a.maxUsedPercent > b.maxUsedPercent
            }
        }
    }

    // MARK: - Gateway Quotas (e.g. Magpie /v1/magpie/quotas)

    public func fetchGatewayQuotas(urlString: String) async -> [SubscriptionQuota] {
        guard let url = URL(string: urlString) else { return [] }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3.5)
        req.httpMethod = "GET"

        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.timeoutIntervalForRequest = 3.5
        sessionCfg.timeoutIntervalForResource = 4.0
        let session = URLSession(configuration: sessionCfg)

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }

        return parseGatewayQuotasJSON(data: data, source: "gateway")
    }

    public func parseGatewayQuotasJSON(data: Data, source: String = "gateway") -> [SubscriptionQuota] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            return []
        }

        var items: [SubscriptionQuota] = []
        for entry in list {
            let provider = (entry["provider"] as? String) ?? "unknown"
            let name = (entry["name"] as? String) ?? provider
            let plan = entry["plan"] as? String
            let user = entry["user"] as? String
            let balanceText = entry["balance"] as? String
            let updatedAt = Formatters.parseISO8601(entry["readAt"] as? String) ?? Date()

            let rawWindows = (entry["windows"] as? [[String: Any]]) ?? []
            var parsedWindows: [QuotaWindow] = []
            for w in rawWindows {
                guard let wName = w["name"] as? String else { continue }
                let used = (w["used"] as? NSNumber)?.doubleValue ?? 0
                let remaining = (w["remaining"] as? NSNumber)?.doubleValue
                let resetsAt = Formatters.parseISO8601(w["resetsAt"] as? String)
                let display = w["display"] as? String
                let unit = w["unit"] as? String
                parsedWindows.append(QuotaWindow(
                    name: wName,
                    usedPercent: used,
                    remainingPercent: remaining,
                    resetsAt: resetsAt,
                    display: display,
                    unit: unit
                ))
            }

            // Summarize very verbose window lists (e.g., per-thinking-tier rows)
            let finalWindows: [QuotaWindow]
            if parsedWindows.count > 5 {
                let summaries = parsedWindows.filter {
                    $0.name.contains("·") || $0.name.contains("hours") || $0.name.contains("days") || $0.name.contains("Total")
                }
                finalWindows = summaries.isEmpty ? Array(parsedWindows.prefix(5)) : summaries
            } else {
                finalWindows = parsedWindows
            }

            items.append(SubscriptionQuota(
                provider: provider,
                name: name,
                kind: .subscription,
                plan: plan,
                accountLabel: user,
                balanceText: balanceText,
                usedUSD: nil,
                remainingUSD: nil,
                windows: finalWindows,
                source: source,
                updatedAt: updatedAt
            ))
        }
        return items
    }

    // MARK: - Direct Vendor Balance APIs

    public func fetchBalanceAccount(_ account: BalanceAccountConfig) async -> SubscriptionQuota? {
        switch account.vendor {
        case .oneAPI, .newAPI:
            return await fetchOneAPIBalance(account)
        case .deepSeek:
            return await fetchDeepSeekBalance(account)
        case .openRouter:
            return await fetchOpenRouterBalance(account)
        case .moonshot:
            return await fetchMoonshotBalance(account)
        case .siliconFlow:
            return await fetchSiliconFlowBalance(account)
        }
    }

    private func fetchOneAPIBalance(_ account: BalanceAccountConfig) async -> SubscriptionQuota? {
        guard var base = account.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else {
            return nil
        }
        if base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/api/user/self") else { return nil }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4.0)
        req.httpMethod = "GET"
        req.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "Authorization")
        if let uid = account.userId {
            req.setValue("\(uid)", forHTTPHeaderField: "New-Api-User")
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let u = obj["data"] as? [String: Any] else {
            return nil
        }

        let remQuota = ((u["quota"] as? NSNumber)?.doubleValue ?? 0) / 500_000.0
        let usedQuota = ((u["used_quota"] as? NSNumber)?.doubleValue ?? 0) / 500_000.0
        let total = remQuota + usedQuota
        let usedPct = total > 0 ? (usedQuota / total) * 100.0 : 0
        let username = u["username"] as? String

        return SubscriptionQuota(
            provider: account.vendor.rawValue,
            name: account.name,
            kind: .apiBalance,
            plan: (u["group"] as? String) ?? "OneAPI",
            accountLabel: username,
            balanceText: "余 \(Formatters.usd(remQuota))",
            usedUSD: usedQuota,
            remainingUSD: remQuota,
            windows: [
                QuotaWindow(
                    name: "额度用量",
                    usedPercent: usedPct,
                    remainingPercent: 100.0 - usedPct,
                    display: "\(Formatters.usd(usedQuota)) / \(Formatters.usd(total))"
                )
            ],
            source: "direct-api"
        )
    }

    private func fetchDeepSeekBalance(_ account: BalanceAccountConfig) async -> SubscriptionQuota? {
        let base = (account.baseURL?.isEmpty == false ? account.baseURL! : "https://api.deepseek.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/user/balance") else { return nil }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4.0)
        req.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = obj["balance_infos"] as? [[String: Any]],
              let first = infos.first else {
            return nil
        }

        let currency = (first["currency"] as? String) ?? "CNY"
        let totalStr = (first["total_balance"] as? String) ?? "0"
        let totalVal = Double(totalStr) ?? 0
        let symbol = currency == "USD" ? "$" : "¥"

        return SubscriptionQuota(
            provider: "deepseek",
            name: account.name,
            kind: .apiBalance,
            plan: "API Balance",
            balanceText: String(format: "%@%.2f", symbol, totalVal),
            remainingUSD: currency == "USD" ? totalVal : nil,
            windows: [],
            source: "direct-api"
        )
    }

    private func fetchOpenRouterBalance(_ account: BalanceAccountConfig) async -> SubscriptionQuota? {
        guard let url = URL(string: "https://openrouter.ai/api/v1/key") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4.0)
        req.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            return nil
        }

        let usage = (d["usage"] as? NSNumber)?.doubleValue ?? 0
        let limit = (d["limit"] as? NSNumber)?.doubleValue
        let remaining = (d["limit_remaining"] as? NSNumber)?.doubleValue
        let label = d["label"] as? String

        var windows: [QuotaWindow] = []
        if let limit, limit > 0 {
            let pct = (usage / limit) * 100.0
            windows.append(QuotaWindow(
                name: "Key Limit",
                usedPercent: pct,
                display: "\(Formatters.usd(usage)) / \(Formatters.usd(limit))"
            ))
        }

        let balText = remaining.map { "余 \(Formatters.usd($0))" } ?? "已用 \(Formatters.usd(usage))"
        return SubscriptionQuota(
            provider: "openrouter",
            name: account.name,
            kind: .apiBalance,
            plan: "OpenRouter",
            accountLabel: label,
            balanceText: balText,
            usedUSD: usage,
            remainingUSD: remaining,
            windows: windows,
            source: "direct-api"
        )
    }

    private func fetchMoonshotBalance(_ account: BalanceAccountConfig) async -> SubscriptionQuota? {
        let base = (account.baseURL?.isEmpty == false ? account.baseURL! : "https://api.moonshot.cn/v1")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/users/me/balance") else { return nil }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4.0)
        req.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let avail = (d["available_balance"] as? NSNumber)?.doubleValue else {
            return nil
        }

        return SubscriptionQuota(
            provider: "moonshot",
            name: account.name,
            kind: .apiBalance,
            plan: "API Balance",
            balanceText: String(format: "¥%.2f", avail),
            windows: [],
            source: "direct-api"
        )
    }

    private func fetchSiliconFlowBalance(_ account: BalanceAccountConfig) async -> SubscriptionQuota? {
        let base = (account.baseURL?.isEmpty == false ? account.baseURL! : "https://api.siliconflow.cn/v1")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/user/info") else { return nil }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4.0)
        req.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            return nil
        }

        let balStr = (d["totalBalance"] as? String) ?? (d["balance"] as? String) ?? "0"
        let val = Double(balStr) ?? 0
        return SubscriptionQuota(
            provider: "siliconflow",
            name: account.name,
            kind: .apiBalance,
            plan: "API Balance",
            accountLabel: d["email"] as? String,
            balanceText: String(format: "¥%.2f", val),
            windows: [],
            source: "direct-api"
        )
    }

    // MARK: - Direct Codex Session Rate Limits Fallback

    private func readDirectCodexRateLimit() -> SubscriptionQuota? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(
                  at: dir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, mtime))
        }
        files.sort { $0.mtime > $1.mtime }

        for item in files.prefix(8) {
            guard let data = try? Data(contentsOf: item.url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var found: SubscriptionQuota?
            text.enumerateLines { line, _ in
                guard line.contains("\"rate_limits\""),
                      let ld = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else { return }
                var windows: [QuotaWindow] = []
                for (key, label) in [("primary", "5 hours"), ("secondary", "7 days")] {
                    if let w = rl[key] as? [String: Any],
                       let used = (w["used_percent"] as? NSNumber)?.doubleValue {
                        let resetsAt = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                        windows.append(QuotaWindow(name: label, usedPercent: used, resetsAt: resetsAt))
                    }
                }
                if !windows.isEmpty {
                    found = SubscriptionQuota(
                        provider: "codex",
                        name: "Codex",
                        kind: .rateLimit,
                        plan: rl["plan_type"] as? String,
                        windows: windows,
                        source: "codex-session"
                    )
                }
            }
            if let found { return found }
        }
        return nil
    }

    private func kindOrder(_ k: QuotaKind) -> Int {
        switch k {
        case .subscription: return 0
        case .apiBalance: return 1
        case .rateLimit: return 2
        }
    }
}
