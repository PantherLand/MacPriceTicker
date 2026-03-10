import SwiftUI
import WidgetKit

struct MarketEntry: TimelineEntry {
    let date: Date
    let snapshot: MarketSnapshot
}

struct MarketProvider: TimelineProvider {
    func placeholder(in context: Context) -> MarketEntry {
        MarketEntry(date: .now, snapshot: .loading)
    }

    func getSnapshot(in context: Context, completion: @escaping (MarketEntry) -> Void) {
        Task {
            let snapshot = await PriceService().fetchAll(forceRefreshTurnover: false)
            completion(MarketEntry(date: .now, snapshot: snapshot))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MarketEntry>) -> Void) {
        Task {
            let snapshot = await PriceService().fetchAll(forceRefreshTurnover: false)
            let entry = MarketEntry(date: .now, snapshot: snapshot)
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

private struct AssetItem: Identifiable {
    let id: String
    let symbol: String
    let iconText: String
    let price: String
    let turnover: String
}

private struct WidgetTheme {
    let canvasTop: Color
    let canvasBottom: Color
    let surface: Color
    let stroke: Color
    let title: Color
    let primary: Color
    let secondary: Color
    let muted: Color
    let divider: Color
    let blue: Color
    let blueDark: Color
    let green: Color

    static let dark = WidgetTheme(
        canvasTop: Color(red: 0.10, green: 0.10, blue: 0.11),
        canvasBottom: Color(red: 0.08, green: 0.08, blue: 0.09),
        surface: Color(red: 0.11, green: 0.11, blue: 0.12),
        stroke: Color.white.opacity(0.12),
        title: .white,
        primary: Color.white.opacity(0.95),
        secondary: Color.white.opacity(0.68),
        muted: Color.white.opacity(0.42),
        divider: Color.white.opacity(0.10),
        blue: Color(red: 0.24, green: 0.52, blue: 1.0),
        blueDark: Color(red: 0.12, green: 0.33, blue: 0.78),
        green: Color(red: 0.23, green: 0.87, blue: 0.35)
    )

    static let light = WidgetTheme(
        canvasTop: Color(red: 0.95, green: 0.95, blue: 0.96),
        canvasBottom: Color(red: 0.92, green: 0.92, blue: 0.93),
        surface: Color(red: 0.93, green: 0.93, blue: 0.94),
        stroke: Color.black.opacity(0.08),
        title: Color.black.opacity(0.98),
        primary: Color.black.opacity(0.96),
        secondary: Color.black.opacity(0.52),
        muted: Color.black.opacity(0.34),
        divider: Color.black.opacity(0.08),
        blue: Color(red: 0.24, green: 0.52, blue: 1.0),
        blueDark: Color(red: 0.12, green: 0.33, blue: 0.78),
        green: Color(red: 0.23, green: 0.80, blue: 0.31)
    )
}

struct TickerWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: MarketEntry

    private var theme: WidgetTheme {
        colorScheme == .dark ? .dark : .light
    }

    private var compactTitle: String {
        colorScheme == .dark ? "核心资产" : "Core Assets"
    }

    private var overviewTitle: String {
        colorScheme == .dark ? "核心资产概览" : "Core Assets"
    }

    private var items: [AssetItem] {
        [
            AssetItem(id: "btc", symbol: "BTC", iconText: "₿", price: MarketText.priceValue(entry.snapshot.btcUsd), turnover: MarketText.turnoverValue(entry.snapshot.btcTurnover24h)),
            AssetItem(id: "eth", symbol: "ETH", iconText: "◆", price: MarketText.priceValue(entry.snapshot.ethUsd), turnover: MarketText.turnoverValue(entry.snapshot.ethTurnover24h)),
            AssetItem(id: "xau", symbol: "XAU", iconText: "🥇", price: MarketText.priceValue(entry.snapshot.xauUsd), turnover: "--"),
            AssetItem(id: "xag", symbol: "XAG", iconText: "🥈", price: MarketText.priceValue(entry.snapshot.xagUsd), turnover: "--"),
            AssetItem(id: "wti", symbol: "WTI", iconText: "🛢", price: MarketText.priceValue(entry.snapshot.oilUsd), turnover: "--"),
            AssetItem(id: "nvda", symbol: "NVDA", iconText: "🖥", price: MarketText.priceValue(entry.snapshot.nvdaUsd), turnover: "--")
        ]
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallCard
            case .systemLarge:
                largeOverview
            default:
                mediumOverview
            }
        }
        .widgetSurface(theme: theme)
    }

    private var smallCard: some View {
        let btc = items[0]

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                assetIcon(for: btc, size: 42)
                Text(btc.symbol)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.title)
                Spacer()
                Circle()
                    .fill(entry.snapshot.btcUsd == nil ? theme.muted : theme.green)
                    .frame(width: 10, height: 10)
            }

            Spacer(minLength: 10)

            Text(btc.price)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.52)

            Text("Vol: \(btc.turnover)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondary)
                .padding(.top, 8)
        }
        .padding(18)
    }

    private var mediumOverview: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: compactTitle, compact: true)
                .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    mediumAssetCell(items[0])
                    mediumAssetCell(items[2])
                    mediumAssetCell(items[4])
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(spacing: 10) {
                    mediumAssetCell(items[1])
                    mediumAssetCell(items[3])
                    mediumAssetCell(items[5])
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var largeOverview: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: overviewTitle, compact: false)
                .padding(.bottom, 12)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                largeAssetRow(item)
                    .padding(.vertical, 9)

                if index < items.count - 1 {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(height: 1)
                        .padding(.horizontal, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func header(title: String, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: compact ? 18 : 19, weight: .bold, design: .rounded))
                .foregroundStyle(theme.title)
                .offset(y: -1)

            Spacer()

            HStack(spacing: 8) {
                Text(MarketText.headerTime(entry.snapshot.updatedAt))
                    .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondary)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(theme.muted)
            }
            .offset(y: compact ? -1 : 0)
        }
    }

    private func largeAssetRow(_ item: AssetItem) -> some View {
        HStack(spacing: 12) {
            assetIcon(for: item, size: 33)

            Text(item.symbol)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primary)
                .frame(width: 56, alignment: .leading)

            Spacer(minLength: 0)

            Text("Vol: \(item.turnover)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(item.turnover == "--" ? theme.muted : theme.secondary)
                .frame(width: 72, alignment: .trailing)

            Text(item.price)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 116, alignment: .trailing)
        }
    }

    private func mediumAssetCell(_ item: AssetItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            assetIcon(for: item, size: 28)

            Text(item.symbol)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                Text(item.price)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if item.turnover != "--" {
                    Text("Vol: \(item.turnover)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondary)
                }
            }
        }
    }

    private func assetIcon(for item: AssetItem, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(iconBackground(for: item))
            Text(item.iconText)
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(iconForeground(for: item))
        }
        .frame(width: size, height: size)
    }

    private func iconBackground(for item: AssetItem) -> AnyShapeStyle {
        switch item.id {
        case "btc":
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        colorScheme == .dark ? Color.white.opacity(0.28) : Color.white.opacity(0.82),
                        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case "eth":
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.blue, theme.blueDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        default:
            return AnyShapeStyle(Color.clear)
        }
    }

    private func iconForeground(for item: AssetItem) -> Color {
        switch item.id {
        case "eth":
            return .white
        case "btc":
            return colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.84)
        default:
            return theme.primary
        }
    }
}

private struct WidgetSurfaceModifier: ViewModifier {
    let theme: WidgetTheme

    func body(content: Content) -> some View {
        let surface = RoundedRectangle(cornerRadius: 28, style: .continuous)

        if #available(iOSApplicationExtension 17.0, *) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(
                    surface
                        .stroke(theme.stroke, lineWidth: 1)
                        .padding(1)
                )
                .containerBackground(for: .widget) {
                    surface
                        .fill(
                            LinearGradient(
                                colors: [theme.canvasTop, theme.canvasBottom],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        } else {
            ZStack {
                surface
                    .fill(
                        LinearGradient(
                            colors: [theme.canvasTop, theme.canvasBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .overlay(surface.stroke(theme.stroke, lineWidth: 1))
        }
    }
}

private extension View {
    func widgetSurface(theme: WidgetTheme) -> some View {
        modifier(WidgetSurfaceModifier(theme: theme))
    }
}

struct TickerWidget: Widget {
    let kind = "TickerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MarketProvider()) { entry in
            TickerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Core Assets")
        .description("Core assets widget for BTC, ETH, XAU, XAG, WTI and NVDA.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct TickerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TickerWidget()
    }
}
