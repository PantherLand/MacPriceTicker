import Foundation
import CFNetwork

struct PricesSnapshot {
    var btcUsd: Double?
    var ethUsd: Double?
    var btcTurnover24h: Double?
    var ethTurnover24h: Double?
    var xauUsd: Double?
    var xagUsd: Double?
    var oilUsd: Double?
    var updatedAt: Date
}

actor TurnoverCache {
    private var cached: (Double?, Double?)?
    private var updatedAt: Date?
    private var lastFailedAt: Date?
    private let refreshInterval: TimeInterval

    init(refreshInterval: TimeInterval) {
        self.refreshInterval = refreshInterval
    }

    func freshValue(now: Date = Date()) -> (Double?, Double?)? {
        guard let cached, let updatedAt else { return nil }
        guard now.timeIntervalSince(updatedAt) < refreshInterval else { return nil }
        return cached
    }

    func canRetry(now: Date = Date(), retryInterval: TimeInterval) -> Bool {
        guard let lastFailedAt else { return true }
        return now.timeIntervalSince(lastFailedAt) >= retryInterval
    }

    func currentValue() -> (Double?, Double?)? {
        return cached
    }

    func store(_ value: (Double?, Double?), now: Date = Date()) {
        cached = value
        updatedAt = now
        lastFailedAt = nil
    }

    func markFailure(now: Date = Date()) {
        lastFailedAt = now
    }
}

final class PriceService {
    private let session: URLSession
    private let turnoverCache = TurnoverCache(refreshInterval: 10 * 60)
    private let turnoverRetryInterval: TimeInterval = 60
    private let coinGeckoAPIKey: String?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10

        // Force using macOS System Proxy settings (HTTP/HTTPS/SOCKS/PAC) when configured.
        if let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any] {
            cfg.connectionProxyDictionary = dict
        }

        self.session = URLSession(configuration: cfg)
        let keyFromBundle = Bundle.main.object(forInfoDictionaryKey: "CoinGeckoAPIKey") as? String
        let keyFromEnv = ProcessInfo.processInfo.environment["COINGECKO_API_KEY"]
        let key = (keyFromBundle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? keyFromBundle
            : keyFromEnv
        self.coinGeckoAPIKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchData(from url: URL, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func coinGeckoHeaders() -> [String: String] {
        guard let key = coinGeckoAPIKey, !key.isEmpty else { return [:] }
        return [
            "x-cg-demo-api-key": key
        ]
    }

    func fetchAll(forceRefreshTurnover: Bool = false) async -> PricesSnapshot {
        async let ce = fetchCoinGecko()
        async let ex = fetchFromExchanges()
        async let turnover = fetchTurnovers24hCached(forceRefresh: forceRefreshTurnover)
        async let xau = fetchGoldXAUUSD()
        async let xag = fetchSilverXAGUSD()
        async let oil = fetchOilWTIUSD()

        let (exBtc, exEth) = await ex
        let (cgBtc, cgEth) = await ce
        let (btcTurnover24h, ethTurnover24h) = await turnover

        let gold = await xau
        let silver = await xag
        let oilPrice = await oil

        // Prefer exchange tickers; fall back to CoinGecko.
        let btc = exBtc ?? cgBtc
        let eth = exEth ?? cgEth

        return PricesSnapshot(
            btcUsd: btc,
            ethUsd: eth,
            btcTurnover24h: btcTurnover24h,
            ethTurnover24h: ethTurnover24h,
            xauUsd: gold,
            xagUsd: silver,
            oilUsd: oilPrice,
            updatedAt: Date()
        )
    }

    private func fetchTurnovers24hCached(forceRefresh: Bool) async -> (Double?, Double?) {
        let now = Date()
        if !forceRefresh, let cached = await turnoverCache.freshValue(now: now) {
            return cached
        }

        if !forceRefresh, !(await turnoverCache.canRetry(now: now, retryInterval: turnoverRetryInterval)) {
            return (nil, nil)
        }

        let fresh = await fetchTurnovers24h()
        if fresh.0 != nil || fresh.1 != nil {
            await turnoverCache.store(fresh, now: now)
            return fresh
        }

        await turnoverCache.markFailure(now: now)

        // On fetch failure, show loading instead of falling back to stale cache.
        return fresh
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
            let data = try await fetchData(from: url, headers: coinGeckoHeaders())
            let decoded = try JSONDecoder().decode(CoinGeckoResp.self, from: data)
            return (decoded.bitcoin?.usd, decoded.ethereum?.usd)
        } catch {
            return (nil, nil)
        }
    }

    private func fetchTurnovers24h() async -> (Double?, Double?) {
        // Turnover uses CoinGecko only.
        return await fetchCoinGeckoTurnovers24h()
    }

    private struct CoinGeckoTurnoverResp: Decodable {
        struct Item: Decodable {
            let usd24hVol: Double?
            let usdMarketCap: Double?

            enum CodingKeys: String, CodingKey {
                case usd24hVol = "usd_24h_vol"
                case usdMarketCap = "usd_market_cap"
            }
        }

        let bitcoin: Item?
        let ethereum: Item?
    }

    private func fetchCoinGeckoTurnovers24h() async -> (Double?, Double?) {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd&include_market_cap=true&include_24hr_vol=true") else {
            return (nil, nil)
        }

        do {
            let data = try await fetchData(from: url, headers: coinGeckoHeaders())
            let decoded = try JSONDecoder().decode(CoinGeckoTurnoverResp.self, from: data)
            return (
                turnoverRatio(item: decoded.bitcoin),
                turnoverRatio(item: decoded.ethereum)
            )
        } catch {
            return (nil, nil)
        }
    }

    private func turnoverRatio(item: CoinGeckoTurnoverResp.Item?) -> Double? {
        guard let vol = item?.usd24hVol, let cap = item?.usdMarketCap, cap > 0 else { return nil }
        return vol / cap
    }

    // MARK: - Gold (XAU/USD)

    private func fetchGoldXAUUSD() async -> Double? {
        if let v = await fetchYahooChartPrice(symbol: "GC=F") { return v }
        if let v = await fetchCurrencyApiMetalUSD(base: "xau") { return v }
        return await fetchStooqSymbolUSD(symbol: "xauusd")
    }

    private func fetchSilverXAGUSD() async -> Double? {
        if let v = await fetchYahooChartPrice(symbol: "SI=F") { return v }
        if let v = await fetchCurrencyApiMetalUSD(base: "xag") { return v }
        return await fetchStooqSymbolUSD(symbol: "xagusd")
    }

    private func fetchOilWTIUSD() async -> Double? {
        // WTI (CL=F) primary, Brent (BZ=F) fallback.
        if let v = await fetchYahooChartPrice(symbol: "CL=F") { return v }
        if let v = await fetchYahooChartPrice(symbol: "BZ=F") { return v }
        return nil
    }

    private struct YahooChartResp: Decodable {
        struct Chart: Decodable {
            struct Result: Decodable {
                struct Meta: Decodable {
                    let regularMarketPrice: Double?
                    let previousClose: Double?
                }

                struct Indicators: Decodable {
                    struct Quote: Decodable {
                        let close: [Double?]?
                    }

                    let quote: [Quote]?
                }

                let meta: Meta?
                let indicators: Indicators?
            }

            let result: [Result]?
        }

        let chart: Chart?
    }

    private func fetchYahooChartPrice(symbol: String) async -> Double? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1m&range=1d") else {
            return nil
        }

        do {
            let data = try await fetchData(
                from: url,
                headers: [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X)",
                    "Accept": "application/json,text/plain,*/*"
                ]
            )
            let decoded = try JSONDecoder().decode(YahooChartResp.self, from: data)
            guard let result = decoded.chart?.result?.first else { return nil }

            if let p = result.meta?.regularMarketPrice, p > 0 { return p }

            if let closes = result.indicators?.quote?.first?.close {
                for value in closes.reversed() {
                    if let v = value, v > 0 { return v }
                }
            }

            if let p = result.meta?.previousClose, p > 0 { return p }
            return nil
        } catch {
            return nil
        }
    }

    private func fetchCurrencyApiMetalUSD(base: String) async -> Double? {
        guard let url = URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/\(base).json") else {
            return nil
        }

        do {
            let data = try await fetchData(from: url)
            guard
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let baseMap = obj[base] as? [String: Any]
            else {
                return nil
            }

            if let usd = baseMap["usd"] as? Double, usd > 0 { return usd }
            if let usd = baseMap["usd"] as? NSNumber, usd.doubleValue > 0 { return usd.doubleValue }
            if let usdText = baseMap["usd"] as? String, let usd = Double(usdText), usd > 0 { return usd }
            return nil
        } catch {
            return nil
        }
    }

    private func fetchStooqSymbolUSD(symbol: String) async -> Double? {
        // Stooq is fallback when Yahoo returns empty/rate-limited data.
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
            let data = try await fetchData(from: u)
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
