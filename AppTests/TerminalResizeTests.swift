import MetalKit
import TerminalCore
import UIKit
import XCTest
@testable import TerminalRender

final class TerminalResizeTests: XCTestCase {
    @MainActor
    func testIdleTerminalRedrawsAtNativeResolutionWhenKeyboardChangesItsHeight() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let terminal = TerminalMetalView(configuration: .init(fontSize: 16, cursorBlinks: false))
        let renderer = try XCTUnwrap(terminal.delegate)
        let observer = ResizeDrawObserver(forwarding: renderer)
        terminal.delegate = observer
        var cellPublications: [CGSize] = []
        var gridPublications: [CGSize] = []
        terminal.onCellSize = { cellPublications.append(CGSize(width: $0, height: $1)) }
        terminal.onResize = { gridPublications.append(CGSize(width: $0, height: $1)) }
        controller.view.addSubview(terminal)
        defer {
            terminal.stop()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        let height = min(600, controller.view.bounds.height - 80)
        XCTAssertGreaterThan(height, 240)
        terminal.frame = CGRect(x: 20, y: 40, width: 300, height: height)
        terminal.layoutIfNeeded()
        try await waitUntil("The first viewport should be drawn and measured") {
            !observer.frames.isEmpty && !cellPublications.isEmpty && !gridPublications.isEmpty
        }
        let originalCellPixels = try XCTUnwrap(cellPublications.first)
        let idleSnapshot = await onParser { () -> TerminalSnapshot in
            let engine = SwiftTermEngine(columns: 20, rows: 3)
            engine.feed(Data("\u{1b}[?25l日本語 >_\r\nfixed-size cells".utf8))
            return engine.snapshot()
        }

        // The resize must repaint even before a connection has a snapshot, and
        // again when an idle shell sends no new revision or PTY acknowledgement.
        for snapshot in [nil, idleSnapshot] {
            terminal.update(snapshot)
            try await Task.sleep(for: .milliseconds(40))
            for nextHeight in [height - 200, height, height + 1, height] {
                let previousDrawCount = observer.frames.count
                terminal.frame.size.height = nextHeight
                terminal.layoutIfNeeded()
                let expected = CGSize(width: 300 * window.screen.scale,
                                      height: nextHeight * window.screen.scale)
                XCTAssertEqual(terminal.drawableSize, expected,
                               "Layout must synchronize the paused drawable before presenting it")
                try await waitUntil("A height change must draw without output or a blinking cursor") {
                    observer.frames.dropFirst(previousDrawCount).contains {
                        $0.bounds.height == nextHeight && $0.drawable == expected
                    }
                }
                XCTAssertTrue(terminal.isPaused)
                XCTAssertEqual(terminal.contentScaleFactor, window.screen.scale)
                XCTAssertTrue(cellPublications.allSatisfy { $0 == originalCellPixels },
                              "Keyboard geometry must never scale terminal cells")
            }
        }
        XCTAssertGreaterThan(Set(gridPublications.map(\.height)).count, 1,
                             "Extra room changes the row count, not the font size")
    }

    @MainActor
    func testKeyboardSizedRenderTargetsKeepEveryExistingGlyphPixelUnstretched() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scale: CGFloat = 3
        let renderer = try MetalRenderer(device: device, configuration: .init(fontSize: 16, cursorBlinks: false), scale: scale)
        let fixture = await onParser { () -> TerminalSnapshot in
            let engine = SwiftTermEngine(columns: 20, rows: 4)
            engine.setColors(foreground: .init(red: 255, green: 255, blue: 255),
                             background: .init(red: 0, green: 0, blue: 0),
                             palette: Array(repeating: .init(red: 255, green: 255, blue: 255), count: 16))
            engine.feed(Data("\u{1b}[?25l日本語 >_\r\nHackGen 123\r\n┌───┐".utf8))
            return engine.snapshot()
        }
        renderer.update(fixture)
        let cellSize = renderer.cellSize
        let reference = try render(renderer, device: device, width: 900, height: 900)
        XCTAssertTrue(reference.contains { $0 != 0 && $0 != 255 }, "The fixture must contain antialiased glyphs")

        // Read actual GPU output, including Japanese, symbols, blank rows, and
        // all three reusable instance buffers. The expected crop is the original
        // raster, independent of any resized viewport/grid calculation.
        for height in [1_800, 900, 1_803, 900, 1_800] {
            let output = try render(renderer, device: device, width: 900, height: height)
            let differingChannels = zip(output.prefix(reference.count), reference).filter {
                abs(Int($0.0) - Int($0.1)) > 2
            }.count
            XCTAssertEqual(differingChannels, 0,
                           "Changing the terminal height must reveal rows without stretching existing pixels")
            XCTAssertEqual(renderer.cellSize, cellSize)
        }
    }

    @MainActor
    private func waitUntil(_ description: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(description)
                throw ResizeWaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func render(_ renderer: MetalRenderer, device: any MTLDevice, width: Int, height: Int) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        renderer.encodeFrame(to: encoder, drawableSize: CGSize(width: width, height: height))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    private enum ResizeWaitError: Error { case timedOut }
}

@MainActor
private final class ResizeDrawObserver: NSObject, MTKViewDelegate {
    struct Frame {
        var bounds: CGRect
        var drawable: CGSize
    }
    private let forwarding: any MTKViewDelegate
    private(set) var frames: [Frame] = []

    init(forwarding: any MTKViewDelegate) { self.forwarding = forwarding }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        forwarding.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        frames.append(.init(bounds: view.bounds, drawable: view.drawableSize))
        forwarding.draw(in: view)
    }
}
