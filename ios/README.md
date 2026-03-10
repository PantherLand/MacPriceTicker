# iOS Folder

This folder contains an iOS host app plus a Home Screen widget built with `SwiftUI` and `WidgetKit`.

## Scope

- Same data sources as the macOS app
- Same turnover logic: CoinGecko only, cached for 10 minutes, 60 second retry delay after failure
- iOS app screen refreshes every 15 seconds while the app is foregrounded
- Widget uses the same sources, but actual refresh cadence is controlled by WidgetKit and cannot match the macOS 15 second loop reliably

## Data Sources

- BTC / ETH price: Binance, then OKX, then Bybit, then CoinGecko fallback
- BTC / ETH 24h turnover: CoinGecko only (`24h volume / market cap`)
- XAU/USD: Yahoo Finance `GC=F`, then currency-api, then Stooq
- XAG/USD: Yahoo Finance `SI=F`, then currency-api, then Stooq
- WTI/USD: Yahoo Finance `CL=F`, then Brent `BZ=F`

## Build

```bash
cd ios
xcodegen generate
open MacPriceTickerIOS.xcodeproj
```

Then build the `MacPriceTickerIOS` scheme in Xcode.

## Notes

- The CoinGecko API key is currently mirrored into both iOS plist files for convenience.
- If you want cleaner key management next, move it to build settings or an `.xcconfig`.
- Widget refresh requests are set to every 15 minutes, but iOS may delay or coalesce them.
