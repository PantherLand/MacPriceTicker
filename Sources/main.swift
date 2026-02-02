import Cocoa

// A minimal always-on-top desktop ticker without Xcode project.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSPanel!
    private var view: TickerView!
    private let service = PriceService()
    private let alerts = Alerts()

    private var timer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no dock icon

        view = TickerView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        view.onMenuRequested = { [weak self] in self?.showMenu() }
        view.onRefreshRequested = { [weak self] in self?.refreshNow() }

        window = FloatingPanel(contentRect: view.bounds)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)

        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
        timer = nil
    }

    private func startPolling() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(15), leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                let snap = await self.service.fetchAll()
                self.alerts.evaluate(prices: snap)
                DispatchQueue.main.async {
                    self.view.update(snapshot: snap)
                }
            }
        }
        t.resume()
        timer = t
    }

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Set Alerts…", action: #selector(openAlerts), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: view)
    }

    @objc private func refreshNow() {
        Task {
            let snap = await service.fetchAll()
            alerts.evaluate(prices: snap)
            await MainActor.run { view.update(snapshot: snap) }
        }
    }

    @objc private func openAlerts() {
        AlertsDialog.present(current: alerts.settings) { [weak self] updated in
            self?.alerts.updateSettings(updated)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
}

final class TickerView: NSView {
    var onMenuRequested: (() -> Void)?
    var onRefreshRequested: (() -> Void)?

    private let title = NSTextField(labelWithString: "Ticker")
    private let refreshBtn = NSButton(title: "↻", target: nil, action: nil)
    private let btc = NSTextField(labelWithString: "BTC: —")
    private let eth = NSTextField(labelWithString: "ETH: —")
    private let xau = NSTextField(labelWithString: "XAU/USD: —")
    private let updated = NSTextField(labelWithString: "—")

    private var snapshot: PricesSnapshot?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let bg = CAGradientLayer()
        bg.colors = [
            NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.10, alpha: 0.92).cgColor,
            NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.08, alpha: 0.92).cgColor
        ]
        bg.startPoint = CGPoint(x: 0, y: 0)
        bg.endPoint = CGPoint(x: 1, y: 1)
        bg.frame = bounds
        layer?.addSublayer(bg)

        let glow = CALayer()
        glow.backgroundColor = NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 0.08).cgColor
        glow.frame = bounds.insetBy(dx: -20, dy: -20)
        glow.cornerRadius = 20
        glow.shadowColor = NSColor.systemPink.cgColor
        glow.shadowOpacity = 0.25
        glow.shadowRadius = 18
        glow.shadowOffset = CGSize(width: 0, height: 0)
        layer?.addSublayer(glow)

        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .white
        title.stringValue = "BTC / ETH / Gold"

        refreshBtn.bezelStyle = .texturedRounded
        refreshBtn.isBordered = true
        refreshBtn.font = .systemFont(ofSize: 13, weight: .bold)
        refreshBtn.contentTintColor = NSColor(white: 1, alpha: 0.85)
        refreshBtn.wantsLayer = true
        refreshBtn.layer?.cornerRadius = 8
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshClicked)

        for l in [btc, eth, xau] {
            l.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            l.textColor = .white
        }

        updated.font = .systemFont(ofSize: 11)
        updated.textColor = NSColor(white: 1, alpha: 0.65)

        let header = NSStackView(views: [title, NSView(), refreshBtn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let stack = NSStackView(views: [header, btc, eth, xau, updated])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),

            refreshBtn.widthAnchor.constraint(equalToConstant: 30),
            refreshBtn.heightAnchor.constraint(equalToConstant: 24)
        ])

        update(snapshot: PricesSnapshot(btcUsd: nil, ethUsd: nil, xauUsd: nil, updatedAt: Date()))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.sublayers?.first?.frame = bounds
    }

    @objc private func refreshClicked() {
        onRefreshRequested?()
    }

    func update(snapshot: PricesSnapshot) {
        self.snapshot = snapshot
        btc.stringValue = "BTC: \(fmt(snapshot.btcUsd))"
        eth.stringValue = "ETH: \(fmt(snapshot.ethUsd))"
        xau.stringValue = "XAU/USD: \(fmt(snapshot.xauUsd))"

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        updated.stringValue = "Updated: \(df.string(from: snapshot.updatedAt))"
    }

    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v >= 1000 { return String(format: "$%.0f", v) }
        if v >= 100 { return String(format: "$%.2f", v) }
        return String(format: "$%.4f", v)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenuRequested?()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.type == .otherMouseDown { onMenuRequested?() }
    }
}

enum AlertsDialog {
    static func present(current: AlertSettings, onSave: @escaping (AlertSettings) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Set price alerts"
        alert.informativeText = "Leave empty to disable a threshold. Values are in USD." 
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: ""), NSTextField(labelWithString: "Above"), NSTextField(labelWithString: "Below")],
            [NSTextField(labelWithString: "BTC"), NSTextField(), NSTextField()],
            [NSTextField(labelWithString: "ETH"), NSTextField(), NSTextField()],
            [NSTextField(labelWithString: "XAU/USD"), NSTextField(), NSTextField()],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        func setup(_ tf: NSTextField) {
            tf.placeholderString = "—"
            tf.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        let btcA = grid.cell(atColumnIndex: 1, rowIndex: 1).contentView as! NSTextField
        let btcB = grid.cell(atColumnIndex: 2, rowIndex: 1).contentView as! NSTextField
        let ethA = grid.cell(atColumnIndex: 1, rowIndex: 2).contentView as! NSTextField
        let ethB = grid.cell(atColumnIndex: 2, rowIndex: 2).contentView as! NSTextField
        let xauA = grid.cell(atColumnIndex: 1, rowIndex: 3).contentView as! NSTextField
        let xauB = grid.cell(atColumnIndex: 2, rowIndex: 3).contentView as! NSTextField

        for tf in [btcA, btcB, ethA, ethB, xauA, xauB] { setup(tf) }

        func s(_ v: Double?) -> String {
            guard let v else { return "" }
            return String(format: "%.4f", v)
        }

        btcA.stringValue = s(current.btcAbove)
        btcB.stringValue = s(current.btcBelow)
        ethA.stringValue = s(current.ethAbove)
        ethB.stringValue = s(current.ethBelow)
        xauA.stringValue = s(current.xauAbove)
        xauB.stringValue = s(current.xauBelow)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
        accessory.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            grid.topAnchor.constraint(equalTo: accessory.topAnchor),
            grid.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        alert.accessoryView = accessory

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        func d(_ s: String) -> Double? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Double(t)
        }

        onSave(AlertSettings(
            btcAbove: d(btcA.stringValue),
            btcBelow: d(btcB.stringValue),
            ethAbove: d(ethA.stringValue),
            ethBelow: d(ethB.stringValue),
            xauAbove: d(xauA.stringValue),
            xauBelow: d(xauB.stringValue)
        ))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
