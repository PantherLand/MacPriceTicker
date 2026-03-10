# MacPriceTicker

A tiny macOS always-on-top desktop ticker for **BTC**, **ETH**, **Gold (XAU/USD)**, **Silver (XAG/USD)**, and **WTI Oil (WTI/USD)**, with configurable price alerts.

- Floating always-on-top window (drag to move)
- Updates every ~15s
- BTC/ETH turnover refreshes every 10 minutes (or immediately on manual Refresh)
- Alerts via macOS notifications (upper/lower thresholds)

## Data sources

- BTC/ETH: Binance / OKX / Bybit public ticker (primary), CoinGecko fallback
- BTC/ETH 24h turnover rate: CoinGecko only (`24h volume / market cap`)
- Gold/Silver: Yahoo Finance futures (`GC=F` / `SI=F`) primary, currency-api fallback, Stooq fallback
- Oil (WTI/USD): Yahoo Finance futures (`CL=F`) primary, Brent (`BZ=F`) fallback

CoinGecko key is read from `CoinGeckoAPIKey` in `Resources/Info.plist` (or `COINGECKO_API_KEY` env var).

## Build & Run

Requirements: macOS + Xcode Command Line Tools.
Runtime target: Apple Silicon (arm64), macOS 12.0 to 15.x.

```bash
make run
```

This will:
- compile `MacPriceTicker`
- create `MacPriceTicker.app`
- launch the app

## Usage

- Drag the floating widget to reposition.
- Right-click (or control-click) the widget to open the menu.
- Choose **Set Alerts…** to configure thresholds.

## Notes

This is intentionally minimal (no login, no keys). If you want more reliable gold quotes, we can plug in a paid data provider.

## Distribution (Gatekeeper)

- `make dmg` now ad-hoc signs the app bundle by default (better than raw unsigned).
- For sharing to other Macs without warnings, use **Developer ID signing + notarization**:

```bash
make dmg SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
xcrun notarytool submit dist/MacPriceTicker-0.1.0.dmg --apple-id "APPLE_ID" --team-id "TEAMID" --password "APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple dist/MacPriceTicker-0.1.0.dmg
```

- If a receiver still sees a block on macOS 12, remove quarantine once:

```bash
xattr -dr com.apple.quarantine /Applications/MacPriceTicker.app
```
