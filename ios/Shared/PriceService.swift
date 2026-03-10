import Foundation

actor TurnoverCache {
    private struct CachePayload: Codable {
        let btc: Double?
        let eth: Double?
        let updatedAt: Date?
        let lastFailedAt: Date?
    }

    private let refreshInterval: TimeInterval
    private let defaults: UserDefaults
    private let storageKey = "ticker.turnover.cache.v1"

    init(refreshInterval: TimeInterval, defaults: UserDefaults = .standard) {
        self.refreshInterval = refreshInterval
        self.defaults = defaults
    }

    func freshValue(now: Date = Date()) -> (Double?, Double?)? {
        guard let payload = load(), let updatedAt = payload.updatedAt else { return nil }
        guard now.timeIntervalSince(updatedAt) < refreshInterval else { return nil }
        return (payload.btc, payload.eth)
    }

    func canRetry(now: Date = Date(), retryInterval: TimeInterval) -> Bool {
        guard let payload = load(), let lastFailedAt = payload.lastFailedAt else { return true }
        return now.timeIntervalSince(lastFailedAt) >= retryInterval
    }

    func store(_ value: (Double?, Double?), now: Date = Date()) {
        save(CachePayload(btc: value.0, eth: value.1, updatedAt: now, lastFailedAt: nil))
    }

    func markFailure(now: Date = Date()) {
        let existing = load()
        save(CachePayload(
            btc: existing?.btc,
            eth: existing?.eth,
            updatedAt: existing?.updatedAt,
            lastFailedAt: now
        ))
    }

    private func load() -> CachePayload? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private func save(_ payload: CachePayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

final class PriceService {
    private let session: URLSession
    private let turnoverCache = TurnoverCache(refreshInterval: 10 * 60)
    private let turnoverRetryInterval: TimeInterval = 60
    private let coinGeckoAPIKey: String?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
        let key = Bundle.main.object(forInfoDictionaryKey: "CoinGeckoAPIKey") as? String
        self.coinGeckoAPIKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchAll(forceRefreshTurnover: Bool = false) async -> MarketSnapshot {
        async let exchange = fetchFromExchanges()
        async let gecko = fetchCoinGecko()
        async let turnover = fetchTurnovers24hCached(forceRefresh: forceRefreshTurnover)
        async let xau = fetchGoldXAUUSD()
        async let xag = fetchSilverXAGUSD()
        async let oil = fetchOilWTIUSD()
        async let nvda = fetchNVDAUSD()

        let (exchangeBTC, exchangeETH) = await exchange
        let (geckoBTC, geckoETH) = await gecko
        let (btcTurnover, ethTurnover) = await turnover

        return MarketSnapshot(
            btcUsd: exchangeBTC ?? geckoBTC,
            ethUsd: exchangeETH ?? geckoETH,
            btcTurnover24h: btcTurnover,
            ethTurnover24h: ethTurnover,
            xauUsd: await xau,
            xagUsd: await xag,
            oilUsd: await oil,
            nvdaUsd: await nvda,
            updatedAt: .now
        )
    }

    private func fetchNVDAUSD() async -> Double? {
        return await fetchYahooChartPrice(symbol: "NVDA")
    }

    private func fetchData(from url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func coinGeckoHeaders() -> [String: String] {
        guard let coinGeckoAPIKey, !coinGeckoAPIKey.isEmpty else { return [:] }
        return ["x-cg-demo-api-key": coinGeckoAPIKey]
    }

    private func fetchTurnovers24hCached(forceRefresh: Bool) async -> (Double?, Double?) {
        let now = Date()
        if !forceRefresh, let cached = await turnoverCache.freshValue(now: now) {
            return cached
        }

        if !forceRefresh, !(await turnoverCache.canRetry(now: now, retryInterval: turnoverRetryInterval)) {
            return (nil, nil)
        }

        let fresh = await fetchCoinGeckoTurnovers24h()
        if fresh.0 != nil || fresh.1 != nil {
            await turnoverCache.store(fresh, now: now)
            return fresh
        }

        await turnoverCache.markFailure(now: now)
        return fresh
    }

    private func fetchFromExchanges() async -> (Double?, Double?) {
        if let value = await fetchBinance() { return value }
        if let value = await fetchOKX() { return value }
        if let value = await fetchBybit() { return value }
        return (nil, nil)
    }

    private struct BinancePriceResponse: Decodable {
        let price: String
    }

    private func fetchBinance() async -> (Double?, Double?)? {
        async let btc = fetchBinancePrice(symbol: "BTCUSDT")
        async let eth = fetchBinancePrice(symbol: "ETHUSDT")
        let result = await (btc, eth)
        if result.0 == nil && result.1 == nil { return nil }
        return result
    }

    private func fetchBinancePrice(symbol: String) async -> Double? {
        guard let url = URL(string: "https://api.binance.com/api/v3/ticker/price?symbol=\(symbol)") else { return nil }
        do {
            let data = try await fetchData(from: url)
            let response = try JSONDecoder().decode(BinancePriceResponse.self, from: data)
            return Double(response.price)
        } catch {
            return nil
        }
    }

    private struct OKXResponse: Decodable {
        struct Item: Decodable {
            let last: String?
        }

        let data: [Item]?
    }

    private func fetchOKX() async -> (Double?, Double?)? {
        async let btc = fetchOKXPrice(instId: "BTC-USDT")
        async let eth = fetchOKXPrice(instId: "ETH-USDT")
        let result = await (btc, eth)
        if result.0 == nil && result.1 == nil { return nil }
        return result
    }

    private func fetchOKXPrice(instId: String) async -> Double? {
        guard let url = URL(string: "https://www.okx.com/api/v5/market/ticker?instId=\(instId)") else { return nil }
        do {
            let data = try await fetchData(from: url)
            let response = try JSONDecoder().decode(OKXResponse.self, from: data)
            guard let last = response.data?.first?.last else { return nil }
            return Double(last)
        } catch {
            return nil
        }
    }

    private struct BybitResponse: Decodable {
        struct Result: Decodable {
            struct Item: Decodable {
                let lastPrice: String?
            }

            let list: [Item]?
        }

        let result: Result?
    }

    private func fetchBybit() async -> (Double?, Double?)? {
        async let btc = fetchBybitPrice(symbol: "BTCUSDT")
        async let eth = fetchBybitPrice(symbol: "ETHUSDT")
        let result = await (btc, eth)
        if result.0 == nil && result.1 == nil { return nil }
        return result
    }

    private func fetchBybitPrice(symbol: String) async -> Double? {
        guard let url = URL(string: "https://api.bybit.com/v5/market/tickers?category=spot&symbol=\(symbol)") else { return nil }
        do {
            let data = try await fetchData(from: url)
            let response = try JSONDecoder().decode(BybitResponse.self, from: data)
            guard let last = response.result?.list?.first?.lastPrice else { return nil }
            return Double(last)
        } catch {
            return nil
        }
    }

    private struct CoinGeckoPriceResponse: Decodable {
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
            let response = try JSONDecoder().decode(CoinGeckoPriceResponse.self, from: data)
            return (response.bitcoin?.usd, response.ethereum?.usd)
        } catch {
            return (nil, nil)
        }
    }

    private struct CoinGeckoTurnoverResponse: Decodable {
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
            let response = try JSONDecoder().decode(CoinGeckoTurnoverResponse.self, from: data)
            return (turnoverRatio(item: response.bitcoin), turnoverRatio(item: response.ethereum))
        } catch {
            return (nil, nil)
        }
    }

    private func turnoverRatio(item: CoinGeckoTurnoverResponse.Item?) -> Double? {
        guard let volume = item?.usd24hVol, let marketCap = item?.usdMarketCap, marketCap > 0 else { return nil }
        return volume / marketCap
    }

    private func fetchGoldXAUUSD() async -> Double? {
        if let value = await fetchYahooChartPrice(symbol: "GC=F") { return value }
        if let value = await fetchCurrencyApiMetalUSD(base: "xau") { return value }
        return await fetchStooqSymbolUSD(symbol: "xauusd")
    }

    private func fetchSilverXAGUSD() async -> Double? {
        if let value = await fetchYahooChartPrice(symbol: "SI=F") { return value }
        if let value = await fetchCurrencyApiMetalUSD(base: "xag") { return value }
        return await fetchStooqSymbolUSD(symbol: "xagusd")
    }

    private func fetchOilWTIUSD() async -> Double? {
        if let value = await fetchYahooChartPrice(symbol: "CL=F") { return value }
        if let value = await fetchYahooChartPrice(symbol: "BZ=F") { return value }
        return nil
    }

    private struct YahooChartResponse: Decodable {
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
                    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)",
                    "Accept": "application/json,text/plain,*/*"
                ]
            )
            let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let result = response.chart?.result?.first else { return nil }
            if let price = result.meta?.regularMarketPrice, price > 0 { return price }
            if let closes = result.indicators?.quote?.first?.close {
                for close in closes.reversed() {
                    if let close, close > 0 { return close }
                }
            }
            if let previousClose = result.meta?.previousClose, previousClose > 0 { return previousClose }
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
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let baseMap = object[base] as? [String: Any]
            else {
                return nil
            }

            if let usd = baseMap["usd"] as? Double, usd > 0 { return usd }
            if let usd = baseMap["usd"] as? NSNumber, usd.doubleValue > 0 { return usd.doubleValue }
            if let text = baseMap["usd"] as? String, let usd = Double(text), usd > 0 { return usd }
            return nil
        } catch {
            return nil
        }
    }

    private func fetchStooqSymbolUSD(symbol: String) async -> Double? {
        if let value = await fetchStooqClose(url: "https://stooq.com/q/l/?s=\(symbol)&f=sd2t2ohlcv&h&e=csv") {
            return value
        }
        return await fetchStooqClose(url: "https://stooq.com/q/l/?s=\(symbol)&f=sd2t2ohlcv&e=csv")
    }

    private func fetchStooqClose(url: String) async -> Double? {
        guard let url = URL(string: url) else { return nil }
        do {
            let data = try await fetchData(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count >= 2 else { return nil }
            let fields = lines[1].split(separator: ",")
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
