import Foundation
import CFNetwork

struct PricesSnapshot {
    var btcUsd: Double?
    var ethUsd: Double?
    var btcTurnover24h: Double?
    var ethTurnover24h: Double?
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

    func fetchAll() async -> PricesSnapshot {
        async let ce = fetchCoinGecko()
        async let ex = fetchFromExchanges()
        async let turnover = fetchTurnovers24h()
        async let xau = fetchGoldXAUUSD()
        async let xag = fetchSilverXAGUSD()

        let (exBtc, exEth) = await ex
        let (cgBtc, cgEth) = await ce
        let (btcTurnover24h, ethTurnover24h) = await turnover

        let gold = await xau
        let silver = await xag

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
            updatedAt: Date()
        )
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
            let data = try await fetchData(from: url)
            let decoded = try JSONDecoder().decode(CoinGeckoResp.self, from: data)
            return (decoded.bitcoin?.usd, decoded.ethereum?.usd)
        } catch {
            return (nil, nil)
        }
    }

    private func fetchTurnovers24h() async -> (Double?, Double?) {
        let paprika = await fetchCoinPaprikaTurnovers24h()
        var btc = paprika.0
        var eth = paprika.1

        if btc == nil || eth == nil {
            let gecko = await fetchCoinGeckoTurnovers24h()
            btc = btc ?? gecko.0
            eth = eth ?? gecko.1
        }

        if btc == nil || eth == nil {
            // Last-resort approximation from Binance volume and circulating supply.
            async let btcApprox = fetchBinanceTurnover24hApprox(
                symbol: "BTCUSDT",
                supplyFetcher: fetchBTCCirculatingSupply,
                fallbackSupply: 19_900_000
            )
            async let ethApprox = fetchBinanceTurnover24hApprox(
                symbol: "ETHUSDT",
                supplyFetcher: fetchETHCirculatingSupply,
                fallbackSupply: 120_000_000
            )

            let btcApproxValue = await btcApprox
            let ethApproxValue = await ethApprox
            if btc == nil { btc = btcApproxValue }
            if eth == nil { eth = ethApproxValue }
        }

        return (btc, eth)
    }

    private struct CoinPaprikaResp: Decodable {
        let totalSupply: Double?

        enum RootKeys: String, CodingKey {
            case totalSupply = "total_supply"
            case quotes
        }

        struct Quotes: Decodable {
            struct USD: Decodable {
                let volume24h: Double?
                let marketCap: Double?

                enum CodingKeys: String, CodingKey {
                    case volume24h = "volume_24h"
                    case marketCap = "market_cap"
                }
            }

            let usd: USD?

            enum CodingKeys: String, CodingKey {
                case usd = "USD"
            }
        }

        let quotes: Quotes?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: RootKeys.self)
            totalSupply = try c.decodeIfPresent(Double.self, forKey: .totalSupply)
            quotes = try c.decodeIfPresent(Quotes.self, forKey: .quotes)
        }
    }

    private func fetchCoinPaprikaTurnovers24h() async -> (Double?, Double?) {
        async let btc = fetchCoinPaprikaTurnover24h(id: "btc-bitcoin")
        async let eth = fetchCoinPaprikaTurnover24h(id: "eth-ethereum")
        return (await btc, await eth)
    }

    private func fetchCoinPaprikaTurnover24h(id: String) async -> Double? {
        guard let url = URL(string: "https://api.coinpaprika.com/v1/tickers/\(id)") else { return nil }
        do {
            let data = try await fetchData(from: url)
            let decoded = try JSONDecoder().decode(CoinPaprikaResp.self, from: data)
            guard let vol = decoded.quotes?.usd?.volume24h, let cap = decoded.quotes?.usd?.marketCap, cap > 0 else {
                return nil
            }
            return vol / cap
        } catch {
            return nil
        }
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

    private struct Binance24hResp: Decodable {
        let quoteVolume: String
        let lastPrice: String
    }

    private func fetchCoinGeckoTurnovers24h() async -> (Double?, Double?) {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd&include_market_cap=true&include_24hr_vol=true") else {
            return (nil, nil)
        }

        do {
            let data = try await fetchData(from: url)
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

    private func fetchBinanceTurnover24hApprox(
        symbol: String,
        supplyFetcher: @escaping () async -> Double?,
        fallbackSupply: Double?
    ) async -> Double? {
        guard let url = URL(string: "https://api.binance.com/api/v3/ticker/24hr?symbol=\(symbol)") else { return nil }

        do {
            let data = try await fetchData(from: url)
            let decoded = try JSONDecoder().decode(Binance24hResp.self, from: data)
            guard let quoteVol = Double(decoded.quoteVolume), quoteVol > 0 else { return nil }

            let supply = (await supplyFetcher()) ?? fallbackSupply
            let price = Double(decoded.lastPrice)
            guard let p = price, p > 0, let supply, supply > 0 else { return nil }

            let marketCap = p * supply
            guard marketCap > 0 else { return nil }
            return quoteVol / marketCap
        } catch {
            return nil
        }
    }

    private func fetchBTCCirculatingSupply() async -> Double? {
        guard let url = URL(string: "https://blockchain.info/q/totalbc") else { return nil }
        do {
            let data = try await fetchData(from: url)
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let satoshis = Double(text),
                satoshis > 0 else {
                return await fetchCoinPaprikaTotalSupply(id: "btc-bitcoin")
            }
            return satoshis / 100_000_000.0
        } catch {
            return await fetchCoinPaprikaTotalSupply(id: "btc-bitcoin")
        }
    }

    private func fetchETHCirculatingSupply() async -> Double? {
        return await fetchCoinPaprikaTotalSupply(id: "eth-ethereum")
    }

    private func fetchCoinPaprikaTotalSupply(id: String) async -> Double? {
        guard let url = URL(string: "https://api.coinpaprika.com/v1/tickers/\(id)") else { return nil }
        do {
            let data = try await fetchData(from: url)
            let decoded = try JSONDecoder().decode(CoinPaprikaResp.self, from: data)
            guard let supply = decoded.totalSupply, supply > 0 else { return nil }
            return supply
        } catch {
            return nil
        }
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
