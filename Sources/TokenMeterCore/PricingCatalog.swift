import Foundation

public struct PricingCatalog: Sendable {
    public static let shared = PricingCatalog()

    private let builtInRules: [(pattern: String, price: ModelPrice)] = [
        // Specific model families first (before generic routing prefixes like "codex-")
        ("deepseek", ModelPrice(inputPer1M: 0.27, outputPer1M: 1.10, cacheReadPer1M: 0.07)),
        ("glm-5", ModelPrice(inputPer1M: 0.60, outputPer1M: 2.20, cacheReadPer1M: 0.12)),
        ("glm-4", ModelPrice(inputPer1M: 0.14, outputPer1M: 0.14, cacheReadPer1M: 0.03)),
        ("qwen", ModelPrice(inputPer1M: 0.40, outputPer1M: 1.60, cacheReadPer1M: 0.08)),
        ("minimax", ModelPrice(inputPer1M: 0.30, outputPer1M: 1.20, cacheReadPer1M: 0.03)),
        ("grok", ModelPrice(inputPer1M: 3.0, outputPer1M: 15.0, cacheReadPer1M: 0.75)),
        ("kimi", ModelPrice(inputPer1M: 0.60, outputPer1M: 2.50, cacheReadPer1M: 0.15)),

        // Anthropic Claude family
        ("claude-opus", ModelPrice(inputPer1M: 15.0, outputPer1M: 75.0, cacheReadPer1M: 1.5, cacheWritePer1M: 18.75)),
        ("claude-sonnet", ModelPrice(inputPer1M: 3.0, outputPer1M: 15.0, cacheReadPer1M: 0.3, cacheWritePer1M: 3.75)),
        ("claude-haiku", ModelPrice(inputPer1M: 0.8, outputPer1M: 4.0, cacheReadPer1M: 0.08, cacheWritePer1M: 1.0)),

        // OpenAI GPT / Codex family
        ("gpt-6", ModelPrice(inputPer1M: 2.5, outputPer1M: 15.0, cacheReadPer1M: 0.25)),
        ("gpt-5.4", ModelPrice(inputPer1M: 2.5, outputPer1M: 15.0, cacheReadPer1M: 0.25)),
        ("gpt-5", ModelPrice(inputPer1M: 1.25, outputPer1M: 10.0, cacheReadPer1M: 0.125)),
        ("gpt-4o-mini", ModelPrice(inputPer1M: 0.15, outputPer1M: 0.60, cacheReadPer1M: 0.075)),
        ("gpt-4o", ModelPrice(inputPer1M: 2.5, outputPer1M: 10.0, cacheReadPer1M: 1.25)),
        ("codex", ModelPrice(inputPer1M: 1.5, outputPer1M: 6.0, cacheReadPer1M: 0.15)),
        ("o3", ModelPrice(inputPer1M: 2.0, outputPer1M: 8.0, cacheReadPer1M: 0.5)),
        ("o4-mini", ModelPrice(inputPer1M: 1.1, outputPer1M: 4.4, cacheReadPer1M: 0.275)),

        // Google Gemini family
        ("gemini-4", ModelPrice(inputPer1M: 1.25, outputPer1M: 10.0, cacheReadPer1M: 0.125)),
        ("gemini-3", ModelPrice(inputPer1M: 0.50, outputPer1M: 3.0, cacheReadPer1M: 0.05)),
        ("gemini-2.5-pro", ModelPrice(inputPer1M: 1.25, outputPer1M: 10.0, cacheReadPer1M: 0.31)),
        ("gemini-2.5-flash", ModelPrice(inputPer1M: 0.15, outputPer1M: 0.60, cacheReadPer1M: 0.0375)),
        ("gemini", ModelPrice(inputPer1M: 0.50, outputPer1M: 2.50, cacheReadPer1M: 0.05))
    ]

    public func price(for model: String, overrides: [String: ModelPrice] = [:]) -> ModelPrice? {
        let normalized = normalizeModelName(model)
        if let exact = overrides[model] ?? overrides[normalized] {
            return exact
        }
        for (key, value) in overrides {
            if normalized.contains(key.lowercased()) {
                return value
            }
        }
        // Local models (ollama/mlx/gguf) are zero API cost
        if normalized.contains("ollama/") || normalized.contains("gguf") || normalized.contains("mlx") || normalized.contains("local/") {
            return ModelPrice(inputPer1M: 0, outputPer1M: 0, cacheReadPer1M: 0, cacheWritePer1M: 0)
        }
        for rule in builtInRules {
            if normalized.contains(rule.pattern) {
                return rule.price
            }
        }
        return nil
    }

    public func estimateCostUSD(model: String, usage: TokenUsage, overrides: [String: ModelPrice] = [:]) -> (cost: Double, estimated: Bool) {
        if let actual = usage.reportedCostUSD, actual > 0 {
            return (actual, false)
        }
        guard let price = price(for: model, overrides: overrides) else {
            return (0.0, true)
        }
        return (price.estimateCost(for: usage), true)
    }

    public func normalizeModelName(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip common routing prefixes like "antigravity/", "group/", "magpie-air/", "zenmux/"
        if let lastSlash = lower.split(separator: "/").last {
            return String(lastSlash)
        }
        return lower
    }

    public func shortDisplayModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.split(separator: "/").last {
            return String(last)
        }
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
