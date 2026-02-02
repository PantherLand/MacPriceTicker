# MacPriceTicker

A tiny macOS always-on-top desktop ticker for **BTC**, **ETH**, **Gold (XAU/USD)**, and **Silver (XAG/USD)**, with configurable price alerts.

- Floating always-on-top window (drag to move)
- Updates every ~15s
- Alerts via macOS notifications (upper/lower thresholds)

## Data sources

- BTC/ETH: CoinGecko (no API key)
- Gold/Silver: Stooq (public CSV for XAUUSD/XAGUSD)

## Build & Run

Requirements: macOS + Xcode Command Line Tools.

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
