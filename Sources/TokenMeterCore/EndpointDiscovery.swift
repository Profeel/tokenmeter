import Foundation

public struct EndpointDiscovery: Sendable {
    public init() {}

    public func discover(config: TokenMeterConfig = .load()) -> [DiscoveredEndpoint] {
        var found: [DiscoveredEndpoint] = []
        var seenKeys = Set<String>()

        func appendUnique(_ ep: DiscoveredEndpoint) {
            let normalized = normalizeURL(ep.baseURL)
            guard !normalized.isEmpty else { return }
            // Skip internal non-LLM endpoints (MCP / CDP / telemetry / docs / local app backends)
            let lower = normalized.lowercased()
            if lower.contains("localhost:9222") || lower.contains("127.0.0.1:9222")
                || lower.contains("localhost:3000") || lower.contains("127.0.0.1:3000")
                || lower.contains("/mcp") || lower.contains("model-catalog.json")
                || lower.contains("portal.nousresearch.com") {
                return
            }
            // Collapse bare local gateway if /v1 is already tracked
            let canonical = lower.hasSuffix("/v1") ? normalized : (normalized == "http://127.0.0.1:3425" ? "http://127.0.0.1:3425/v1" : normalized)
            let dedupKey = "\(ep.kind.rawValue)::\(canonical)"
            if seenKeys.contains(dedupKey) { return }
            seenKeys.insert(dedupKey)
            var copy = ep
            copy.baseURL = canonical
            found.append(copy)
        }

        // 1. User custom endpoints & OneAPI accounts
        for custom in config.customEndpoints {
            appendUnique(custom)
        }
        for oneapi in config.oneAPIAccounts {
            appendUnique(DiscoveredEndpoint(
                name: oneapi.name,
                baseURL: oneapi.baseURL,
                source: "tokenmeter",
                kind: .oneAPI
            ))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser

        // 2. Hermes (~/.hermes/config.yaml) — URLs only, never touch secrets
        let hermesConfig = home.appendingPathComponent(".hermes/config.yaml")
        for url in extractBaseURLs(fromTextFile: hermesConfig) {
            appendUnique(DiscoveredEndpoint(
                name: friendlyName(for: url),
                baseURL: url,
                source: "hermes",
                kind: inferKind(url)
            ))
        }

        // 3. Codex (~/.codex/config.toml)
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        for url in extractBaseURLs(fromTextFile: codexConfig) {
            appendUnique(DiscoveredEndpoint(
                name: friendlyName(for: url),
                baseURL: url,
                source: "codex",
                kind: inferKind(url)
            ))
        }

        // 4. Pi (~/.pi/agent/models.json)
        let piModels = home.appendingPathComponent(".pi/agent/models.json")
        if let data = try? Data(contentsOf: piModels),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providers = obj["providers"] as? [String: Any] {
            for (name, val) in providers {
                if let pObj = val as? [String: Any],
                   let baseUrl = pObj["baseUrl"] as? String, !baseUrl.isEmpty {
                    appendUnique(DiscoveredEndpoint(
                        name: name,
                        baseURL: baseUrl,
                        source: "pi",
                        kind: inferKind(baseUrl)
                    ))
                }
            }
        }

        // 5. ZCode (~/.zcode/v2/config.json)
        let zcodeConfig = home.appendingPathComponent(".zcode/v2/config.json")
        for url in extractBaseURLs(fromTextFile: zcodeConfig) {
            appendUnique(DiscoveredEndpoint(
                name: friendlyName(for: url),
                baseURL: url,
                source: "zcode",
                kind: inferKind(url)
            ))
        }

        // 6. Standard local Ollama probe candidate if nothing on 11434 yet
        appendUnique(DiscoveredEndpoint(
            name: "Ollama (Local)",
            baseURL: "http://127.0.0.1:11434",
            source: "default-local",
            kind: .ollama
        ))

        return found
    }

    private func extractBaseURLs(fromTextFile url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let pattern = #"https?://[A-Za-z0-9\.\-:_/]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var urls: [String] = []
        text.enumerateLines { line, _ in
            let lower = line.lowercased()
            guard lower.contains("base_url") || lower.contains("baseurl") || lower.contains("endpoint") else {
                return
            }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                if let r = Range(match.range, in: line) {
                    urls.append(String(line[r]))
                }
            }
        }
        return urls
    }

    private func normalizeURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        // Collapse accidental /v1/v1 suffix
        if trimmed.hasSuffix("/v1/v1") {
            trimmed = String(trimmed.dropLast(3))
        }
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme,
              (scheme == "http" || scheme == "https"),
              parsed.host != nil else {
            return ""
        }
        return trimmed
    }

    private func inferKind(_ url: String) -> DiscoveredEndpoint.EndpointKind {
        let lower = url.lowercased()
        if lower.contains("11434") || lower.contains("ollama") { return .ollama }
        if lower.contains("anthropic") { return .anthropic }
        return .openAI
    }

    private func friendlyName(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        if host == "127.0.0.1" || host == "localhost" {
            let port = url.port.map { ":\($0)" } ?? ""
            if url.port == 3425 { return "Local Gateway\(port)" }
            if url.port == 8000 { return "Local MTPLX\(port)" }
            if url.port == 11434 { return "Ollama\(port)" }
            return "Local\(port)"
        }
        return host
    }
}
