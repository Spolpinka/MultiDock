import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Простое наблюдаемое значение вместо @State (макрос @State недоступен без полного Xcode).
final class Flag: ObservableObject {
    @Published var value = false
}

/// Размытие, которое не перехватывает мышь (события идут в SwiftUI-слой поверх).
final class GlassView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Матовое «стекло» с размытием того, что за окном.
struct VisualEffect: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> GlassView {
        let v = GlassView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = Self.mask(radius)
        return v
    }

    func updateNSView(_ v: GlassView, context: Context) {
        v.maskImage = Self.mask(radius)
    }

    private static func mask(_ r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

struct DockView: View {
    let dockID: UUID
    @ObservedObject private var store = DockStore.shared
    @ObservedObject private var running = RunningApps.shared
    @StateObject private var targeted = Flag()

    var body: some View {
        if let c = store.docks.first(where: { $0.id == dockID }) {
            content(c)
                .id("\(c.edge.rawValue)-\(c.shape.rawValue)")
                .padding(c.pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(glass(c))
                .overlay(
                    RoundedRectangle(cornerRadius: c.corner, style: .continuous)
                        .strokeBorder(targeted.value ? Color.accentColor : Color.white.opacity(0.28),
                                      lineWidth: targeted.value ? max(2, c.borderWidth) : c.borderWidth)
                        .allowsHitTesting(false)
                )
                .onDrop(of: [.fileURL, .url, .plainText],
                        isTargeted: Binding(get: { targeted.value }, set: { targeted.value = $0 })) { providers in
                    receiveDrop(providers, dock: dockID, anchor: nil, after: true)
                }
                .contextMenu { menu(c) }
        }
    }

    struct Option {
        let title: String
        let value: Double
    }

    static let borderOptions = [
        Option(title: "Нет", value: 0), Option(title: "Тонкая", value: 1),
        Option(title: "Средняя", value: 2), Option(title: "Толстая", value: 4)
    ]
    static let insetOptions = [
        Option(title: "Компактный", value: 3), Option(title: "Обычный", value: 8),
        Option(title: "Просторный", value: 14), Option(title: "Широкий", value: 22)
    ]

    // MARK: - Содержимое

    @ViewBuilder
    private func content(_ c: DockConfig) -> some View {
        if c.items.isEmpty {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: c.cell, height: c.cell)
        } else if c.shape == .square {
            let cols = c.grid.cols
            let rows = stride(from: 0, to: c.items.count, by: cols).map {
                Array(c.items[$0 ..< min($0 + cols, c.items.count)])
            }
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(rows[r], id: \.self) { path in icon(path, c) }
                    }
                }
            }
        } else if c.edge.isHorizontal {
            HStack(spacing: 0) {
                ForEach(c.items, id: \.self) { path in icon(path, c) }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(c.items, id: \.self) { path in icon(path, c) }
            }
        }
    }

    private func icon(_ path: String, _ c: DockConfig) -> some View {
        DockIcon(path: path, dockID: dockID, config: c, isRunning: running.paths.contains(path))
    }

    private func glass(_ c: DockConfig) -> some View {
        ZStack {
            VisualEffect(radius: c.corner).opacity(c.opacity)
            RoundedRectangle(cornerRadius: c.corner, style: .continuous)
                .fill(Color.white.opacity(0.05))
            // Слой для перетаскивания всего дока за свободное место (рамку/отступы).
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { _ in DockPanels.dragChanged(dockID) }
                        .onEnded { _ in DockPanels.dragEnded(dockID) }
                )
        }
    }

    // MARK: - Меню дока (правый клик по фону)

    @ViewBuilder
    private func menu(_ c: DockConfig) -> some View {
        Button("Добавить приложение…") { Launcher.pickApps(for: dockID) }
        Button("Добавить приложения из системного дока") { store.importFromSystemDock(into: dockID) }
        Button("Автоскрытие" + (c.autoHide ? "  ✓" : "")) { store.setAutoHide(!c.autoHide, for: dockID) }

        Button("Вернуть в центр края") { store.centerDock(dockID) }
        Menu("Форма") {
            ForEach(DockShape.allCases) { s in
                Button(s.title + (c.shape == s ? "  ✓" : "")) { store.setShape(s, for: dockID) }
            }
        }
        Menu("Граница") {
            ForEach(Self.borderOptions.indices, id: \.self) { i in
                let o = Self.borderOptions[i]
                Button(o.title + (c.borderWidth == o.value ? "  ✓" : "")) { store.setBorder(o.value, for: dockID) }
            }
        }
        Menu("Отступ внутри") {
            ForEach(Self.insetOptions.indices, id: \.self) { i in
                let o = Self.insetOptions[i]
                Button(o.title + (c.inset == o.value ? "  ✓" : "")) { store.setInset(o.value, for: dockID) }
            }
        }
        Menu("Размер иконок") {
            ForEach([32, 40, 48, 56, 64, 72], id: \.self) { s in
                Button("\(s)" + (Int(c.iconSize) == s ? "  ✓" : "")) { store.setSize(Double(s), for: dockID) }
            }
        }
        Menu("Плотность стекла") {
            ForEach([20, 40, 60, 80, 100], id: \.self) { p in
                Button("\(p)%" + (Int((c.opacity * 100).rounded()) == p ? "  ✓" : "")) {
                    store.setOpacity(Double(p) / 100, for: dockID)
                }
            }
        }
        Divider()
        Menu("Доки по краям экрана") {
            ForEach(DockEdge.allCases) { e in
                let on = store.docks.contains { $0.edge == e && $0.visible }
                Button(e.title + (on ? "  ✓" : "")) { store.toggleEdge(e) }
            }
        }
        Button("Применить этот стиль ко всем докам") { store.applyStyleToAll(from: dockID) }
        Button("Скрыть док") { store.setVisible(false, for: dockID) }
        Button("Удалить док") { store.removeDock(dockID) }
        Divider()
        Button("Выйти из MultiDock") { NSApp.terminate(nil) }
        Button("Сборка 5") {}.disabled(true)
    }
}

@MainActor
struct IconDropDelegate: DropDelegate {
    let dockID: UUID
    let path: String
    let rowMajor: Bool
    let cell: CGFloat

    func performDrop(info: DropInfo) -> Bool {
        let pos = rowMajor ? info.location.x : info.location.y
        return receiveDrop(info.itemProviders(for: [.fileURL, .url, .plainText]),
                           dock: dockID, anchor: path, after: pos > cell / 2)
    }
}

struct DockIcon: View {
    let path: String
    let dockID: UUID
    let config: DockConfig
    let isRunning: Bool
    @StateObject private var hover = Flag()

    var body: some View {
        let size = CGFloat(config.iconSize)
        ZStack {
            Image(nsImage: Icons.icon(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .scaleEffect(hover.value ? 1.12 : 1.0)
                .animation(.easeOut(duration: 0.12), value: hover.value)

            if isRunning {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 4, height: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: config.edge.dotAlignment)
                    .padding(1)
            }
        }
        .frame(width: config.cell, height: config.cell)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .onTapGesture { Launcher.open(path) }
        .help(Icons.name(for: path))
        .onDrag { NSItemProvider(object: "\(dockID.uuidString)|\(path)" as NSString) }
        .onDrop(of: [.fileURL, .url, .plainText],
                delegate: IconDropDelegate(dockID: dockID, path: path,
                                           rowMajor: config.rowMajor, cell: config.cell))
        .contextMenu {
            Button("Показать в Finder") { Launcher.reveal(path) }
            Button("Убрать из дока") { DockStore.shared.remove(path: path, from: dockID) }
        }
    }
}
