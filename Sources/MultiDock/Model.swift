import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DockEdge: String, Codable, CaseIterable, Identifiable {
    case bottom, left, right, top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Снизу"
        case .left: return "Слева"
        case .right: return "Справа"
        case .top: return "Сверху"
        }
    }

    var isHorizontal: Bool { self == .bottom || self == .top }

    /// Где рисуем точку «приложение запущено» — у внешнего края дока.
    var dotAlignment: Alignment {
        switch self {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }
}

enum DockShape: String, Codable, CaseIterable, Identifiable {
    case rounded, square, oval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rounded: return "Прямоугольник"
        case .square: return "Квадрат"
        case .oval: return "Овал"
        }
    }
}

struct DockConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var edge: DockEdge
    var items: [String]
    var iconSize: Double
    var opacity: Double
    var visible: Bool
    var shape: DockShape
    var borderWidth: Double
    var inset: Double
    /// Позиция вдоль края: 0...1 (0.5 — по центру).
    var anchor: Double
    /// Автоскрытие: док уезжает за край экрана и выезжает при подведении мыши к краю.
    var autoHide: Bool

    init(id: UUID = UUID(), edge: DockEdge, items: [String], iconSize: Double = 48,
         opacity: Double = 0.85, visible: Bool = true, shape: DockShape = .rounded,
         borderWidth: Double = 1, inset: Double = 8, anchor: Double = 0.5, autoHide: Bool = false) {
        self.id = id
        self.edge = edge
        self.items = items
        self.iconSize = iconSize
        self.opacity = opacity
        self.visible = visible
        self.shape = shape
        self.borderWidth = borderWidth
        self.inset = inset
        self.anchor = anchor
        self.autoHide = autoHide
    }

    enum CodingKeys: String, CodingKey {
        case id, edge, items, iconSize, opacity, visible, shape, borderWidth, inset, anchor, autoHide
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        edge = try c.decode(DockEdge.self, forKey: .edge)
        items = try c.decodeIfPresent([String].self, forKey: .items) ?? []
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? 48
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.85
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        shape = try c.decodeIfPresent(DockShape.self, forKey: .shape) ?? .rounded
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 1
        inset = try c.decodeIfPresent(Double.self, forKey: .inset) ?? 8
        anchor = try c.decodeIfPresent(Double.self, forKey: .anchor) ?? 0.5
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide) ?? false
    }

    // MARK: - Геометрия

    var cell: CGFloat { CGFloat(iconSize) + 12 }
    var pad: CGFloat { CGFloat(inset) }

    /// Иконки идут строками (слева направо)? Для вертикальных доков — столбцом.
    var rowMajor: Bool { edge.isHorizontal || shape == .square }

    var grid: (cols: Int, rows: Int) {
        let n = max(items.count, 1)
        if shape == .square {
            let cols = Int(Double(n).squareRoot().rounded(.up))
            let rows = Int((Double(n) / Double(cols)).rounded(.up))
            return (cols, rows)
        }
        return edge.isHorizontal ? (n, 1) : (1, n)
    }

    var panelSize: CGSize {
        let g = grid
        var w = CGFloat(g.cols) * cell + 2 * pad
        var h = CGFloat(g.rows) * cell + 2 * pad
        if shape == .oval {
            if edge.isHorizontal { w += 12 } else { h += 12 }
        }
        return CGSize(width: w, height: h)
    }

    var corner: CGFloat {
        let s = panelSize
        let half = min(s.width, s.height) / 2
        switch shape {
        case .rounded: return min(20, half)
        case .square: return min(12, half)
        case .oval: return half
        }
    }
}

@MainActor
final class DockStore: ObservableObject {
    static let shared = DockStore()

    @Published var docks: [DockConfig] = [] {
        didSet { save() }
    }

    private let url: URL

    static func defaultApps() -> [String] {
        [
            "/System/Library/CoreServices/Finder.app",
            "/Applications/Safari.app",
            "/System/Applications/Notes.app",
            "/System/Applications/System Settings.app"
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MultiDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([DockConfig].self, from: data) {
            docks = saved
        } else {
            docks = [DockConfig(edge: .bottom, items: Self.defaultApps())]
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(docks) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Изменения

    func update(_ id: UUID, _ change: (inout DockConfig) -> Void) {
        guard let i = docks.firstIndex(where: { $0.id == id }) else { return }
        var d = docks[i]
        change(&d)
        docks[i] = d
    }

    /// Новый док наследует стиль (форма, размер иконок, отступ, граница, стекло) первого видимого дока.
    private func makeDock(edge: DockEdge, withItems: Bool) -> DockConfig {
        guard var d = docks.first(where: { $0.visible }) ?? docks.first else {
            return DockConfig(edge: edge, items: withItems ? Self.defaultApps() : [])
        }
        d.id = UUID()
        d.edge = edge
        d.anchor = 0.5
        d.visible = true
        if !withItems { d.items = [] }
        return d
    }

    /// Пустой дополнительный док на выбранном краю (со стилем текущих).
    func addDock(edge: DockEdge) {
        docks.append(makeDock(edge: edge, withItems: false))
    }

    /// Скопировать стиль дока `id` на все остальные доки.
    func applyStyleToAll(from id: UUID) {
        guard let src = docks.first(where: { $0.id == id }) else { return }
        for i in docks.indices where docks[i].id != id {
            docks[i].shape = src.shape
            docks[i].iconSize = src.iconSize
            docks[i].opacity = src.opacity
            docks[i].borderWidth = src.borderWidth
            docks[i].inset = src.inset
            docks[i].autoHide = src.autoHide
        }
    }

    /// Включить/выключить док на краю. Если дока там ещё нет — создать с теми же приложениями, что в первом.
    func toggleEdge(_ edge: DockEdge) {
        let idx = docks.indices.filter { docks[$0].edge == edge }
        if idx.isEmpty {
            docks.append(makeDock(edge: edge, withItems: true))
        } else {
            let show = !idx.contains { docks[$0].visible }
            for i in idx { docks[i].visible = show }
        }
    }

    func removeDock(_ id: UUID) {
        docks.removeAll { $0.id == id }
    }

    func setEdge(_ edge: DockEdge, for id: UUID, anchor: Double = 0.5) {
        update(id) { $0.edge = edge; $0.anchor = anchor }
    }
    func centerDock(_ id: UUID) { update(id) { $0.anchor = 0.5 } }
    func setSize(_ size: Double, for id: UUID) { update(id) { $0.iconSize = size } }
    func setOpacity(_ value: Double, for id: UUID) { update(id) { $0.opacity = value } }
    func setShape(_ shape: DockShape, for id: UUID) { update(id) { $0.shape = shape } }
    func setBorder(_ width: Double, for id: UUID) { update(id) { $0.borderWidth = width } }
    func setInset(_ value: Double, for id: UUID) { update(id) { $0.inset = value } }
    func setVisible(_ value: Bool, for id: UUID) { update(id) { $0.visible = value } }
    func setAutoHide(_ value: Bool, for id: UUID) { update(id) { $0.autoHide = value } }

    /// Добавить в док приложения из системного Dock (те, что там ещё не добавлены).
    func importFromSystemDock(into id: UUID) {
        guard let i = docks.firstIndex(where: { $0.id == id }) else { return }
        var items = docks[i].items
        for path in SystemDock.apps() where !items.contains(path) {
            items.append(path)
        }
        docks[i].items = items
    }

    func remove(path: String, from id: UUID) {
        update(id) { $0.items.removeAll { $0 == path } }
    }

    /// Положить приложение в док `dst`. `src` — откуда его тащили (nil — из Finder/диалога).
    /// `anchor` — иконка, рядом с которой бросили; `after` — вставить после неё.
    func drop(path: String, from src: UUID?, onto dst: UUID, anchor: String?, after: Bool) {
        if anchor == path && (src == nil || src == dst) { return }
        if let src, src != dst { remove(path: path, from: src) }
        guard let i = docks.firstIndex(where: { $0.id == dst }) else { return }
        var items = docks[i].items
        items.removeAll { $0 == path }
        if let anchor, let t = items.firstIndex(of: anchor) {
            items.insert(path, at: after ? t + 1 : t)
        } else {
            items.append(path)
        }
        docks[i].items = items
    }
}

// MARK: - Иконки, запуск, список запущенных

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let img = cache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 128, height: 128)
        cache[path] = img
        return img
    }

    static func name(for path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }
}

@MainActor
enum Launcher {
    static func open(_ path: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg, completionHandler: nil)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func pickApps(for dock: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for u in panel.urls {
                DockStore.shared.drop(path: u.path, from: nil, onto: dock, anchor: nil, after: true)
            }
        }
    }
}

@MainActor
final class RunningApps: ObservableObject {
    static let shared = RunningApps()
    @Published private(set) var paths: Set<String> = []

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func refresh() {
        paths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
    }
}

// MARK: - Перетаскивание самого дока к краю экрана

@MainActor
enum DockPanels {
    static var panels: [UUID: NSPanel] = [:]
    private static var startMouse: NSPoint?
    private static var startOrigin: NSPoint = .zero

    static func dragChanged(_ id: UUID) {
        guard let p = panels[id] else { return }
        let m = NSEvent.mouseLocation
        if startMouse == nil {
            startMouse = m
            startOrigin = p.frame.origin
        }
        guard let s = startMouse else { return }
        p.setFrameOrigin(NSPoint(x: startOrigin.x + m.x - s.x, y: startOrigin.y + m.y - s.y))
    }

    /// Отпустили: док «прилипает» к ближайшему краю и перестраивается (горизонтально/вертикально).
    static func dragEnded(_ id: UUID) {
        startMouse = nil
        guard let p = panels[id], let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let cx = p.frame.midX
        let cy = p.frame.midY
        let tx = Double(min(max((cx - vf.minX) / max(vf.width, 1), 0), 1))
        let ty = Double(min(max((cy - vf.minY) / max(vf.height, 1), 0), 1))
        let distances: [(DockEdge, CGFloat)] = [
            (.bottom, cy - vf.minY),
            (.top, vf.maxY - cy),
            (.left, cx - vf.minX),
            (.right, vf.maxX - cx)
        ]
        let edge = distances.min { $0.1 < $1.1 }?.0 ?? .bottom
        // Запоминаем место вдоль края, где отпустили док.
        DockStore.shared.setEdge(edge, for: id, anchor: edge.isHorizontal ? tx : ty)
    }
}

// MARK: - Приложения системного Dock

enum SystemDock {
    /// Пути приложений, закреплённых в системном Dock.
    static func apps() -> [String] {
        guard let raw = CFPreferencesCopyAppValue("persistent-apps" as CFString,
                                                  "com.apple.dock" as CFString) as? [[String: Any]] else {
            return []
        }
        var result: [String] = []
        for entry in raw {
            guard let tile = entry["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let urlString = file["_CFURLString"] as? String,
                  let url = URL(string: urlString) else { continue }
            let path = url.path
            if path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) {
                result.append(path)
            }
        }
        return result
    }
}

// MARK: - Приём перетаскивания (из Finder, системного Dock или другого дока)

/// Достаёт файловый URL из перетаскиваемого элемента (Finder и системный Dock отдают его по-разному).
private func loadFileURL(_ p: NSItemProvider, completion: @escaping (URL?) -> Void) {
    let type = p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        ? UTType.fileURL.identifier
        : UTType.url.identifier
    p.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
        var url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let u = item as? URL {
            url = u
        } else if let s = item as? String {
            url = URL(string: s)
        }
        if let u = url, u.isFileURL {
            completion((u as NSURL).filePathURL ?? u)
        } else {
            completion(nil)
        }
    }
}

@MainActor
func receiveDrop(_ providers: [NSItemProvider], dock: UUID, anchor: String?, after: Bool) -> Bool {
    var ok = false
    for p in providers {
        let isFile = p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || p.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        if isFile {
            ok = true
            loadFileURL(p) { url in
                guard let url, url.pathExtension.lowercased() == "app" else { return }
                let path = url.path
                Task { @MainActor in
                    DockStore.shared.drop(path: path, from: nil, onto: dock, anchor: anchor, after: after)
                }
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            ok = true
            _ = p.loadObject(ofClass: String.self) { text, _ in
                guard let text, let bar = text.firstIndex(of: "|"),
                      let src = UUID(uuidString: String(text[..<bar])) else { return }
                let path = String(text[text.index(after: bar)...])
                Task { @MainActor in
                    DockStore.shared.drop(path: path, from: src, onto: dock, anchor: anchor, after: after)
                }
            }
        }
    }
    return ok
}
