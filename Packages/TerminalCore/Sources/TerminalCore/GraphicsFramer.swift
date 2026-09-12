import Foundation

/// A bounded APC transport envelope, not a VT parser. Non-APC bytes pass unchanged
/// to SwiftTerm, including UTF-8 sequences split across reads. OSC/DCS strings are
/// tracked solely to avoid interpreting their contents as graphics commands.
struct GraphicsFramer {
    private enum State { case ground, escape, apc, apcEscape, string, stringEscape }
    private var state = State.ground
    private var packet: [UInt8] = []
    private var overflow = false
    private var utf8ContinuationBytes = 0
    private let maximumPacketBytes = 8192

    mutating func feed(_ bytes: Data, onTerminal: ([UInt8]) -> Void,
                       onGraphics: ([UInt8]) -> Void, onOverflow: () -> Void, onReset: () -> Void) {
        var normal: [UInt8] = []
        normal.reserveCapacity(min(bytes.count, 65_536))
        func flush() { if !normal.isEmpty { onTerminal(normal); normal.removeAll(keepingCapacity: true) } }
        for byte in bytes {
            let continuation = utf8ContinuationBytes > 0 && (0x80...0xbf).contains(byte)
            if continuation { utf8ContinuationBytes -= 1 }
            else if (0xc2...0xdf).contains(byte) { utf8ContinuationBytes = 1 }
            else if (0xe0...0xef).contains(byte) { utf8ContinuationBytes = 2 }
            else if (0xf0...0xf4).contains(byte) { utf8ContinuationBytes = 3 }
            else { utf8ContinuationBytes = 0 }
            // Also gate standalone 8-bit APC introducers. Never confuse a UTF-8
            // continuation byte (for example in emoji) with a control character.
            if byte == 0x9f && !continuation && state != .apc && state != .apcEscape {
                normal.append(0x18); flush()
                packet.removeAll(keepingCapacity: true); overflow = false; state = .apc
                continue
            }
            switch state {
            case .ground:
                if byte == 0x1b { state = .escape } else { normal.append(byte) }
            case .escape:
                if byte == 0x5f {
                    normal.append(0x18); flush(); packet.removeAll(keepingCapacity: true); overflow = false; state = .apc
                } else {
                    if byte == 0x63 { flush(); onReset() }
                    normal.append(0x1b)
                    if byte == 0x1b { state = .escape }
                    else {
                        normal.append(byte)
                        state = [0x50, 0x5d, 0x58, 0x5e].contains(byte) ? .string : .ground
                    }
                }
            case .apc:
                if byte == 0x9c || byte == 0x07 {
                    if !overflow, packet.first == 0x47 { onGraphics(Array(packet.dropFirst())) }
                    packet.removeAll(keepingCapacity: true); state = .ground
                } else if byte == 0x1b { state = .apcEscape }
                else if byte == 0x18 || byte == 0x1a {
                    packet.removeAll(keepingCapacity: true); state = .ground; onOverflow()
                } else if !overflow {
                    if packet.count < maximumPacketBytes { packet.append(byte) }
                    else { packet.removeAll(keepingCapacity: true); overflow = true; onOverflow() }
                }
            case .apcEscape:
                if byte == 0x5c {
                    if !overflow, packet.first == 0x47 { onGraphics(Array(packet.dropFirst())) }
                    packet.removeAll(keepingCapacity: true); state = .ground
                } else {
                    // An ESC followed by a different command aborts the APC.
                    packet.removeAll(keepingCapacity: true); onOverflow()
                    normal.append(0x1b); normal.append(byte); state = .ground
                }
            case .string:
                normal.append(byte)
                if byte == 0x1b { state = .stringEscape }
                else if byte == 0x07 || byte == 0x18 || byte == 0x1a { state = .ground }
            case .stringEscape:
                if byte == 0x5f {
                    normal.append(0x18); flush(); packet.removeAll(keepingCapacity: true); overflow = false; state = .apc
                } else {
                    normal.append(byte)
                    if byte == 0x63 { flush(); onReset() }
                    if byte == 0x1b { state = .stringEscape }
                    else { state = [0x50, 0x5d, 0x58, 0x5e].contains(byte) ? .string : .ground }
                }
            }
            if normal.count >= 65_536 { flush() }
        }
        flush()
    }
}
