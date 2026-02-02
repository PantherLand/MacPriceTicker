import Foundation

struct PricesSnapshot {
    var btcUsd: Double?
    var ethUsd: Double?
    var xauUsd: Double?
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

        let (btc, eth) = await ce
        let gold = await xau

        return PricesSnapshot(btcUsd: btc, ethUsd: eth, xauUsd: gold, updatedAt: Date())
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

    // Public CSV from Stooq. Note: quote may be delayed.
    // Example:
    // Symbol,Date,Time,Open,High,Low,Close,Volume
    // XAUUSD,2026-02-02,21:58:00,....
    private func fetchGoldXAUUSD() async -> Double? {
        guard let url = URL(string: "https://stooq.com/q/l/?s=xauusd&f=sd2t2ohlcv&h&e=csv") else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count >= 2 else { return nil }
            let fields = lines[1].split(separator: ",")
            // fields: Symbol,Date,Time,Open,High,Low,Close,Volume
            guard fields.count >= 7 else { return nil }
            let close = fields[6]
            return Double(close)
        } catch {
            return nil
        }
    }
}
