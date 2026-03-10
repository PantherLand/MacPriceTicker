import Foundation

struct MarketSnapshot: Codable, Equatable {
    var btcUsd: Double?
    var ethUsd: Double?
    var btcTurnover24h: Double?
    var ethTurnover24h: Double?
    var xauUsd: Double?
    var xagUsd: Double?
    var oilUsd: Double?
    var nvdaUsd: Double?
    var updatedAt: Date

    static let loading = MarketSnapshot(
        btcUsd: nil,
        ethUsd: nil,
        btcTurnover24h: nil,
        ethTurnover24h: nil,
        xauUsd: nil,
        xagUsd: nil,
        oilUsd: nil,
        nvdaUsd: nil,
        updatedAt: .now
    )
}

enum MarketText {
    static func priceLine(_ name: String, _ value: Double?) -> String {
        guard let value else { return "\(name): loading..." }
        return "\(name): \(formatPrice(value))"
    }

    static func turnoverLine(_ name: String, _ value: Double?) -> String {
        guard let value else { return "\(name) 24h Turnover: loading..." }
        return String(format: "\(name) 24h Turnover: %.2f%%", value * 100)
    }

    static func updatedLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "Updated: \(formatter.string(from: date))"
    }

    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func headerTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    static func priceValue(_ value: Double?) -> String {
        guard let value else { return "loading..." }
        return formatPrice(value)
    }

    static func turnoverValue(_ value: Double?) -> String {
        guard let value else { return "loading..." }
        return String(format: "%.2f%%", value * 100)
    }

    private static func formatPrice(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if value >= 1 {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        } else {
            formatter.minimumFractionDigits = 4
            formatter.maximumFractionDigits = 4
        }

        let text = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "$\(text)"
    }
}
