import Compression
import Foundation
import Testing
@testable import TerminalCore

/// #18: a `o=z` transfer was refused outright, so an image a sender thought worth compressing
/// drew nothing. Inflating it means the engine now decompresses attacker-controlled bytes, and
/// the ceiling on the result is the part that has to hold.
@Suite @TerminalParserActor struct KittyCompressionTests {
    /// A real zlib stream: two-byte header, raw deflate, Adler-32.
    private func zlib(_ data: Data) -> Data {
        var destination = [UInt8](repeating: 0, count: data.count + 4096)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(&destination, destination.count,
                                      source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        var stream = Data([0x78, 0x01])
        stream.append(contentsOf: destination[0..<written])
        var low: UInt32 = 1, high: UInt32 = 0
        for byte in data { low = (low &+ UInt32(byte)) % 65521; high = (high &+ low) % 65521 }
        let adler = (high << 16) | low
        stream.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: adler >> (24 - 8 * $0)) })
        return stream
    }

    @Test func aCompressedPayloadInflatesToExactlyWhatWentIn() {
        let original = Data((0..<200_000).map { UInt8($0 % 251) })
        let compressed = zlib(original)
        #expect(compressed.count < original.count)
        #expect(KittyZlib.inflate(compressed, maximumBytes: 16 * 1024 * 1024) == original)
    }

    /// The whole point of the ceiling: a payload that is small on the wire and enormous once
    /// inflated is refused rather than allocated. 8MB of zeros compresses to a few kilobytes.
    @Test func aPayloadThatInflatesPastTheCeilingIsRefused() {
        let bomb = zlib(Data(count: 8 * 1024 * 1024))
        #expect(bomb.count < 64 * 1024, "the test payload is not actually a small one: \(bomb.count)")
        #expect(KittyZlib.inflate(bomb, maximumBytes: 1024 * 1024) == nil)
        #expect(KittyZlib.inflate(bomb, maximumBytes: 16 * 1024 * 1024)?.count == 8 * 1024 * 1024)
    }

    @Test func malformedStreamsAreRefusedRatherThanPartlyDecoded() {
        let valid = zlib(Data((0..<4096).map { UInt8($0 % 251) }))
        #expect(KittyZlib.inflate(Data(), maximumBytes: 4096) == nil)
        #expect(KittyZlib.inflate(Data([0x78, 0x01, 0x00]), maximumBytes: 4096) == nil)
        // Not a zlib header: compression method 7 is not deflate.
        #expect(KittyZlib.inflate(Data([0x77, 0x01]) + valid.dropFirst(2), maximumBytes: 65536) == nil)
        // The header check is a multiple of 31, so a corrupted one is caught before inflating.
        #expect(KittyZlib.inflate(Data([0x78, 0x02]) + valid.dropFirst(2), maximumBytes: 65536) == nil)
        // Truncated deflate data ends the stream early, which must not return a partial image.
        #expect(KittyZlib.inflate(valid.prefix(valid.count / 2), maximumBytes: 65536) == nil)
    }

    /// End to end through the engine: an image whose inflated size is past the configured
    /// per-image limit is refused, and the engine answers rather than going quiet.
    @Test func anOversizedCompressedTransferIsRefusedWithAnAnswer() {
        let engine = SwiftTermEngine(columns: 20, rows: 6,
                                     imageLimits: TerminalImageLimits(maximumImageBytes: 64 * 1024))
        var replies = Data()
        engine.onOutput = { replies.append($0) }
        let payload = zlib(Data(count: 512 * 1024)).base64EncodedString()
        #expect(payload.count <= 4096, "the compressed payload needs to fit one packet: \(payload.count)")
        engine.feed(Data("\u{1b}_Gi=1,f=32,s=512,v=256,o=z,a=T,C=1;\(payload)\u{1b}\\".utf8))
        #expect(engine.snapshot().images.isEmpty)
        #expect(String(decoding: replies, as: UTF8.self).contains("EINVAL"))
    }
}
