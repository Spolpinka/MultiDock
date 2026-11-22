import AppKit
import SwiftUI
import Combine
import ServiceManagement

/// Одна прозрачная панель = один док. Не забирает фокус у приложений.
@MainActor
final class DockPanelController {
    let id: UUID
    let panel: NSPanel
    private let host: NSHostingView<DockView>
    private var lastKey: String?

    init(id: UUID) {
        self.id = id
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
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
        panel.contentView = host
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
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h), display: true)

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
