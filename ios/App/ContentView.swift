import SwiftUI
import WidgetKit

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var snapshot: MarketSnapshot = .loading
    @Published var isRefreshing = false

    private let service = PriceService()
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await refresh(forceTurnover: false, reloadWidget: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await refresh(forceTurnover: false, reloadWidget: false)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshNow() {
        Task {
            await refresh(forceTurnover: true, reloadWidget: true)
        }
    }

    private func refresh(forceTurnover: Bool, reloadWidget: Bool) async {
        isRefreshing = true
        let latest = await service.fetchAll(forceRefreshTurnover: forceTurnover)
        snapshot = latest
        isRefreshing = false
        if reloadWidget {
            WidgetCenter.shared.reloadTimelines(ofKind: "TickerWidget")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.07, blue: 0.12),
                    Color(red: 0.02, green: 0.05, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BTC / ETH / Gold / Silver / Oil")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Same sources as macOS. App view refreshes every 15s while foreground.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Button {
                        viewModel.refreshNow()
                    } label: {
                        Image(systemName: viewModel.isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 10) {
                    line(MarketText.priceLine("BTC", viewModel.snapshot.btcUsd), emphasis: true)
                    line(MarketText.priceLine("ETH", viewModel.snapshot.ethUsd), emphasis: true)
                    line(MarketText.turnoverLine("BTC", viewModel.snapshot.btcTurnover24h))
                    line(MarketText.turnoverLine("ETH", viewModel.snapshot.ethTurnover24h))
                    line(MarketText.priceLine("XAU/USD", viewModel.snapshot.xauUsd), emphasis: true)
                    line(MarketText.priceLine("XAG/USD", viewModel.snapshot.xagUsd), emphasis: true)
                    line(MarketText.priceLine("WTI/USD", viewModel.snapshot.oilUsd), emphasis: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                )

                Text(MarketText.updatedLine(viewModel.snapshot.updatedAt))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()
            }
            .padding(24)
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                viewModel.start()
            } else {
                viewModel.stop()
            }
        }
    }

    private func line(_ text: String, emphasis: Bool = false) -> some View {
        Text(text)
            .font(emphasis ? .system(size: 19, weight: .bold, design: .rounded) : .system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(emphasis ? .white : Color(red: 0.72, green: 0.93, blue: 1.0))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
