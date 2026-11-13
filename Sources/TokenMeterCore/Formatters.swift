import Foundation

public enum Formatters {
    public static func tokens(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.2fB", Double(count) / 1_000_000_000.0)
        } else if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 10_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        } else if count >= 1_000 {
            return String(format: "%.2fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    public static func compactTokens(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000.0)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    public static func usd(_ amount: Double) -> String {
        if amount >= 100 {
            return String(format: "$%.0f", amount)
        } else if amount >= 10 {
            return String(format: "$%.1f", amount)
        } else if amount >= 0.01 || amount == 0 {
            return String(format: "$%.2f", amount)
        }
        return String(format: "$%.4f", amount)
    }

    public static func percent(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100.0)
    }

    public static func parseISO8601(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    public static func relativeTime(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "无记录" }
        let diff = max(0, Int(now.timeIntervalSince(date)))
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60)分钟前" }
        if diff < 86400 { return "\(diff / 3600)小时前" }
        return "\(diff / 86400)天前"
    }
}
