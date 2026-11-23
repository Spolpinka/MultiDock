# MultiDock

**Multiple translucent docks for macOS — on any screen edge, at the same time.**

macOS gives you one Dock on one edge. MultiDock adds as many extra docks as you like — left, right, top, bottom — each with its own apps, shape and style. Your system Dock stays untouched.

*[Русская версия](README.ru.md)*

<!-- Add a screenshot or GIF here: docs/demo.gif -->

## Features

- **Auto-hide** per dock: slides off the screen edge and returns when the mouse touches the edge.
- Import apps from the system Dock (right-click menu) or drag them in.
- Several docks on different screen edges **at once**
- Frosted-glass look with adjustable transparency
- Shapes: rectangle, square (grid) or oval
- Adjustable icon size, inner padding and border
- Drag a dock with the mouse — it snaps to the nearest edge, rebuilds itself horizontally or vertically, and **remembers where you left it** along the edge
- Drag apps in from Finder or Applications; reorder icons or move them between docks
- Running-app indicator, "reveal in Finder", launch at login
- Lightweight native Swift/SwiftUI app, no Xcode required to build

## Install

**Download:** grab `MultiDock.zip` from [Releases](../../releases), unzip it and move `MultiDock.app` to Applications.

The app is not notarized, so on first launch macOS may block it. Either right-click the app → **Open**, or run:

```
xattr -dr com.apple.quarantine /Applications/MultiDock.app
```

**Build from source** (only Command Line Tools are needed):

```
xcode-select --install   # if not installed yet
git clone https://github.com/Spolpinka/MultiDock.git
cd MultiDock
bash build.sh
open MultiDock.app
```

Requires macOS 13 or newer.

## Usage

- Right-click the dock background → **Docks on screen edges** to toggle docks on the bottom / left / right / top. A new dock copies the style of the first visible one.
- Drag a dock by its free border area to move it to another edge.
- Right-click the dock background for: add app, return to edge center, shape, border, padding, icon size, glass density, apply style to all docks, hide, delete, quit.
- Right-click an icon: reveal in Finder / remove from dock.
- The same toggles are in the menu bar icon.
- Settings are stored in `~/Library/Application Support/MultiDock/config.json`.

## License

MIT, see [LICENSE](LICENSE).
