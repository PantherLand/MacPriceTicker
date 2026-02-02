import Foundation
import UserNotifications

struct AlertSettings: Codable {
    var btcAbove: Double?
    var btcBelow: Double?
    var ethAbove: Double?
    var ethBelow: Double?
    var xauAbove: Double?
    var xauBelow: Double?
    var xagAbove: Double?
    var xagBelow: Double?
}

final class Alerts {
    private let center = UNUserNotificationCenter.current()
    private let defaultsKey = "alerts.v1"
    private let firedKey = "alerts.fired.v1"

    private(set) var settings: AlertSettings

    // Avoid spamming: remember which thresholds have already fired.
    // Keys like: btcAbove, btcBelow...
    private var fired: Set<String>

    init() {
        self.settings = Alerts.loadSettings(defaultsKey: defaultsKey)
        self.fired = Alerts.loadFired(firedKey: firedKey)

        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func updateSettings(_ new: AlertSettings) {
        settings = new
        Alerts.saveSettings(settings, defaultsKey: defaultsKey)
        // Reset fired markers when user changes settings
        fired.removeAll()
        Alerts.saveFired(fired, firedKey: firedKey)
    }

    func evaluate(prices: PricesSnapshot) {
        check(symbol: "BTC", above: settings.btcAbove, below: settings.btcBelow, value: prices.btcUsd, prefix: "btc")
        check(symbol: "ETH", above: settings.ethAbove, below: settings.ethBelow, value: prices.ethUsd, prefix: "eth")
        check(symbol: "XAU/USD", above: settings.xauAbove, below: settings.xauBelow, value: prices.xauUsd, prefix: "xau")
        check(symbol: "XAG/USD", above: settings.xagAbove, below: settings.xagBelow, value: prices.xagUsd, prefix: "xag")
    }

    private func check(symbol: String, above: Double?, below: Double?, value: Double?, prefix: String) {
        guard let v = value else { return }

        if let a = above {
            let key = "\(prefix)Above"
            if v >= a {
                if !fired.contains(key) {
                    notify(title: "\(symbol) alert", body: "Crossed above \(format(a)) (now \(format(v)))")
                    fired.insert(key)
                    Alerts.saveFired(fired, firedKey: firedKey)
                }
            } else {
                fired.remove(key)
            }
        }

        if let b = below {
            let key = "\(prefix)Below"
            if v <= b {
                if !fired.contains(key) {
                    notify(title: "\(symbol) alert", body: "Crossed below \(format(b)) (now \(format(v)))")
                    fired.insert(key)
                    Alerts.saveFired(fired, firedKey: firedKey)
                }
            } else {
                fired.remove(key)
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    private func format(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }

    private static func loadSettings(defaultsKey: String) -> AlertSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return AlertSettings() }
        return (try? JSONDecoder().decode(AlertSettings.self, from: data)) ?? AlertSettings()
    }

    private static func saveSettings(_ s: AlertSettings, defaultsKey: String) {
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func loadFired(firedKey: String) -> Set<String> {
        guard let arr = UserDefaults.standard.array(forKey: firedKey) as? [String] else { return [] }
        return Set(arr)
    }

    private static func saveFired(_ fired: Set<String>, firedKey: String) {
        UserDefaults.standard.set(Array(fired), forKey: firedKey)
    }
}
