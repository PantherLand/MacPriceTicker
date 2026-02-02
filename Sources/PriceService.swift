import Foundation
import CFNetwork

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

        // Force using macOS System Proxy settings (HTTP/HTTPS/SOCKS/PAC) when configured.
        if let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any] {
            cfg.connectionProxyDictionary = dict
        }

        self.session = URLSession(configuration: cfg)
    }

    func fetchAll() async -> PricesSnapshot {
        async let ce = fetchCoinGecko()
        async let ex = fetchFromExchanges()
        async let xau = fetchGoldXAUUSD()
        async let xag = fetchSilverXAGUSD()

        let (exBtc, exEth) = await ex
        let (cgBtc, cgEth) = await ce

        let gold = await xau
        let silver = await xag

        // Prefer exchange tickers; fall back to CoinGecko.
        let btc = exBtc ?? cgBtc
        let eth = exEth ?? cgEth

        return PricesSnapshot(btcUsd: btc, ethUsd: eth, xauUsd: gold, xagUsd: silver, updatedAt: Date())
    }

    // MARK: - Exchanges (primary)

    private func fetchFromExchanges() async -> (Double?, Double?) {
        // Try in order: Binance → OKX → Bybit
        if let v = await fetchBinance() { return v }
        if let v = await fetchOKX() { return v }
        if let v = await fetchBybit() { return v }
        return (nil, nil)
    }

    private func fetchBinance() async -> (Double?, Double?)? {
        async let btc = fetchBinancePrice(symbol: "BTCUSDT")
        async let eth = fetchBinancePrice(symbol: "ETHUSDT")
        let b = await btc
        let e = await eth
        if b == nil && e == nil { return nil }
        return (b, e)
    }

    private struct BinancePriceResp: Decodable {
        let price: String
    }

    private func fetchBinancePrice(symbol: String) async -> Double? {
        guard let url = URL(string: "https://api.binance.com/api/v3/ticker/price?symbol=\(symbol)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(BinancePriceResp.self, from: data)
            return Double(decoded.price)
        } catch {
            return nil
        }
    }

    private func fetchOKX() async -> (Double?, Double?)? {
        async let btc = fetchOKXLast(instId: "BTC-USDT")
        async let eth = fetchOKXLast(instId: "ETH-USDT")
        let b = await btc
        let e = await eth
        if b == nil && e == nil { return nil }
        return (b, e)
    }

    private struct OKXResp: Decodable {
        struct Item: Decodable {
            let last: String?
        }
        let data: [Item]?
    }

    private func fetchOKXLast(instId: String) async -> Double? {
        guard let url = URL(string: "https://www.okx.com/api/v5/market/ticker?instId=\(instId)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(OKXResp.self, from: data)
            guard let last = decoded.data?.first?.last else { return nil }
            return Double(last)
        } catch {
            return nil
        }
    }

    private func fetchBybit() async -> (Double?, Double?)? {
        async let btc = fetchBybitLast(symbol: "BTCUSDT")
        async let eth = fetchBybitLast(symbol: "ETHUSDT")
        let b = await btc
        let e = await eth
        if b == nil && e == nil { return nil }
        return (b, e)
    }

    private struct BybitResp: Decodable {
        struct Result: Decodable {
            struct Item: Decodable {
                let lastPrice: String?
            }
            let list: [Item]?
        }
        let result: Result?
    }

    private func fetchBybitLast(symbol: String) async -> Double? {
        guard let url = URL(string: "https://api.bybit.com/v5/market/tickers?category=spot&symbol=\(symbol)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(BybitResp.self, from: data)
            guard let last = decoded.result?.list?.first?.lastPrice else { return nil }
            return Double(last)
        } catch {
            return nil
        }
    }

    // MARK: - CoinGecko (fallback)

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
