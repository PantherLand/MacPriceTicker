import Cocoa

// A minimal always-on-top desktop ticker without Xcode project.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSPanel!
    private var view: TickerView!
    private let service = PriceService()
    private let alerts = Alerts()
    private let expandedSize = NSSize(width: 218, height: 206)
    private let collapsedSize = NSSize(width: 44, height: 44)
    private var isCollapsed = false
    private var isTransitioning = false
    private var expandFromCollapsedOffset = NSPoint(x: 0, y: 0)

    private var timer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no dock icon

        view = TickerView(frame: NSRect(origin: .zero, size: expandedSize))
        view.autoresizingMask = [.width, .height]
        view.onMenuRequested = { [weak self] in self?.showMenu() }
        view.onRefreshRequested = { [weak self] in self?.refreshNow() }
        view.onCollapseToggled = { [weak self] collapsed in self?.setCollapsed(collapsed) }

        window = FloatingPanel(contentRect: view.bounds)
        window.contentView = view
        window.center()
        setCollapsed(false, animated: false)
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
                let snap = await self.service.fetchAll(forceRefreshTurnover: false)
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
            let snap = await service.fetchAll(forceRefreshTurnover: true)
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

    private func setCollapsed(_ collapsed: Bool) {
        setCollapsed(collapsed, animated: true)
    }

    private func setCollapsed(_ collapsed: Bool, animated: Bool) {
        if isCollapsed == collapsed || isTransitioning {
            return
        }
        isCollapsed = collapsed
        let target = collapsed ? collapsedSize : expandedSize
        let current = window.frame
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        var newFrame = current
        newFrame.size = targetFrame.size
        if collapsed {
            let expandedOrigin = current.origin
            let anchor = view.collapseAnchorOnScreen()
            let collapsedOrigin: NSPoint
            if let anchor {
                collapsedOrigin = NSPoint(
                    x: anchor.x - targetFrame.size.width / 2,
                    y: anchor.y - targetFrame.size.height / 2
                )
            } else {
                collapsedOrigin = current.origin
            }
            newFrame.origin = collapsedOrigin
            expandFromCollapsedOffset = NSPoint(
                x: expandedOrigin.x - collapsedOrigin.x,
                y: expandedOrigin.y - collapsedOrigin.y
            )
        } else {
            // Expand back to the matching anchor-relative position.
            newFrame.origin = NSPoint(
                x: current.origin.x + expandFromCollapsedOffset.x,
                y: current.origin.y + expandFromCollapsedOffset.y
            )
        }

        if animated {
            isTransitioning = true
            view.prepareTransition(toCollapsed: collapsed)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
                view.animateTransition(toCollapsed: collapsed)
            } completionHandler: { [weak self] in
                guard let self else { return }
                self.view.finishTransition(toCollapsed: collapsed)
                self.isTransitioning = false
            }
        } else {
            window.setFrame(newFrame, display: true, animate: false)
            view.finishTransition(toCollapsed: collapsed)
        }
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
    var onCollapseToggled: ((Bool) -> Void)?

    private let title = NSTextField(labelWithString: "Ticker")
    private let refreshBtn = NSButton(title: "↻", target: nil, action: nil)
    private let collapseBtn = NSButton(title: "—", target: nil, action: nil)
    private let compactIcon = NSTextField(labelWithString: "◎")
    private let btc = NSTextField(labelWithString: "BTC: —")
    private let eth = NSTextField(labelWithString: "ETH: —")
    private let btcTurnover = NSTextField(labelWithString: "BTC 24h Turnover: —")
    private let ethTurnover = NSTextField(labelWithString: "ETH 24h Turnover: —")
    private let xau = NSTextField(labelWithString: "XAU/USD: —")
    private let xag = NSTextField(labelWithString: "XAG/USD: —")
    private let oil = NSTextField(labelWithString: "WTI/USD: —")
    private let updated = NSTextField(labelWithString: "—")

    private let valueColor = NSColor(white: 1, alpha: 1)
    private let loadingColor = NSColor(white: 1, alpha: 0.55)
    private var lastUpdatedAt: Date? = nil

    private var snapshot: PricesSnapshot?
    private var clockTimer: Timer?
    private var contentStack: NSStackView!
    private var contentConstraints: [NSLayoutConstraint] = []
    private let bgLayer = CAGradientLayer()
    private let glowLayer = CALayer()
    private var dragStartWindowOrigin: NSPoint?
    private var dragStartScreenPoint: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        bgLayer.colors = [
            NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.10, alpha: 0.78).cgColor,
            NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.08, alpha: 0.74).cgColor
        ]
        bgLayer.startPoint = CGPoint(x: 0, y: 0)
        bgLayer.endPoint = CGPoint(x: 1, y: 1)
        bgLayer.frame = bounds
        layer?.addSublayer(bgLayer)

        glowLayer.backgroundColor = NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 0.04).cgColor
        glowLayer.frame = bounds.insetBy(dx: -20, dy: -20)
        glowLayer.cornerRadius = 20
        glowLayer.shadowColor = NSColor.systemPink.cgColor
        glowLayer.shadowOpacity = 0.18
        glowLayer.shadowRadius = 18
        glowLayer.shadowOffset = CGSize(width: 0, height: 0)
        layer?.addSublayer(glowLayer)

        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .white
        title.stringValue = "BTC / ETH / Gold / Silver / Oil"

        refreshBtn.bezelStyle = .texturedRounded
        refreshBtn.isBordered = true
        let refreshAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        refreshBtn.attributedTitle = NSAttributedString(string: "↻", attributes: refreshAttrs)
        refreshBtn.attributedAlternateTitle = NSAttributedString(string: "↻", attributes: refreshAttrs)
        refreshBtn.contentTintColor = .white
        refreshBtn.wantsLayer = true
        refreshBtn.layer?.cornerRadius = 8
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshClicked)

        collapseBtn.bezelStyle = .texturedRounded
        collapseBtn.isBordered = true
        collapseBtn.font = .systemFont(ofSize: 13, weight: .bold)
        collapseBtn.contentTintColor = NSColor(white: 1, alpha: 0.9)
        collapseBtn.wantsLayer = true
        collapseBtn.layer?.cornerRadius = 8
        collapseBtn.target = self
        collapseBtn.action = #selector(collapseClicked)

        compactIcon.font = .systemFont(ofSize: 20, weight: .semibold)
        compactIcon.textColor = NSColor(white: 1, alpha: 0.9)
        compactIcon.alignment = .center
        compactIcon.isHidden = true
        compactIcon.translatesAutoresizingMaskIntoConstraints = false

        for l in [btc, eth, xau, xag, oil] {
            l.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            l.textColor = .white
        }

        btcTurnover.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        btcTurnover.textColor = NSColor(calibratedRed: 0.66, green: 0.94, blue: 1.0, alpha: 1.0)
        ethTurnover.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        ethTurnover.textColor = NSColor(calibratedRed: 0.66, green: 0.94, blue: 1.0, alpha: 0.92)

        updated.font = .systemFont(ofSize: 11)
        updated.textColor = NSColor(white: 1, alpha: 0.65)

        let header = NSStackView(views: [title, NSView(), refreshBtn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let footer = NSStackView(views: [updated, NSView(), collapseBtn])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        contentStack = NSStackView(views: [header, btc, eth, btcTurnover, ethTurnover, xau, xag, oil, footer])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        addSubview(compactIcon)

        contentConstraints = [
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ]

        NSLayoutConstraint.activate(contentConstraints + [
            refreshBtn.widthAnchor.constraint(equalToConstant: 30),
            refreshBtn.heightAnchor.constraint(equalToConstant: 24),
            collapseBtn.widthAnchor.constraint(equalToConstant: 30),
            collapseBtn.heightAnchor.constraint(equalToConstant: 24),

            compactIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            compactIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            compactIcon.widthAnchor.constraint(equalToConstant: 24),
            compactIcon.heightAnchor.constraint(equalToConstant: 24)
        ])

        // Live clock (updates every second)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateClock()
        }

        update(snapshot: PricesSnapshot(
            btcUsd: nil,
            ethUsd: nil,
            btcTurnover24h: nil,
            ethTurnover24h: nil,
            xauUsd: nil,
            xagUsd: nil,
            oilUsd: nil,
            updatedAt: Date()
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds
        glowLayer.frame = bounds.insetBy(dx: -20, dy: -20)
    }

    @objc private func refreshClicked() {
        onRefreshRequested?()
    }

    @objc private func collapseClicked() {
        onCollapseToggled?(true)
    }

    func collapseAnchorOnScreen() -> NSPoint? {
        guard let window else { return nil }
        let pInWindow = collapseBtn.convert(
            NSPoint(x: collapseBtn.bounds.midX, y: collapseBtn.bounds.midY),
            to: nil
        )
        return window.convertPoint(toScreen: pInWindow)
    }

    func prepareTransition(toCollapsed collapsed: Bool) {
        if !collapsed {
            if !contentConstraints.isEmpty {
                NSLayoutConstraint.activate(contentConstraints)
            }
            contentStack.isHidden = false
            compactIcon.isHidden = false
            contentStack.alphaValue = 0
            compactIcon.alphaValue = 1
            collapseBtn.isHidden = false
            layer?.cornerRadius = 14
            return
        }

        // Release expanded constraints before shrinking, or Auto Layout can keep the window large.
        NSLayoutConstraint.deactivate(contentConstraints)
        contentStack.isHidden = true
        compactIcon.isHidden = false
        contentStack.alphaValue = 0
        compactIcon.alphaValue = 0
        collapseBtn.isHidden = true
        layer?.cornerRadius = 12
    }

    func animateTransition(toCollapsed collapsed: Bool) {
        if collapsed {
            compactIcon.animator().alphaValue = 1
        } else {
            contentStack.animator().alphaValue = 1
            compactIcon.animator().alphaValue = 0
        }
    }

    func finishTransition(toCollapsed collapsed: Bool) {
        contentStack.isHidden = collapsed
        compactIcon.isHidden = !collapsed
        contentStack.alphaValue = collapsed ? 0 : 1
        compactIcon.alphaValue = collapsed ? 1 : 0
        collapseBtn.isHidden = collapsed
        if !collapsed && !contentConstraints.isEmpty {
            NSLayoutConstraint.activate(contentConstraints)
        }
        layer?.cornerRadius = collapsed ? 12 : 14
        needsLayout = true
    }

    func update(snapshot: PricesSnapshot) {
        self.snapshot = snapshot
        lastUpdatedAt = snapshot.updatedAt

        setLine(label: btc, name: "BTC", value: snapshot.btcUsd)
        setLine(label: eth, name: "ETH", value: snapshot.ethUsd)
        setTurnover(label: btcTurnover, name: "BTC", value: snapshot.btcTurnover24h)
        setTurnover(label: ethTurnover, name: "ETH", value: snapshot.ethTurnover24h)
        setLine(label: xau, name: "XAU/USD", value: snapshot.xauUsd)
        setLine(label: xag, name: "XAG/USD", value: snapshot.xagUsd)
        setLine(label: oil, name: "WTI/USD", value: snapshot.oilUsd)

        updateClock()
    }

    private func setLine(label: NSTextField, name: String, value: Double?) {
        if let v = value {
            label.textColor = valueColor
            label.stringValue = "\(name): \(fmt(v))"
        } else {
            label.textColor = loadingColor
            label.stringValue = "\(name): loading…"
        }
    }

    private func setTurnover(label: NSTextField, name: String, value: Double?) {
        if let v = value {
            label.stringValue = String(format: "\(name) 24h Turnover: %.2f%%", v * 100)
        } else {
            label.stringValue = "\(name) 24h Turnover: loading…"
        }
    }

    private func updateClock() {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"

        let nowStr = df.string(from: Date())
        let updStr = lastUpdatedAt.map { df.string(from: $0) } ?? "—"
        updated.stringValue = "Updated: \(updStr) • Now: \(nowStr)"
    }

    private func fmt(_ v: Double) -> String {
        if v >= 1000 { return String(format: "$%.0f", v) }
        if v >= 100 { return String(format: "$%.2f", v) }
        return String(format: "$%.4f", v)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartWindowOrigin = window.frame.origin
        dragStartScreenPoint = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let startOrigin = dragStartWindowOrigin,
            let startScreen = dragStartScreenPoint
        else { return }

        let now = NSEvent.mouseLocation
        let dx = now.x - startScreen.x
        let dy = now.y - startScreen.y
        if abs(dx) > 1 || abs(dy) > 1 {
            didDrag = true
        }

        window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartWindowOrigin = nil
            dragStartScreenPoint = nil
            didDrag = false
        }

        if contentStack.isHidden && !didDrag {
            onCollapseToggled?(false)
        }
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
            [NSTextField(labelWithString: "XAG/USD"), NSTextField(), NSTextField()],
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
        let xagA = grid.cell(atColumnIndex: 1, rowIndex: 4).contentView as! NSTextField
        let xagB = grid.cell(atColumnIndex: 2, rowIndex: 4).contentView as! NSTextField

        for tf in [btcA, btcB, ethA, ethB, xauA, xauB, xagA, xagB] { setup(tf) }

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
        xagA.stringValue = s(current.xagAbove)
        xagB.stringValue = s(current.xagBelow)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 168))
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
            xauBelow: d(xauB.stringValue),
            xagAbove: d(xagA.stringValue),
            xagBelow: d(xagB.stringValue)
        ))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
