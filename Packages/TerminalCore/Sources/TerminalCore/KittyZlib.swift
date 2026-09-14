import Compression
import Foundation

/// `o=z` in a Kitty transfer means the pixels arrive as a zlib stream, which is what a sender
/// reaches for when the image is large — exactly when it is worth sending (#18).
///
/// Only `SwiftTermEngine`'s store needs this. libghostty-vt inflates a compressed payload
/// itself before storing it, and its header says so: "compressed payloads are inflated before
/// storage. Consumers never need to inflate image data themselves."
enum KittyZlib {
    /// Returns nil rather than a partial result for anything malformed, and for anything that
    /// inflates past `maximumBytes`. That bound is the point: a compressed payload is small by
    /// construction, so without a ceiling a few kilobytes of APC could ask for gigabytes of
    /// pixels. The caller's limit is the same one the uncompressed path applies.
    static func inflate(_ data: Data, maximumBytes: Int) -> Data? {
        // A zlib stream wraps the deflate data in a two-byte header and a four-byte Adler-32.
        // Apple's decoder takes the deflate stream on its own, so the wrapper is checked here
        // and then stepped over: method 8 is deflate, the two header bytes are a multiple of
        // 31, and a preset dictionary (which the Kitty protocol never uses) is refused rather
        // than mistaken for compressed data.
        guard data.count > 6, maximumBytes > 0 else { return nil }
        let header = data[data.startIndex], flags = data[data.startIndex + 1]
        guard header & 0x0f == 8, flags & 0x20 == 0,
              (UInt16(header) << 8 | UInt16(flags)) % 31 == 0 else { return nil }
        let deflated = data.dropFirst(2).dropLast(4)
        guard !deflated.isEmpty else { return nil }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var block = [UInt8](repeating: 0, count: 64 * 1024)
        return deflated.withUnsafeBytes { source -> Data? in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = source.count
            while true {
                var status = COMPRESSION_STATUS_ERROR
                block.withUnsafeMutableBufferPointer { destination in
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = destination.count - stream.dst_size
                    if produced > 0 { output.append(destination.baseAddress!, count: produced) }
                }
                guard output.count <= maximumBytes else { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK: continue
                default: return nil
                }
            }
        }
    }
}
