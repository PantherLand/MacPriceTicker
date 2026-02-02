import Foundation

struct PricesSnapshot {
    var btcUsd: Double?
    var ethUsd: Double?
    var xauUsd: Double?
    var xagUsd: Double?
    var updatedAt: Date
}

final class PriceService {
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: cfg)
    }

    func fetchAll() async -> PricesSnapshot {
        async let ce = fetchCoinGecko()
        async let xau = fetchGoldXAUUSD()
        async let xag = fetchSilverXAGUSD()

        let (btc, eth) = await ce
        let gold = await xau
        let silver = await xag

        return PricesSnapshot(btcUsd: btc, ethUsd: eth, xauUsd: gold, xagUsd: silver, updatedAt: Date())
    }

    // MARK: - CoinGecko

    private struct CoinGeckoResp: Decodable {
        struct Item: Decodable {
            let usd: Double?
        }
        let bitcoin: Item?
        let ethereum: Item?
    }

    private func fetchCoinGecko() async -> (Double?, Double?) {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd") else {
            return (nil, nil)
        }

        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(CoinGeckoResp.self, from: data)
            return (decoded.bitcoin?.usd, decoded.ethereum?.usd)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - Gold (XAU/USD)

    // Public CSV from Stooq.
    // Intraday endpoint can sometimes return N/D; we fall back to daily close.
    private func fetchGoldXAUUSD() async -> Double? {
        return await fetchStooqSymbolUSD(symbol: "xauusd")
    }

    private func fetchSilverXAGUSD() async -> Double? {
        return await fetchStooqSymbolUSD(symbol: "xagusd")
    }

    private func fetchStooqSymbolUSD(symbol: String) async -> Double? {
        // Stooq intraday is generally OK; daily endpoint for these symbols can be unreliable.
        if let v = await fetchStooqClose(url: "https://stooq.com/q/l/?s=\(symbol)&f=sd2t2ohlcv&h&e=csv") {
            return v
        }
        // Fallback: same intraday without header flag
        if let v = await fetchStooqClose(url: "https://stooq.com/q/l/?s=\(symbol)&f=sd2t2ohlcv&e=csv") {
            return v
        }
        return nil
    }

    private func fetchStooqClose(url: String) async -> Double? {
        guard let u = URL(string: url) else { return nil }
        do {
            let (data, _) = try await session.data(from: u)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count >= 2 else { return nil }
            let fields = lines[1].split(separator: ",")
            // q/l: Symbol,Date,Time,Open,High,Low,Close,Volume
            // q/d/l: Symbol,Date,Open,High,Low,Close,Volume
            let closeIndex = (fields.count >= 8) ? 6 : ((fields.count >= 6) ? 5 : -1)
            guard closeIndex >= 0, fields.count > closeIndex else { return nil }

            let raw = fields[closeIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw == "N/D" || raw == "n/a" { return nil }
            return Double(raw)
        } catch {
            return nil
        }
    }
}
