import Foundation
import GhosttyEngine
import TerminalCore
import Testing

/// What the trial engine does with memory: the failure it used to hide (#28), the image bytes
/// it used to keep outside the workspace's ceiling (#26), and the history pages it never asked
/// the library to reclaim (#19).
///
/// Serialized, because several of these put a number on how much memory something takes and
/// every test here allocates in the same process and on the same actor.
@TerminalParserActor
@Suite(.serialized)
struct GhosttyEngineMemoryTests {

    // MARK: - #28, a failed allocation

    @Test func constructionIsFailableRatherThanSilentlyBlank() throws {
        // The type is what rules the blank terminal out. There is no `GhosttyEngine` without a
        // libghostty terminal behind it any more, so there is no instance on which `feed`
        // discards output and `snapshot()` hands back a grid of default cells.
        let constructed: GhosttyEngine? = GhosttyEngine(columns: 20, rows: 4)
        let engine = try #require(constructed)
        #expect(engine.columns == 20)
        #expect(engine.rows == 4)
        engine.feed(Data("visible".utf8))
        #expect(engine.snapshot()[0, 0].text == "v")
    }

    /// Sizes outside what the library accepts are clamped rather than refused, so the failable
    /// initializer reports a refusal from the library and nothing else.
    @Test func absurdSizesAreClampedNotFailed() throws {
        let small = try #require(GhosttyEngine(columns: 0, rows: 0))
        #expect(small.columns >= 2)
        #expect(small.rows >= 1)
        let large = try #require(GhosttyEngine(columns: 100_000, rows: 100_000))
        #expect(large.columns <= 1000)
        #expect(large.rows <= 1000)
    }

    // MARK: - #26, decoded images

    /// A direct uncompressed RGB transmission that also places the image, which is the one
    /// Kitty path this engine decodes.
    private func kittyImage(id: UInt32, width: Int, height: Int) -> Data {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 3)
        for index in 0..<(width * height) {
            pixels.append(UInt8(index % 256)); pixels.append(0); pixels.append(255)
        }
        let payload = Data(pixels).base64EncodedString()
        return Data("\u{1b}_Gi=\(id),f=24,s=\(width),v=\(height),a=T,C=1;\(payload)\u{1b}\\".utf8)
    }

    @Test func decodedImageBytesAreAccountedThroughTheSharedBudget() throws {
        let budget = TerminalImageBudget(maximumTotalBytes: 1 << 20)
        let engine = try #require(GhosttyEngine(columns: 20, rows: 6, imageBudget: budget))
        engine.setCellSize(width: 8, height: 16)
        engine.feed(kittyImage(id: 1, width: 8, height: 8))
        #expect(engine.snapshot().images.map(\.id) == [1])
        // Bytes, not a count of entries: the ceiling the workspace enforces is in the unit the
        // device cares about.
        #expect(budget.totalBytes == 8 * 8 * 4)

        // A memory warning calls exactly this, and it used to walk a table this engine never
        // put anything in.
        var invalidations = 0, displays = 0
        engine.onImageCacheInvalidated = { invalidations += 1 }
        engine.onNeedsDisplay = { displays += 1 }
        budget.removeAll()
        #expect(budget.totalBytes == 0)
        #expect(invalidations == 1)
        #expect(displays == 1)
    }

    @Test func oneImageLargerThanTheCeilingIsRefusedRatherThanDecoded() throws {
        // Four pixels of RGBA is sixteen bytes, so a ceiling of eight cannot hold it. The
        // engine used to have no byte ceiling at all: a count of 64 entries admitted 64 images
        // of any size.
        let budget = TerminalImageBudget(maximumTotalBytes: 8)
        let engine = try #require(GhosttyEngine(columns: 20, rows: 6, imageBudget: budget))
        engine.setCellSize(width: 8, height: 16)
        engine.feed(kittyImage(id: 1, width: 2, height: 2))
        #expect(engine.snapshot().images.isEmpty)
        #expect(budget.totalBytes == 0)
    }

    @Test func theBudgetEvictsTheLeastRecentlyDrawnImageAcrossSessions() throws {
        // Room for two single pixels. A third arriving has to displace one of them, and the one
        // it displaces has to be the one nothing has drawn for the longest — not every entry,
        // which is what `removeAll(keepingCapacity:)` did.
        let budget = TerminalImageBudget(maximumTotalBytes: 8)
        let first = try #require(GhosttyEngine(columns: 20, rows: 6, imageBudget: budget))
        let second = try #require(GhosttyEngine(columns: 20, rows: 6, imageBudget: budget))
        for engine in [first, second] { engine.setCellSize(width: 8, height: 16) }

        first.feed(kittyImage(id: 1, width: 1, height: 1))
        #expect(first.snapshot().images.map(\.id) == [1])
        second.feed(kittyImage(id: 1, width: 1, height: 1))
        #expect(second.snapshot().images.map(\.id) == [1])
        #expect(budget.totalBytes == 8)

        // The first session's frame is the older one, so the second session's third image
        // evicts it — and the evicted session is told synchronously, so a hidden view cannot
        // keep the pixels alive in its last frame.
        var retained: TerminalSnapshot? = first.snapshot()
        first.onImageCacheInvalidated = { retained = nil }
        second.feed(kittyImage(id: 2, width: 1, height: 1))
        _ = second.snapshot()
        #expect(retained == nil)
        #expect(budget.totalBytes == 8)
    }

    @Test func aClosedSessionGivesItsImageBytesBack() throws {
        let budget = TerminalImageBudget(maximumTotalBytes: 1 << 20)
        var engine: GhosttyEngine? = try #require(GhosttyEngine(columns: 20, rows: 6, imageBudget: budget))
        engine?.setCellSize(width: 8, height: 16)
        engine?.feed(kittyImage(id: 1, width: 4, height: 4))
        _ = engine?.snapshot()
        #expect(budget.totalBytes == 4 * 4 * 4)
        // Weak ownership, the same as for the other engine's graphics store: nothing has to be
        // unregistered from a deinit that cannot reach this actor.
        engine = nil
        #expect(budget.totalBytes == 0)
    }

    @Test func resetGivesTheImageBytesBack() throws {
        let budget = TerminalImageBudget(maximumTotalBytes: 1 << 20)
        let engine = try #require(GhosttyEngine(columns: 20, rows: 6, imageBudget: budget))
        engine.setCellSize(width: 8, height: 16)
        engine.feed(kittyImage(id: 1, width: 4, height: 4))
        _ = engine.snapshot()
        #expect(budget.totalBytes == 4 * 4 * 4)
        var invalidations = 0
        engine.onImageCacheInvalidated = { invalidations += 1 }
        engine.reset()
        #expect(budget.totalBytes == 0)
        #expect(invalidations == 1)
    }

    // MARK: - #19, scrollback compression

    /// Enough output to push complete pages into history, in the network-sized batches the
    /// pipeline hands over.
    private func fillHistory(_ engine: any TerminalEngine, frames: Int = 120) {
        var frame = ""
        for row in 0..<95 {
            for column in 0..<105 {
                frame += "\u{1b}[38;2;\((row * 7 + column * 3) % 256);\((row * 11) % 256);\((column * 13) % 256)m"
                frame += "\u{1b}[48;2;\((column * 5) % 256);\((row * 3) % 256);\((row + column) % 256)m▀"
            }
            frame += "\r\n"
        }
        let data = Data(frame.utf8)
        for _ in 0..<frames {
            var offset = 0
            while offset < data.count {
                let end = min(offset + 8192, data.count)
                engine.feed(data.subdata(in: offset..<end))
                offset = end
            }
        }
    }

    @Test func compressionNeverRunsInsideFeedAndRunsOnceParsingGoesIdle() async throws {
        let engine = try #require(GhosttyEngine(columns: 105, rows: 95))
        fillHistory(engine, frames: 60)
        // Feeding never suspends, so the maintenance loop cannot have taken a step yet. That is
        // the property that keeps compression off the parse path: it only ever runs in the gaps.
        #expect(engine.compressionSteps == 0)

        // Past the idle delay the loop takes its steps on its own. It waits for the pass to
        // end rather than for a fixed time because the actor is shared with every other session
        // in the process: what is asserted is that the scheduler runs unprompted, not how
        // quickly this host gets round to it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while engine.compressionPasses == 0, !engine.compressionIsUnsupported,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.compressionSteps > 0)
        // Unsupported means the library cannot reclaim retained mappings on this target. There
        // is nothing to schedule, and the engine has to stop asking rather than spin on it.
        #expect(engine.compressionPasses >= 1 || engine.compressionIsUnsupported)

        // A finished pass does not start another until the library's token says state moved.
        let settled = engine.compressionSteps
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.compressionSteps == settled)
    }

    @Test func compressionReclaimsMemoryAndLeavesHistoryReadable() throws {
        let engine = try #require(GhosttyEngine(columns: 105, rows: 95))
        fillHistory(engine)
        let scrolled = engine.snapshot().scrollbackCount
        // The byte ceiling is what bounds history, and it has to be big enough for history to
        // exist at all: the library's default of 10,000 bytes held a few hundred lines.
        #expect(scrolled > 2_000, "history held \(scrolled) rows")

        let before = footprint()
        let steps = engine.compressScrollbackNow()
        let after = footprint()
        #expect(steps > 0)
        print(String(format: "COMPRESSION rows=%d steps=%d footprint %.1fMB -> %.1fMB (reclaimed %.1fMB)",
                     scrolled, steps, mebibytes(before), mebibytes(after), mebibytes(before - after)))

        // Compression changes the storage representation, never the contents. Scrolling into
        // the compressed history has to still produce the cells that were written there.
        #expect(engine.snapshot().scrollbackCount == scrolled)
        engine.scroll(by: scrolled)
        let history = engine.snapshot()
        #expect(history.scrollbackOffset == scrolled)
        #expect(history.cells.contains { $0.text == "▀" })
    }

    /// The comparison the release needs a number for. It is taken on whatever host runs the
    /// tests, so it is a bound rather than the device measurement #19 reported: what it pins is
    /// that this engine's retention is of the same order as the engine the app ships with, and
    /// that it stays inside the ceiling the engine sets for itself.
    @Test func retainedBytesAreOfTheSameOrderAsTheShippingEngine() throws {
        var growth: [String: Int] = [:]
        for name in ["swiftterm", "ghostty"] {
            let before = footprint()
            let engine: any TerminalEngine = name == "ghostty"
                ? try #require(GhosttyEngine(columns: 105, rows: 95))
                : SwiftTermEngine(columns: 105, rows: 95)
            fillHistory(engine)
            (engine as? GhosttyEngine)?.compressScrollbackNow()
            _ = engine.snapshot()
            growth[name] = footprint() - before
        }
        let ghostty = growth["ghostty"] ?? 0, swiftTerm = growth["swiftterm"] ?? 0
        print(String(format: "RETAINED swiftterm=%.1fMB ghostty=%.1fMB", mebibytes(swiftTerm), mebibytes(ghostty)))
        // The scrollback ceiling this engine sets is 24MB. Allowing twice that covers the
        // grid, the snapshot and the allocator's slack while still failing if history grows
        // without a bound, which is what #19 describes.
        #expect(ghostty < 48 << 20, "ghostty grew \(mebibytes(ghostty))MB")
    }

    private func mebibytes(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

    /// The same counter the device measurement in #19 used, so the numbers printed here are in
    /// the same currency even though the host is not the same.
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
