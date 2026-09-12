import Foundation
import CoreGraphics
import ImageIO

public struct TerminalImageLimits: Sendable {
    public let maximumImageBytes, maximumTotalBytes, maximumImages, maximumPlacements, maximumDimension: Int
    public static let `default` = Self()
    public init(maximumImageBytes: Int = 16 * 1024 * 1024, maximumTotalBytes: Int = 64 * 1024 * 1024,
                maximumImages: Int = 64, maximumPlacements: Int = 256, maximumDimension: Int = 4096) {
        self.maximumImageBytes = min(64 * 1024 * 1024, max(4, maximumImageBytes))
        self.maximumTotalBytes = min(256 * 1024 * 1024, max(4, maximumTotalBytes))
        self.maximumImages = min(1024, max(1, maximumImages))
        self.maximumPlacements = min(4096, max(1, maximumPlacements))
        self.maximumDimension = min(8192, max(1, maximumDimension))
    }
}

struct KittyGraphicsContext {
    let column, row, liveTop, trimmed, columns, rows, cellWidth, cellHeight: Int
    let alternate: Bool
}

/// Direct transfers only. No file, shared-memory, compression or animation
/// paths are delegated to SwiftTerm's broader implementation.
@MainActor final class KittyGraphicsStore {
    private struct Image {
        let data: Data
        let width, height: Int
        var tick: UInt64
    }
    private struct Placement {
        let imageID, placementID: UInt32
        let column, columns, offsetX, offsetY, zIndex: Int
        var absoluteRow, rows: Int
        var sourceY: Double = 0
        var sourceHeight: Double = 1
        let alternate: Bool
        let virtual: Bool
    }
    private struct Transfer {
        let control: [String: String]
        var bytes: Data
    }
    private let limits: TerminalImageLimits
    private var images: [UInt32: Image] = [:]
    private var imageNumbers: [UInt32: UInt32] = [:]
    private var placements: [Placement] = []
    private var pending: Transfer?
    private var discardContinuation = false
    private var totalBytes = 0
    private var sequence: UInt32 = 0
    private var tick: UInt64 = 0

    init(limits: TerminalImageLimits) { self.limits = limits }
    func reset() { images.removeAll(); imageNumbers.removeAll(); placements.removeAll(); pending = nil; totalBytes = 0; discardContinuation = false }
    func clearPlacements() { placements.removeAll { !$0.virtual } }
    func clearAlternatePlacements() { placements.removeAll { $0.alternate && !$0.virtual } }
    func scrollRegion(top: Int, bottom: Int, context: KittyGraphicsContext) {
        guard top > 0 else { return } // Full-screen scrolling uses the absolute anchor in both buffers.
        for index in placements.indices {
            let placement = placements[index]
            let row = placement.absoluteRow - context.trimmed - context.liveTop
            guard !placement.virtual, placement.alternate == context.alternate,
                  row >= top, row + placement.rows - 1 <= bottom else { continue }
            placements[index].absoluteRow -= 1
            if row == top {
                let slice = placement.sourceHeight / Double(placement.rows)
                placements[index].sourceY += slice
                placements[index].sourceHeight -= slice
                placements[index].rows -= 1
                placements[index].absoluteRow += 1
            }
        }
        placements.removeAll { $0.rows == 0 }
    }
    func cancelTransfer() { pending = nil; discardContinuation = true }

    func receive(_ packet: [UInt8], context: KittyGraphicsContext,
                 output: (Data) -> Void, moveCursor: (Int, Int) -> Void) {
        let separator = packet.firstIndex(of: 0x3b) ?? packet.count
        guard separator <= 1024, let header = String(bytes: packet[..<separator], encoding: .ascii) else { cancelTransfer(); return }
        var control: [String: String] = [:]
        for pair in header.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 1, parts[1].count <= 32 else { cancelTransfer(); return }
            control[String(parts[0])] = String(parts[1])
        }
        let payload = separator < packet.count ? Array(packet[(separator + 1)...]) : []
        let action = control["a"] ?? "t"
        if action == "d" { pending = nil; discardContinuation = false; delete(control, context: context, output: output); return }
        if action == "p" { place(control, context: context, output: output, moveCursor: moveCursor); return }
        guard ["t", "T", "q"].contains(action) else { respond(control, "ENOTSUP: unsupported action", output); return }
        let more = control["m"] == "1"
        if discardContinuation {
            // A new explicit transmission can replace a cancelled transfer.
            if control["a"] != nil || control["i"] != nil || control["f"] != nil { discardContinuation = false }
            else { if !more { discardContinuation = false }; return }
        }
        let original = pending?.control ?? control
        guard original["t", default: "d"] == "d", original["o"] == nil,
              original["P"] == nil, original["Q"] == nil else {
            respond(original, "ENOTSUP: only direct uncompressed placements are supported", output)
            pending = nil; discardContinuation = more; return
        }
        guard payload.count <= 4096, let decoded = Data(base64Encoded: Data(payload)),
              decoded.count <= limits.maximumImageBytes - (pending?.bytes.count ?? 0) else {
            respond(original, "E2BIG: invalid or oversized transfer", output)
            pending = nil; discardContinuation = more; return
        }
        if pending == nil { pending = Transfer(control: control, bytes: Data()) }
        pending?.bytes.append(decoded)
        if more { return }
        guard let transfer = pending else { return }
        pending = nil
        guard let image = decode(transfer.bytes, control: transfer.control) else {
            respond(transfer.control, "EINVAL: invalid image or dimensions exceed limits", output); return
        }
        if transfer.control["a"] == "q" { respond(transfer.control, "OK", output); return }
        let id = uint(transfer.control, "i") ?? nextID()
        guard id != 0 else { respond(transfer.control, "EINVAL: image id must be nonzero", output); return }
        removeImage(id)
        while totalBytes + image.data.count > limits.maximumTotalBytes || images.count >= limits.maximumImages {
            guard let oldest = images.min(by: { $0.value.tick < $1.value.tick })?.key else { break }
            removeImage(oldest)
        }
        guard image.data.count <= limits.maximumTotalBytes else { respond(transfer.control, "E2BIG: image cache limit", output); return }
        tick &+= 1
        images[id] = Image(data: image.data, width: image.width, height: image.height, tick: tick)
        totalBytes += image.data.count
        if let number = uint(transfer.control, "I"), number != 0 { imageNumbers[number] = id }
        var placementControl = transfer.control
        placementControl["i"] = String(id)
        if transfer.control["a"] == "T" { place(placementControl, context: context, output: output, moveCursor: moveCursor) }
        else { respond(placementControl, "OK", output) }
    }

    private func decode(_ data: Data, control: [String: String]) -> Image? {
        let format = integer(control, "f", fallback: 32)
        if format == 100 { return decodePNG(data) }
        guard format == 24 || format == 32 else { return nil }
        let width = integer(control, "s"), height = integer(control, "v")
        guard dimensionsAllowed(width, height), data.count == width * height * (format / 8) else { return nil }
        if format == 32 { return Image(data: data, width: width, height: height, tick: 0) }
        var rgba = Data(); rgba.reserveCapacity(width * height * 4)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in stride(from: 0, to: bytes.count, by: 3) { rgba.append(bytes[index]); rgba.append(bytes[index + 1]); rgba.append(bytes[index + 2]); rgba.append(255) }
        }
        return Image(data: rgba, width: width, height: height, tick: 0)
    }

    private func dimensionsAllowed(_ width: Int, _ height: Int) -> Bool {
        width > 0 && height > 0 && width <= limits.maximumDimension && height <= limits.maximumDimension && width * height <= limits.maximumImageBytes / 4
    }

    private func decodePNG(_ data: Data) -> Image? {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= 24, data.prefix(8).elementsEqual(signature),
              data[12..<16].elementsEqual("IHDR".utf8) else { return nil }
        func bigEndian(_ offset: Int) -> Int { data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        let width = bigEndian(16), height = bigEndian(20)
        // Validate the uncompressed size before asking ImageIO to allocate anything.
        guard dimensionsAllowed(width, height),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              cgImage.width == width, cgImage.height == height else { return nil }
        var rgba = Data(count: width * height * 4)
        let succeeded = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: raw.count, by: 4) {
                let alpha = Int(bytes[index + 3])
                if alpha > 0 && alpha < 255 {
                    for component in 0..<3 { bytes[index + component] = UInt8(min(255, (Int(bytes[index + component]) * 255 + alpha / 2) / alpha)) }
                }
            }
            return true
        }
        return succeeded ? Image(data: rgba, width: width, height: height, tick: 0) : nil
    }

    private func place(_ control: [String: String], context: KittyGraphicsContext,
                       output: (Data) -> Void, moveCursor: (Int, Int) -> Void) {
        guard control["P"] == nil, control["Q"] == nil,
              ["x", "y", "w", "h"].allSatisfy({ integer(control, $0) == 0 }) else {
            respond(control, "ENOTSUP: relative and cropped placements are unavailable", output); return
        }
        guard let id = uint(control, "i") ?? uint(control, "I").flatMap({ imageNumbers[$0] }), let image = images[id] else {
            respond(control, "ENOENT: image not found", output); return
        }
        let requestedCols = integer(control, "c"), requestedRows = integer(control, "r")
        guard (0...10_000).contains(requestedCols), (0...10_000).contains(requestedRows) else { respond(control, "EINVAL: placement exceeds limits", output); return }
        let cols: Int, rows: Int
        if requestedCols > 0, requestedRows > 0 { cols = requestedCols; rows = requestedRows }
        else if requestedCols > 0 {
            cols = requestedCols
            rows = max(1, Int(ceil(Double(image.height) * Double(cols * context.cellWidth) / Double(image.width * context.cellHeight))))
        } else if requestedRows > 0 {
            rows = requestedRows
            cols = max(1, Int(ceil(Double(image.width) * Double(rows * context.cellHeight) / Double(image.height * context.cellWidth))))
        } else {
            cols = (image.width + context.cellWidth - 1) / context.cellWidth
            rows = (image.height + context.cellHeight - 1) / context.cellHeight
        }
        guard cols <= 10_000, rows <= 10_000 else { respond(control, "E2BIG: placement exceeds limits", output); return }
        let placementID = uint(control, "p") ?? nextID()
        placements.removeAll { $0.imageID == id && $0.placementID == placementID }
        if placements.count >= limits.maximumPlacements { placements.removeFirst() }
        placements.append(Placement(imageID: id, placementID: placementID, column: min(context.columns - 1, context.column),
                                    columns: cols,
                                    offsetX: min(context.cellWidth - 1, max(0, integer(control, "X"))),
                                    offsetY: min(context.cellHeight - 1, max(0, integer(control, "Y"))),
                                    zIndex: integer(control, "z"),
                                    absoluteRow: context.trimmed + context.liveTop + context.row, rows: rows,
                                    alternate: context.alternate, virtual: control["U"] == "1"))
        tick &+= 1; images[id]?.tick = tick
        if control["C"] != "1", control["U"] != "1" { moveCursor(cols, min(rows, context.rows + 1)) }
        var response = control; response["i"] = String(id)
        respond(response, "OK", output)
    }

    func snapshot(context: KittyGraphicsContext, viewportTop: Int, placeholders: [KittyPlaceholderCell]) -> [TerminalImagePlacement] {
        placements.removeAll { !$0.virtual && $0.alternate == context.alternate && $0.absoluteRow + $0.rows <= context.trimmed }
        var result: [TerminalImagePlacement] = placements.compactMap { placement in
            guard !placement.virtual, placement.alternate == context.alternate, let image = images[placement.imageID] else { return nil }
            let row = placement.absoluteRow - context.trimmed - viewportTop
            guard row < context.rows, row + placement.rows > 0 else { return nil }
            return TerminalImagePlacement(id: placement.imageID, placementID: placement.placementID,
                                          column: placement.column, row: row, columns: placement.columns, rows: placement.rows,
                                          offsetX: placement.offsetX, offsetY: placement.offsetY, zIndex: placement.zIndex,
                                          pixelWidth: image.width, pixelHeight: image.height, rgba: image.data,
                                          sourceY: placement.sourceY, sourceHeight: placement.sourceHeight)
        }
        for cell in placeholders {
            guard let prototype = placements.last(where: { $0.virtual && $0.imageID == cell.imageID && (cell.placementID == 0 || $0.placementID == cell.placementID) }),
                  let image = images[cell.imageID], cell.imageColumn < prototype.columns, cell.imageRow < prototype.rows else { continue }
            let scale = min(Double(prototype.columns * context.cellWidth) / Double(image.width),
                            Double(prototype.rows * context.cellHeight) / Double(image.height))
            let displayedWidth = Double(image.width) * scale, displayedHeight = Double(image.height) * scale
            let left = Double(cell.imageColumn * context.cellWidth), top = Double(cell.imageRow * context.cellHeight)
            guard left < displayedWidth, top < displayedHeight else { continue }
            let width = min(Double(context.cellWidth), displayedWidth - left)
            let height = min(Double(context.cellHeight), displayedHeight - top)
            result.append(TerminalImagePlacement(id: cell.imageID, placementID: prototype.placementID,
                                                 column: cell.column, row: cell.row, columns: 1, rows: 1,
                                                 zIndex: prototype.zIndex, pixelWidth: image.width, pixelHeight: image.height, rgba: image.data,
                                                 sourceX: left / displayedWidth, sourceY: top / displayedHeight,
                                                 sourceWidth: width / displayedWidth, sourceHeight: height / displayedHeight,
                                                 widthFraction: width / Double(context.cellWidth), heightFraction: height / Double(context.cellHeight)))
        }
        return result.sorted { ($0.zIndex, $0.id, $0.placementID) < ($1.zIndex, $1.id, $1.placementID) }
    }

    private func delete(_ control: [String: String], context: KittyGraphicsContext, output: (Data) -> Void) {
        let mode = control["d"] ?? "a"
        let lower = mode.lowercased()
        guard ["a", "i", "n", "c", "p", "q", "x", "y", "z", "r"].contains(lower) else { respond(control, "ENOTSUP: unsupported deletion", output); return }
        let id = uint(control, "i"), number = uint(control, "I"), placementID = uint(control, "p")
        var removedIDs = Set<UInt32>()
        placements.removeAll { placement in
            guard placement.alternate == context.alternate || placement.virtual else { return false }
            if placement.virtual && !["i", "n", "r"].contains(lower) { return false }
            let row = placement.absoluteRow - context.trimmed - context.liveTop
            let visible = row < context.rows && row + placement.rows > 0
            let x = lower == "c" ? context.column : integer(control, "x") - 1
            let y = lower == "c" ? context.row : integer(control, "y") - 1
            let hitX = x >= placement.column && x < placement.column + placement.columns
            let hitY = y >= row && y < row + placement.rows
            let matches: Bool
            switch lower {
            case "a": matches = visible
            case "i": matches = placement.imageID == id && (placementID == nil || placement.placementID == placementID)
            case "n": matches = placement.imageID == number.flatMap { imageNumbers[$0] } && (placementID == nil || placement.placementID == placementID)
            case "c", "p": matches = hitX && hitY
            case "q": matches = hitX && hitY && placement.zIndex == integer(control, "z")
            case "x": matches = hitX
            case "y": matches = hitY
            case "z": matches = placement.zIndex == integer(control, "z")
            case "r": matches = placement.imageID >= (uint(control, "x") ?? 0) && placement.imageID <= (uint(control, "y") ?? UInt32.max)
            default: matches = false
            }
            if matches { removedIDs.insert(placement.imageID) }
            return matches
        }
        if mode != lower {
            if lower == "i", let id { removedIDs.insert(id) }
            if lower == "n", let number, let id = imageNumbers[number] { removedIDs.insert(id) }
            if lower == "r" { removedIDs.formUnion(images.keys.filter { $0 >= (uint(control, "x") ?? 0) && $0 <= (uint(control, "y") ?? UInt32.max) }) }
            if lower == "a" { removedIDs.formUnion(images.keys.filter { key in !placements.contains { $0.imageID == key } }) }
            for id in removedIDs where !placements.contains(where: { $0.imageID == id }) { removeImage(id) }
        }
        // Kitty deletion is deliberately silent, regardless of q.
    }

    private func removeImage(_ id: UInt32) {
        if let old = images.removeValue(forKey: id) { totalBytes -= old.data.count }
        placements.removeAll { $0.imageID == id }
        imageNumbers = imageNumbers.filter { $0.value != id }
    }
    private func nextID() -> UInt32 {
        repeat { sequence &+= 1 } while sequence == 0 || images[sequence] != nil
        return sequence
    }
    private func integer(_ control: [String: String], _ key: String, fallback: Int = 0) -> Int { control[key].flatMap(Int.init) ?? fallback }
    private func uint(_ control: [String: String], _ key: String) -> UInt32? { control[key].flatMap(UInt32.init) }
    private func respond(_ control: [String: String], _ message: String, _ output: (Data) -> Void) {
        let quiet = integer(control, "q")
        guard quiet < 2, !(quiet == 1 && message == "OK") else { return }
        var fields: [String] = []
        for key in ["i", "I", "p"] { if let value = uint(control, key) { fields.append("\(key)=\(value)") } }
        guard !fields.isEmpty else { return }
        output(Data("\u{1b}_G\(fields.joined(separator: ","));\(message)\u{1b}\\".utf8))
    }
}
