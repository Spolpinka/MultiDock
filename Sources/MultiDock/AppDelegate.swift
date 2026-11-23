import AppKit
import SwiftUI
import Combine
import ServiceManagement

/// Панель, которую система не прижимает обратно к экрану (нужно для автоскрытия за край).
final class DockPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Контейнер на всю панель: принимает перетаскивание приложений напрямую из системного Dock и Finder
/// средствами AppKit (SwiftUI-приёмник не все такие перетаскивания видит).
final class DropContainer: NSView {
    var dockID = UUID()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL,
                                 NSPasteboard.PasteboardType("NSFilenamesPboardType"),
                                 NSPasteboard.PasteboardType("com.apple.dock.extra"),
                                 NSPasteboard.PasteboardType("com.apple.dock.tile")])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func appPaths(_ pb: NSPasteboard) -> [String] {
        var paths: [String] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            paths += urls.map { $0.path }
        }
        if let list = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            paths += list
        }
        var seen = Set<String>()
        return paths.filter { $0.hasSuffix(".app") && seen.insert($0).inserted }
    }

    private func log(_ pb: NSPasteboard, _ found: [String]) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MultiDock")
        let line = "\(Date()) types=\((pb.types ?? []).map(\.rawValue)) apps=\(found)\n"
        if let data = line.data(using: .utf8) {
            let f = dir.appendingPathComponent("drop.log")
            if let h = try? FileHandle(forWritingTo: f) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: f)
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        appPaths(sender.draggingPasteboard).isEmpty ? [] : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        appPaths(sender.draggingPasteboard).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = appPaths(sender.draggingPasteboard)
        log(sender.draggingPasteboard, paths)
        guard !paths.isEmpty else { return false }
        let id = dockID
        Task { @MainActor in
            for p in paths {
                DockStore.shared.drop(path: p, from: nil, onto: id, anchor: nil, after: true)
            }
        }
        return true
    }
}

/// Одна прозрачная панель = один док. Не забирает фокус у приложений.
@MainActor
final class DockPanelController {
    let id: UUID
    let panel: NSPanel
    private let host: NSHostingView<DockView>
    private var lastKey: String?

    // Автоскрытие
    private(set) var autoHide = false
    private var shownFrame = NSRect.zero
    private var hiddenFrame = NSRect.zero
    private var triggerZone = NSRect.zero
    private var revealed = true
    private var leaveSince: Date?

    init(id: UUID) {
        self.id = id
        panel = DockPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        host = NSHostingView(rootView: DockView(dockID: id))
        host.sizingOptions = []
        let container = DropContainer(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.dockID = id
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        panel.orderFrontRegardless()

        DockPanels.panels[id] = panel
    }

    /// `layer` — порядковый номер дока на этом же краю (вторые и следующие сдвигаются вглубь экрана).
    func apply(_ c: DockConfig, layer: Int) {
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let margin: CGFloat = 8
        let size = c.panelSize
        let w = min(size.width, vf.width - 2 * margin)
        let h = min(size.height, vf.height - 2 * margin)
        let across = c.edge.isHorizontal ? h : w
        let inset = margin + CGFloat(layer) * (across + margin)

        // Позиция вдоль края (0...1), чтобы док оставался там, где его оставили.
        let t = CGFloat(min(max(c.anchor, 0), 1))
        let alongX = min(max(vf.minX + t * vf.width - w / 2, vf.minX + margin), vf.maxX - margin - w)
        let alongY = min(max(vf.minY + t * vf.height - h / 2, vf.minY + margin), vf.maxY - margin - h)

        let x: CGFloat
        let y: CGFloat
        switch c.edge {
        case .bottom: x = alongX;                     y = vf.minY + inset
        case .top:    x = alongX;                     y = vf.maxY - h - inset
        case .left:   x = vf.minX + inset;            y = alongY
        case .right:  x = vf.maxX - w - inset;        y = alongY
        }
        let shown = NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
        shownFrame = shown
        autoHide = c.autoHide

        // Куда уезжает док и где мышь его вызывает (весь край экрана вдоль дока).
        let sf = screen.frame
        let band: CGFloat = 3
        switch c.edge {
        case .bottom:
            hiddenFrame = shown.offsetBy(dx: 0, dy: sf.minY - shown.maxY)
            triggerZone = NSRect(x: shown.minX - 20, y: sf.minY, width: w + 40, height: band)
        case .top:
            hiddenFrame = shown.offsetBy(dx: 0, dy: sf.maxY - shown.minY)
            triggerZone = NSRect(x: shown.minX - 20, y: sf.maxY - band, width: w + 40, height: band)
        case .left:
            hiddenFrame = shown.offsetBy(dx: sf.minX - shown.maxX, dy: 0)
            triggerZone = NSRect(x: sf.minX, y: shown.minY - 20, width: band, height: h + 40)
        case .right:
            hiddenFrame = shown.offsetBy(dx: sf.maxX - shown.minX, dy: 0)
            triggerZone = NSRect(x: sf.maxX - band, y: shown.minY - 20, width: band, height: h + 40)
        }
        if autoHide {
            // После перенастройки прячем док сразу, если мышь не рядом.
            let m = NSEvent.mouseLocation
            revealed = shown.insetBy(dx: -12, dy: -12).contains(m) || triggerZone.contains(m)
            panel.setFrame(revealed ? shown : hiddenFrame, display: true)
        } else {
            revealed = true
            panel.setFrame(shown, display: true)
        }

        // Принудительно перестраиваем содержимое при смене стороны/формы/размера,
        // иначе SwiftUI обновляет вид только после следующего события мыши.
        let key = "\(c.edge.rawValue)-\(c.shape.rawValue)-\(c.items.count)-\(c.iconSize)-\(c.inset)"
        if key != lastKey {
            lastKey = key
            host.rootView = DockView(dockID: id)
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    /// Вызывается таймером, пока у какого-либо дока включено автоскрытие.
    func tick(mouse: NSPoint) {
        guard autoHide else { return }
        if revealed {
            let keep = shownFrame.insetBy(dx: -14, dy: -14).contains(mouse) || triggerZone.contains(mouse)
            if keep {
                leaveSince = nil
            } else if NSEvent.pressedMouseButtons != 0 && panel.frame.insetBy(dx: -40, dy: -40).contains(mouse) {
                leaveSince = nil // идёт перетаскивание рядом с доком
            } else if let t = leaveSince {
                if Date().timeIntervalSince(t) > 0.45 { setRevealed(false) }
            } else {
                leaveSince = Date()
            }
        } else if triggerZone.contains(mouse) {
            leaveSince = nil
            setRevealed(true)
        }
    }

    private func setRevealed(_ value: Bool) {
        guard value != revealed else { return }
        revealed = value
        if value { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(value ? shownFrame : hiddenFrame, display: true)
        }
    }

    func close() {
        DockPanels.panels[id] = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [UUID: DockPanelController] = [:]
    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?
    private var hideTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // Обновляем после изменения (а не в момент willSet), чтобы вид видел уже новые данные.
        cancellable = DockStore.shared.$docks.sink { [weak self] _ in
            Task { @MainActor in
                self?.sync(DockStore.shared.docks)
            }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sync(DockStore.shared.docks)
            }
        }
    }

    private func sync(_ allDocks: [DockConfig]) {
        let docks = allDocks.filter { $0.visible }
        let ids = Set(docks.map(\.id))
        for (id, controller) in controllers where !ids.contains(id) {
            controller.close()
            controllers[id] = nil
        }

        var layers: [DockEdge: Int] = [:]
        for d in docks {
            let layer = layers[d.edge, default: 0]
            layers[d.edge] = layer + 1
            if controllers[d.id] == nil {
                controllers[d.id] = DockPanelController(id: d.id)
            }
            controllers[d.id]?.apply(d, layer: layer)
        }
        updateTimer()
    }

    /// Опрашиваем положение мыши только пока есть док с автоскрытием.
    private func updateTimer() {
        let need = controllers.values.contains { $0.autoHide }
        if need, hideTimer == nil {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let m = NSEvent.mouseLocation
                    for c in self.controllers.values { c.tick(mouse: m) }
                }
            }
        } else if !need {
            hideTimer?.invalidate()
            hideTimer = nil
        }
    }

    // MARK: - Иконка в строке меню

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "MultiDock")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Включатели доков по краям экрана — можно держать включёнными сразу несколько.
        let header = NSMenuItem(title: "Показать док:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let docks = DockStore.shared.docks
        for e in DockEdge.allCases {
            let it = NSMenuItem(title: e.title, action: #selector(toggleEdge(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.rawValue
            it.state = docks.contains { $0.edge == e && $0.visible } ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Добавить ещё один пустой док", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for e in DockEdge.allCases {
            let it = NSMenuItem(title: e.title, action: #selector(addDock(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.rawValue
            sub.addItem(it)
        }
        addItem.submenu = sub
        menu.addItem(addItem)

        // Скрытые доки можно вернуть отсюда.
        let hidden = docks.filter { !$0.visible }
        if !hidden.isEmpty {
            let hiddenItem = NSMenuItem(title: "Скрытые доки", action: nil, keyEquivalent: "")
            let hsub = NSMenu()
            for d in hidden {
                let it = NSMenuItem(title: "\(d.edge.title) (\(d.items.count))", action: #selector(showDock(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = d.id.uuidString
                hsub.addItem(it)
            }
            hiddenItem.submenu = hsub
            menu.addItem(hiddenItem)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEdge(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let edge = DockEdge(rawValue: raw) {
            DockStore.shared.toggleEdge(edge)
        }
    }

    @objc private func addDock(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let edge = DockEdge(rawValue: raw) {
            DockStore.shared.addDock(edge: edge)
        }
    }

    @objc private func showDock(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) {
            DockStore.shared.setVisible(true, for: id)
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("MultiDock: launch at login failed: \(error)")
        }
    }
}
