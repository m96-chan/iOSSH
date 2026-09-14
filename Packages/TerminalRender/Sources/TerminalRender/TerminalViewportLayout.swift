import CoreGraphics

/// All rectangles use the terminal view's coordinates. Intersecting absolute edges
/// avoids deducting keyboard height a second time after SwiftUI adjusts its safe area.
enum TerminalViewportLayout {
    static func visibleBounds(in bounds: CGRect, safeAreaBottom: CGFloat,
                              keyboardFrame: CGRect?, accessoryFrame: CGRect?) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let tolerance: CGFloat = 1
        let safeBottom = max(bounds.minY, bounds.maxY - max(0, safeAreaBottom))
        var bottom = safeBottom
        if let keyboardFrame, !keyboardFrame.isNull, keyboardFrame.width > 0,
           keyboardFrame.maxY >= bounds.maxY - tolerance {
            bottom = min(bottom, max(bounds.minY, min(bounds.maxY, keyboardFrame.minY)))
        }
        if let accessoryFrame, !accessoryFrame.isNull, accessoryFrame.height > 0,
           accessoryFrame.minX <= bounds.minX + tolerance,
           accessoryFrame.maxX >= bounds.maxX - tolerance,
           accessoryFrame.maxY > bounds.minY {
            // A live full-width accessory is authoritative even while the keyboard
            // guide catches up after foregrounding. Narrow floating keyboards leave
            // the grid alone; full-width undocked bars still obscure complete rows.
            let accessoryTop = max(bounds.minY, min(bounds.maxY, accessoryFrame.minY))
            if let keyboardFrame, !keyboardFrame.isNull, keyboardFrame.width > 0,
               accessoryFrame.maxY >= keyboardFrame.maxY - tolerance,
               accessoryFrame.minY >= keyboardFrame.minY {
                // The accessory fills the bottom of the keyboard region, so that region is
                // the bar plus the inset beneath it and only the bar obscures a row. Taking
                // the guide's top instead would surrender that inset, a whole row on an iPad
                // with a hardware keyboard attached (#14).
                bottom = min(safeBottom, accessoryTop)
            } else {
                bottom = min(bottom, accessoryTop)
            }
        }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bottom - bounds.minY)
    }

    static func gridSize(in viewport: CGRect, cellSize: CGSize) -> CGSize? {
        guard viewport.width > 0, viewport.height > 0, cellSize.width > 0, cellSize.height > 0 else { return nil }
        return CGSize(width: max(2, floor(viewport.width / cellSize.width)),
                      height: max(1, floor(viewport.height / cellSize.height)))
    }
}
