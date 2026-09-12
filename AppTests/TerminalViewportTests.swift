import CoreGraphics
import Testing
@testable import TerminalRender

struct TerminalViewportTests {
    private let cell = CGSize(width: 10, height: 20)

    @Test
    func accessoryIsExcludedWhenSwiftUIOnlyAvoidsTheKeyboard() throws {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 600)
        let accessory = CGRect(x: 0, y: 356, width: 390, height: 44)
        let visible = TerminalViewportLayout.visibleBounds(in: bounds, safeAreaBottom: 0,
            keyboardFrame: CGRect(x: 0, y: 400, width: 390, height: 200), accessoryFrame: accessory)
        let grid = try #require(TerminalViewportLayout.gridSize(in: visible, cellSize: cell))
        #expect(visible.height == 356)
        #expect(grid.height == 17)
        #expect(grid.height * cell.height <= accessory.minY)
    }

    @Test
    func keyboardAndAccessoryAreNotSubtractedAgainAfterSwiftUIResizes() throws {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 356)
        let visible = TerminalViewportLayout.visibleBounds(in: bounds, safeAreaBottom: 0,
            keyboardFrame: CGRect(x: 0, y: 356, width: 390, height: 0),
            accessoryFrame: CGRect(x: 0, y: 356, width: 390, height: 44))
        #expect(visible == bounds)
        #expect(try #require(TerminalViewportLayout.gridSize(in: visible, cellSize: cell)).height == 17)
    }

    @Test
    func restoredAccessoryWinsBeforeKeyboardGuideAndSafeAreaCatchUp() throws {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 744)
        let accessory = CGRect(x: 0, y: 400, width: 390, height: 44)
        let restored = TerminalViewportLayout.visibleBounds(in: bounds, safeAreaBottom: 34,
            keyboardFrame: CGRect(x: 0, y: 710, width: 390, height: 34), accessoryFrame: accessory)
        #expect(restored.height == 400)
        #expect(try #require(TerminalViewportLayout.gridSize(in: restored, cellSize: cell)).height == 20)

        // A reconnect banner changes the terminal origin and height, while the
        // accessory stays in its keyboard window. Its converted edge moves with it.
        let reconnected = TerminalViewportLayout.visibleBounds(
            in: CGRect(x: 0, y: 0, width: 390, height: 680), safeAreaBottom: 34,
            keyboardFrame: CGRect(x: 0, y: 646, width: 390, height: 34),
            accessoryFrame: accessory.offsetBy(dx: 0, dy: -64))
        let grid = try #require(TerminalViewportLayout.gridSize(in: reconnected, cellSize: cell))
        #expect(reconnected.height == 336)
        #expect(grid.height * cell.height <= 336)
    }

    @Test
    func hardwareKeyboardAccessoryAndDismissalUseTheirActualEdges() throws {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 744)
        let accessory = CGRect(x: 0, y: 666, width: 390, height: 44)
        let visible = TerminalViewportLayout.visibleBounds(in: bounds, safeAreaBottom: 34,
            keyboardFrame: CGRect(x: 0, y: 710, width: 390, height: 34), accessoryFrame: accessory)
        #expect(visible.height == 666)
        #expect(try #require(TerminalViewportLayout.gridSize(in: visible, cellSize: cell)).height == 33)

        let dismissed = TerminalViewportLayout.visibleBounds(in: bounds, safeAreaBottom: 34,
            keyboardFrame: CGRect(x: 0, y: 710, width: 390, height: 34), accessoryFrame: nil)
        #expect(dismissed.height == 710)
    }

    @Test
    func narrowFloatingKeyboardDoesNotShrinkTheEntireGrid() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let visible = TerminalViewportLayout.visibleBounds(in: bounds, safeAreaBottom: 20,
            keyboardFrame: CGRect(x: 0, y: 580, width: 800, height: 20),
            accessoryFrame: CGRect(x: 300, y: 250, width: 320, height: 44))
        #expect(visible.height == 580)
    }

    @Test
    func rotationAndFullWidthUndockedAccessoryKeepLastRowAboveTheBar() throws {
        let accessory = CGRect(x: 0, y: 150, width: 744, height: 44)
        let visible = TerminalViewportLayout.visibleBounds(
            in: CGRect(x: 0, y: 0, width: 744, height: 300), safeAreaBottom: 20,
            keyboardFrame: CGRect(x: 0, y: 280, width: 744, height: 20), accessoryFrame: accessory)
        let grid = try #require(TerminalViewportLayout.gridSize(in: visible, cellSize: cell))
        #expect(grid.width == 74)
        #expect(grid.height == 7)
        #expect(grid.height * cell.height <= accessory.minY)
    }
}
