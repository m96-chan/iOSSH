import MetalKit
import TerminalCore
import UIKit

@MainActor
final class MetalRenderer: NSObject, MTKViewDelegate {
    private struct Instance {
        var rect: SIMD4<Float> = .zero
        var uv: SIMD4<Float> = .zero
        var color: SIMD4<Float> = .zero
    }
    private struct Row {
        var batches: [[Instance]] = Array(repeating: [], count: 6)
        var generation = 0
    }
    private struct Frame {
        var buffer: (any MTLBuffer)?
        var generations: [Int] = []
    }
    private struct ImageTexture {
        var data: Data
        var width: Int
        var height: Int
        var texture: any MTLTexture
    }

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let solid: any MTLRenderPipelineState
    private let glyph: any MTLRenderPipelineState
    private let imagePipeline: any MTLRenderPipelineState
    private let inFlight = DispatchSemaphore(value: 3)
    private var frames = [Frame(), Frame(), Frame()]
    private var frameIndex = 0
    private var rows: [Row] = []
    private var pendingRows = Set<Int>()
    private var blinkingRows = Set<Int>()
    private var imageTextures: [UInt32: ImageTexture] = [:]
    private var configuration: TerminalConfiguration
    private var atlas: GlyphAtlas
    private(set) var snapshot: TerminalSnapshot?
    var cellSize: CGSize { atlas.cellSize }
    var isActive = true
    var hasBlinkingText: Bool { !blinkingRows.isEmpty }
    var cursorVisible = true {
        didSet { if oldValue != cursorVisible { pendingRows.formUnion(blinkingRows) } }
    }
    var selection: ClosedRange<Int>? { didSet { pendingRows.formUnion(rows.indices) } }

    init(device: any MTLDevice, configuration: TerminalConfiguration, scale: CGFloat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderError.commandQueue }
        self.queue = queue
        guard let url = Bundle.module.url(forResource: "Terminal", withExtension: "metal", subdirectory: "Shaders") else {
            throw RenderError.shaderResource
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pipeline(_ fragment: String) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "terminalVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.solid = try pipeline("terminalSolid")
        self.glyph = try pipeline("terminalGlyph")
        self.imagePipeline = try pipeline("terminalImage")
        self.configuration = configuration
        self.atlas = GlyphAtlas(device: device, configuration: configuration, scale: scale)
        super.init()
    }

    func configure(_ configuration: TerminalConfiguration, scale: CGFloat) {
        guard configuration != self.configuration || scale != atlas.scale else { return }
        self.configuration = configuration
        atlas = GlyphAtlas(device: device, configuration: configuration, scale: scale)
        pendingRows.formUnion(rows.indices)
    }

    func purgeCaches() {
        atlas = GlyphAtlas(device: device, configuration: configuration, scale: atlas.scale)
        imageTextures.removeAll()
        frames = [Frame(), Frame(), Frame()]
        pendingRows.formUnion(rows.indices)
    }

    func update(_ value: TerminalSnapshot?) {
        guard let value else {
            snapshot = nil
            rows = []
            pendingRows = []
            blinkingRows = []
            imageTextures = [:]
            return
        }
        let resized = snapshot?.columns != value.columns || snapshot?.rows != value.rows
        let skipped = snapshot.map { value.revision != $0.revision && value.revision != $0.revision &+ 1 } ?? true
        if resized {
            rows = Array(repeating: Row(), count: max(0, value.rows))
            pendingRows = []
            blinkingRows = []
            frames = [Frame(), Frame(), Frame()]
        }
        if resized || skipped || snapshot?.revision == value.revision && snapshot?.cells != value.cells {
            pendingRows.formUnion(rows.indices)
        } else {
            pendingRows.formUnion(value.damageRows.filter { rows.indices.contains($0) })
        }
        if value.columns > 0, value.cells.count >= value.columns * value.rows {
            for row in pendingRows {
                let start = row * value.columns
                let hasBlink = value.cells[start..<(start + value.columns)].contains { $0.attributes.contains(.blink) }
                if hasBlink { blinkingRows.insert(row) } else { blinkingRows.remove(row) }
            }
        }
        snapshot = value
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        pendingRows.formUnion(rows.indices)
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard isActive, view.window != nil, view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else {
            view.setNeedsDisplay()
            return
        }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        command.addCompletedHandler { _ in semaphore.signal() }
        // The acquired drawable can precede a resize of the view. Normalize
        // against the texture being rendered, so glyph pixels keep their size.
        encodeFrame(to: encoder, drawableSize: CGSize(width: drawable.texture.width,
                                                     height: drawable.texture.height))
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// Encodes the same terminal frame into either an MTKView or an offscreen render target.
    /// The caller owns the render pass and must complete each use of a frame buffer before
    /// encoding more than three frames, matching the view's in-flight semaphore.
    /// Draws one frame into a texture that is not a drawable, for the Picture in Picture window
    /// (#39). PiP consumes pixel buffers rather than presenting a drawable, so it needs the same
    /// encoding without `MTKView` around it.
    ///
    /// `isActive` is deliberately not consulted. It is false exactly when the app is not
    /// frontmost, which is when PiP is the only thing drawing — the flag exists to stop GPU work
    /// the system would kill us for, and PiP is the case where the system permits it.
    func render(into texture: any MTLTexture, background: MTLClearColor,
                completion: @escaping @Sendable () -> Void) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        command.addCompletedHandler { _ in
            semaphore.signal()
            completion()
        }
        encodeFrame(to: encoder, drawableSize: CGSize(width: texture.width, height: texture.height))
        encoder.endEncoding()
        command.commit()
    }

    func encodeFrame(to encoder: any MTLRenderCommandEncoder, drawableSize: CGSize) {
        var viewport = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        if let snapshot, snapshot.columns > 0, snapshot.rows > 0,
           snapshot.cells.count >= snapshot.columns * snapshot.rows {
            for row in pendingRows.sorted() { rebuild(row: row, snapshot: snapshot) }
            pendingRows.removeAll(keepingCapacity: true)
            let slot = frameIndex % frames.count
            frameIndex &+= 1
            let columnCapacity = snapshot.columns
            let rowCapacity = columnCapacity * 21
            let stride = MemoryLayout<Instance>.stride
            let byteCount = max(stride, rowCapacity * snapshot.rows * stride)
            if frames[slot].buffer?.length != byteCount {
                frames[slot].buffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
                frames[slot].buffer?.label = "Terminal instances \(slot)"
                frames[slot].generations = Array(repeating: -1, count: rows.count)
            }
            if let buffer = frames[slot].buffer {
                for rowIndex in rows.indices where frames[slot].generations[rowIndex] != rows[rowIndex].generation {
                    for batch in 0..<6 {
                        let offset = (rowIndex * rowCapacity + batch * columnCapacity) * stride
                        rows[rowIndex].batches[batch].withUnsafeBytes { bytes in
                            if let source = bytes.baseAddress, bytes.count > 0 {
                                buffer.contents().advanced(by: offset).copyMemory(from: source, byteCount: bytes.count)
                            }
                        }
                    }
                    frames[slot].generations[rowIndex] = rows[rowIndex].generation
                }
                func drawBatch(_ batch: Int, pipeline: any MTLRenderPipelineState) {
                    encoder.setRenderPipelineState(pipeline)
                    for rowIndex in rows.indices {
                        let count = rows[rowIndex].batches[batch].count
                        guard count > 0 else { continue }
                        encoder.setVertexBuffer(buffer, offset: (rowIndex * rowCapacity + batch * columnCapacity) * stride, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
                    }
                }
                let placements = snapshot.images.sorted {
                    if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
                    if $0.id != $1.id { return $0.id < $1.id }
                    return $0.placementID < $1.placementID
                }
                prepareImageTextures(placements)
                // Kitty's most negative layer sits underneath cell backgrounds.
                drawImages(placements.filter { $0.zIndex < -1_073_741_824 }, encoder: encoder)
                drawBatch(0, pipeline: solid)
                drawImages(placements.filter { $0.zIndex >= -1_073_741_824 && $0.zIndex < 0 }, encoder: encoder)
                for page in atlas.textures.indices {
                    encoder.setFragmentTexture(atlas.textures[page], index: 0)
                    drawBatch(page + 1, pipeline: glyph)
                }
                drawBatch(5, pipeline: solid)
                drawImages(placements.filter { $0.zIndex >= 0 }, encoder: encoder)
                drawCursor(snapshot, encoder: encoder)
            }
        }
    }

    private func rebuild(row: Int, snapshot: TerminalSnapshot) {
        guard rows.indices.contains(row) else { return }
        var batches: [[Instance]] = Array(repeating: [], count: 6)
        let width = Float(atlas.cellSize.width * atlas.scale)
        let height = Float(atlas.cellSize.height * atlas.scale)
        for column in 0..<snapshot.columns {
            let index = row * snapshot.columns + column
            let cell = snapshot.cells[index]
            let rect = SIMD4(Float(column) * width, Float(row) * height, width, height)
            let background = selection?.contains(index) == true ? configuration.theme.selection.linearColor : cell.background.linearColor
            // Default backgrounds are supplied by the clear color. Leaving those cells
            // transparent here preserves Kitty placements beneath non-default backgrounds.
            if selection?.contains(index) == true || cell.background != snapshot.defaultBackground {
                batches[0].append(Instance(rect: rect, color: background))
            }
            guard cell.width > 0, !cell.attributes.contains(.invisible) else { continue }
            if cell.attributes.contains(.blink) && !cursorVisible { continue }
            var foreground = cell.foreground.linearColor
            if cell.attributes.contains(.dim) {
                foreground.x *= 0.5; foreground.y *= 0.5; foreground.z *= 0.5
            }
            if let entry = atlas.glyph(text: cell.text, width: cell.width, bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic)) {
                var color = foreground
                if entry.isColor { color.w = -1 }
                batches[entry.page + 1].append(Instance(rect: SIMD4(rect.x, rect.y, entry.size.x, entry.size.y), uv: entry.uv, color: color))
            }
            let decoration = cell.underlineColor?.linearColor ?? foreground
            let thickness = max(1, Float(atlas.scale))
            let lineWidth = width * Float(max(1, cell.width))
            func line(_ x: Float, _ y: Float, _ w: Float, _ h: Float = 0) {
                batches[5].append(Instance(rect: SIMD4(x, y, w, h == 0 ? thickness : h), color: decoration))
            }
            let underline = cell.underlineStyle == .none && cell.attributes.contains(.underline) ? TerminalUnderlineStyle.single : cell.underlineStyle
            let baseline = rect.y + height - thickness * 2
            switch underline {
            case .none: break
            case .single: line(rect.x, baseline, lineWidth)
            case .double:
                line(rect.x, baseline, lineWidth)
                line(rect.x, baseline - thickness * 2, lineWidth)
            case .curly:
                let segment = lineWidth / 8
                for n in 0..<8 {
                    line(rect.x + Float(n) * segment, baseline - (n % 4 < 2 ? thickness : 0), segment)
                }
            case .dotted, .dashed:
                let count = underline == .dotted ? 4 : 2
                let segment = lineWidth / Float(count * 2)
                for n in 0..<count { line(rect.x + Float(n * 2) * segment, baseline, segment) }
            }
            if cell.attributes.contains(.strikethrough) { line(rect.x, rect.y + height * 0.53, lineWidth) }
        }
        rows[row].batches = batches
        rows[row].generation &+= 1
    }

    private func drawCursor(_ snapshot: TerminalSnapshot, encoder: any MTLRenderCommandEncoder) {
        let cursor = snapshot.cursor
        guard cursor.visible, cursorVisible || !cursor.blinking || !configuration.cursorBlinks,
              cursor.row >= 0, cursor.row < snapshot.rows, cursor.column >= 0, cursor.column < snapshot.columns,
              snapshot.scrollbackOffset == 0 else { return }
        let width = Float(atlas.cellSize.width * atlas.scale)
        let height = Float(atlas.cellSize.height * atlas.scale)
        var rect = SIMD4(Float(cursor.column) * width, Float(cursor.row) * height, width, height)
        var color = configuration.theme.cursor.linearColor
        switch cursor.style {
        case .block:
            color *= 0.45
        case .bar: rect.z = max(1, Float(atlas.scale) * 2)
        case .underline:
            rect.y += height - max(1, Float(atlas.scale) * 2)
            rect.w = max(1, Float(atlas.scale) * 2)
        }
        var instance = Instance(rect: rect, color: color)
        encoder.setRenderPipelineState(solid)
        encoder.setVertexBytes(&instance, length: MemoryLayout<Instance>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
    }

    private func drawImages(_ placements: [TerminalImagePlacement], encoder: any MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(imagePipeline)
        let cellWidth = Float(atlas.cellSize.width * atlas.scale)
        let cellHeight = Float(atlas.cellSize.height * atlas.scale)
        for placement in placements {
            guard let texture = imageTextures[placement.id]?.texture else { continue }
            let imageWidth = (placement.columns > 0 ? Float(placement.columns) * cellWidth : Float(placement.pixelWidth)) * Float(placement.widthFraction)
            let imageHeight = (placement.rows > 0 ? Float(placement.rows) * cellHeight : Float(placement.pixelHeight)) * Float(placement.heightFraction)
            var instance = Instance(rect: SIMD4(Float(placement.column) * cellWidth + Float(placement.offsetX),
                Float(placement.row) * cellHeight + Float(placement.offsetY), imageWidth, imageHeight),
                uv: SIMD4(Float(placement.sourceX), Float(placement.sourceY), Float(placement.sourceWidth), Float(placement.sourceHeight)),
                color: SIMD4(repeating: 1))
            encoder.setVertexBytes(&instance, length: MemoryLayout<Instance>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        }
    }

    private func prepareImageTextures(_ placements: [TerminalImagePlacement]) {
        let liveIDs = Set(placements.map(\.id))
        imageTextures = imageTextures.filter { liveIDs.contains($0.key) }
        var visited = Set<UInt32>()
        var byteCount = 0
        for placement in placements {
            guard visited.insert(placement.id).inserted else { continue }
            guard placement.pixelWidth > 0, placement.pixelHeight > 0,
                  placement.pixelWidth <= 8192, placement.pixelHeight <= 8192,
                  placement.rgba.count == placement.pixelWidth * placement.pixelHeight * 4 else { continue }
            byteCount += placement.rgba.count
            guard byteCount <= 128 * 1024 * 1024 else {
                imageTextures.removeValue(forKey: placement.id)
                continue
            }
            let cached = imageTextures[placement.id]
            if cached?.data != placement.rgba || cached?.width != placement.pixelWidth || cached?.height != placement.pixelHeight {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                    width: placement.pixelWidth, height: placement.pixelHeight, mipmapped: false)
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: descriptor) else { continue }
                placement.rgba.withUnsafeBytes { bytes in
                    texture.replace(region: MTLRegionMake2D(0, 0, placement.pixelWidth, placement.pixelHeight), mipmapLevel: 0,
                                    withBytes: bytes.baseAddress!, bytesPerRow: placement.pixelWidth * 4)
                }
                imageTextures[placement.id] = ImageTexture(data: placement.rgba, width: placement.pixelWidth, height: placement.pixelHeight, texture: texture)
            }
        }
    }

    enum RenderError: Error { case commandQueue, shaderResource }
}

extension TerminalColor {
    var linearColor: SIMD4<Float> {
        var result = (UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)).linearColor
        let opacity = Float(alpha) / 255
        result *= opacity
        return result
    }
}

extension TerminalTheme {
    public var coreForeground: TerminalColor { foreground.coreColor }
    public var coreBackground: TerminalColor { background.coreColor }
    public var corePalette: [TerminalColor] { ansi.map(\.coreColor) }
}

private extension UInt32 {
    var coreColor: TerminalColor {
        TerminalColor(red: UInt8((self >> 16) & 255), green: UInt8((self >> 8) & 255), blue: UInt8(self & 255))
    }
}

