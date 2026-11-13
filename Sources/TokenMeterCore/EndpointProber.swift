import Foundation

public struct EndpointProber: Sendable {
    public init() {}

    public func probeAll(endpoints: [DiscoveredEndpoint], config: TokenMeterConfig = .load()) async -> [EndpointProbeResult] {
        await withTaskGroup(of: EndpointProbeResult.self) { group in
            for ep in endpoints {
                group.addTask {
                    await probe(endpoint: ep, config: config)
                }
            }
            var results: [EndpointProbeResult] = []
            for await res in group {
                results.append(res)
            }
            return results.sorted { a, b in
                if a.status == b.status {
                    return a.latencyMs < b.latencyMs
                }
                return statusPriority(a.status) < statusPriority(b.status)
            }
        }
    }

    public func probe(endpoint: DiscoveredEndpoint, config: TokenMeterConfig) async -> EndpointProbeResult {
        if endpoint.kind == .oneAPI,
           let account = config.oneAPIAccounts.first(where: { $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == endpoint.baseURL }) {
            return await probeOneAPI(endpoint: endpoint, account: account)
        }

        let probeURLString: String
        switch endpoint.kind {
        case .ollama:
            probeURLString = "\(endpoint.baseURL)/api/tags"
        case .anthropic:
            probeURLString = "\(endpoint.baseURL)/v1/models"
        case .openAI, .oneAPI:
            if endpoint.baseURL.hasSuffix("/v1") || endpoint.baseURL.hasSuffix("/v3") {
                probeURLString = "\(endpoint.baseURL)/models"
            } else {
                probeURLString = "\(endpoint.baseURL)/v1/models"
            }
        }

        guard let url = URL(string: probeURLString) else {
            return EndpointProbeResult(
                endpoint: endpoint,
                status: .down,
                httpStatusCode: nil,
                latencyMs: 0,
                modelCount: nil,
                quotaRemainingUSD: nil,
                quotaUsedUSD: nil,
                errorMessage: "Invalid URL",
                checkedAt: Date()
            )
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3.5)
        req.httpMethod = "GET"

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 3.5
        sessionConfig.timeoutIntervalForResource = 4.0
        let session = URLSession(configuration: sessionConfig)

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let (data, response) = try await session.data(for: req)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0

            let modelCount = parseModelCount(data: data, kind: endpoint.kind)
            let status: EndpointStatus
            if code == 429 {
                status = .rateLimited
            } else if code == 401 || code == 403 {
                status = .authRequired
            } else if (200..<400).contains(code) {
                status = .healthy
            } else if code == 404 || code == 405 {
                // Server responded quickly at HTTP layer even if /models is not exposed
                status = .authRequired
            } else {
                status = .degraded
            }

            return EndpointProbeResult(
                endpoint: endpoint,
                status: status,
                httpStatusCode: code,
                latencyMs: elapsedMs,
                modelCount: modelCount,
                quotaRemainingUSD: nil,
                quotaUsedUSD: nil,
                errorMessage: nil,
                checkedAt: Date()
            )
        } catch {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            return EndpointProbeResult(
                endpoint: endpoint,
                status: .down,
                httpStatusCode: nil,
                latencyMs: elapsedMs,
                modelCount: nil,
                quotaRemainingUSD: nil,
                quotaUsedUSD: nil,
                errorMessage: error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    private func probeOneAPI(endpoint: DiscoveredEndpoint, account: OneAPIConfig) async -> EndpointProbeResult {
        var base = account.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
        while base.hasSuffix("/") { base.removeLast() }

        guard let url = URL(string: "\(base)/api/user/self") else {
            return EndpointProbeResult(
                endpoint: endpoint,
                status: .down,
                httpStatusCode: nil,
                latencyMs: 0,
                modelCount: nil,
                quotaRemainingUSD: nil,
                quotaUsedUSD: nil,
                errorMessage: "Invalid OneAPI URL",
                checkedAt: Date()
            )
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4.0)
        req.httpMethod = "GET"
        req.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        if let uid = account.userId {
            req.setValue("\(uid)", forHTTPHeaderField: "New-Api-User")
        }

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            var remainingUSD: Double? = nil
            var usedUSD: Double? = nil
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let userData = obj["data"] as? [String: Any] {
                if let quota = (userData["quota"] as? NSNumber)?.doubleValue {
                    remainingUSD = quota / 500_000.0
                }
                if let used = (userData["used_quota"] as? NSNumber)?.doubleValue {
                    usedUSD = used / 500_000.0
                }
            }

            let status: EndpointStatus = code == 429 ? .rateLimited : ((200..<300).contains(code) ? .healthy : (code == 401 ? .authRequired : .degraded))
            return EndpointProbeResult(
                endpoint: endpoint,
                status: status,
                httpStatusCode: code,
                latencyMs: elapsedMs,
                modelCount: nil,
                quotaRemainingUSD: remainingUSD,
                quotaUsedUSD: usedUSD,
                errorMessage: nil,
                checkedAt: Date()
            )
        } catch {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            return EndpointProbeResult(
                endpoint: endpoint,
                status: .down,
                httpStatusCode: nil,
                latencyMs: elapsedMs,
                modelCount: nil,
                quotaRemainingUSD: nil,
                quotaUsedUSD: nil,
                errorMessage: error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    private func parseModelCount(data: Data, kind: DiscoveredEndpoint.EndpointKind) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if kind == .ollama, let models = obj["models"] as? [Any] {
            return models.count
        }
        if let list = obj["data"] as? [Any] {
            return list.count
        }
        if let models = obj["models"] as? [Any] {
            return models.count
        }
        return nil
    }

    private func statusPriority(_ s: EndpointStatus) -> Int {
        switch s {
        case .rateLimited: return 0
        case .healthy: return 1
        case .authRequired: return 2
        case .degraded: return 3
        case .down: return 4
        }
    }
}
