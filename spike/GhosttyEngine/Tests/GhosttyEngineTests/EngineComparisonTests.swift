import Foundation
import GhosttyEngine
import TerminalCore
import Testing

/// #10 stage 2: the same bytes through both engines, comparing the grid they produce and how
/// long they take to produce it. Differences are reported per cell rather than as one failed
/// equality, because what matters is which constructs disagree.
@TerminalParserActor
struct EngineComparisonTests {
    private struct Case {
        let name: String
        let input: String
        let columns: Int
        let rows: Int
    }

    private let cases: [Case] = [
        .init(name: "plain text", input: "hello world", columns: 20, rows: 3),
        .init(name: "wrapping", input: String(repeating: "abcdefghij", count: 5), columns: 20, rows: 4),
        .init(name: "truecolor", input: "\u{1b}[38;2;10;200;30m\u{1b}[48;2;1;2;3mcolored\u{1b}[0m plain", columns: 20, rows: 2),
        .init(name: "palette", input: "\u{1b}[31mred\u{1b}[42mgreen-bg\u{1b}[0m", columns: 20, rows: 2),
        .init(name: "attributes", input: "\u{1b}[1mbold\u{1b}[0m \u{1b}[3mital\u{1b}[0m \u{1b}[4munder\u{1b}[0m \u{1b}[7minv\u{1b}[0m", columns: 30, rows: 2),
        .init(name: "japanese", input: "日本語とascii", columns: 20, rows: 2),
        .init(name: "cursor moves", input: "\u{1b}[2;5Hplaced\u{1b}[1;1Htop", columns: 20, rows: 3),
        .init(name: "erase", input: "dirty\u{1b}[2J\u{1b}[Hclean", columns: 20, rows: 3),
        .init(name: "half blocks", input: "\u{1b}[38;2;255;0;0m\u{1b}[48;2;0;0;255m▀▀▀", columns: 10, rows: 2)
    ]

    @Test func bothEnginesAgreeOnTheGrid() {
        var report: [String] = []
        for scenario in cases {
            let swiftTerm = SwiftTermEngine(columns: scenario.columns, rows: scenario.rows)
            let ghostty = GhosttyEngine(columns: scenario.columns, rows: scenario.rows)
            var palette: [TerminalColor] = []
            for index in 0..<16 {
                palette.append(TerminalColor(red: UInt8(index * 16), green: UInt8(index * 8), blue: UInt8(index * 4)))
            }
            swiftTerm.setColors(foreground: .foreground, background: .background, palette: palette)
            ghostty.setColors(foreground: .foreground, background: .background, palette: palette)
            swiftTerm.feed(Data(scenario.input.utf8))
            ghostty.feed(Data(scenario.input.utf8))

            let expected = swiftTerm.snapshot()
            let actual = ghostty.snapshot()
            var text = 0, foreground = 0, background = 0, attributes = 0, width = 0
            for index in 0..<min(expected.cells.count, actual.cells.count) {
                let left = expected.cells[index], right = actual.cells[index]
                if left.text.trimmingCharacters(in: .whitespaces) != right.text.trimmingCharacters(in: .whitespaces) { text += 1 }
                if left.foreground != right.foreground { foreground += 1 }
                if left.background != right.background { background += 1 }
                if left.attributes != right.attributes { attributes += 1 }
                if left.width != right.width { width += 1 }
            }
            let cursor = expected.cursor == actual.cursor ? "same" : "differs"
            let line = "\(scenario.name): cells=\(expected.cells.count) text=\(text) fg=\(foreground)"
                + " bg=\(background) attr=\(attributes) width=\(width) cursor=\(cursor)"
            report.append(line)
        }
        print("COMPARISON\n" + report.joined(separator: "\n"))
    }

    @Test func throughputOfBothEngines() {
        let columns = 105, rows = 95
        var frame = ""
        for row in 0..<rows {
            frame += "\u{1b}[\(row + 1);1H"
            for column in 0..<columns {
                frame += "\u{1b}[38;2;\((row * 7 + column * 3) % 256);\((row * 11) % 256);\((column * 13) % 256)m"
                frame += "\u{1b}[48;2;\((column * 5) % 256);\((row * 3) % 256);\((row + column) % 256)m▀"
            }
        }
        let data = Data(frame.utf8)

        func measure(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }

        let swiftTerm = SwiftTermEngine(columns: columns, rows: rows)
        let ghostty = GhosttyEngine(columns: columns, rows: rows)
        swiftTerm.feed(data); _ = swiftTerm.snapshot()
        ghostty.feed(data); _ = ghostty.snapshot()

        var swiftFeed = 0.0, swiftSnapshot = 0.0, ghosttyFeed = 0.0, ghosttySnapshot = 0.0
        for _ in 0..<20 {
            swiftFeed += measure { swiftTerm.feed(data) }
            swiftSnapshot += measure { _ = swiftTerm.snapshot() }
            ghosttyFeed += measure { ghostty.feed(data) }
            ghosttySnapshot += measure { _ = ghostty.snapshot() }
        }
        print(String(format: "THROUGHPUT bytes=%d\n  SwiftTerm feed=%.2fms snapshot=%.2fms\n  Ghostty   feed=%.2fms snapshot=%.2fms",
                     data.count, swiftFeed / 20, swiftSnapshot / 20, ghosttyFeed / 20, ghosttySnapshot / 20))
    }
}

/// The engine has to answer the questions a program asks before it draws. Nothing did until a
/// device crash traced back to how the callbacks were installed, so this pins the behaviour.
@TerminalParserActor
struct GhosttyQueryTests {
    @Test func queriesAreAnswered() {
        let engine = GhosttyEngine(columns: 80, rows: 24)
        engine.setCellSize(width: 14, height: 31)
        var replies = Data()
        engine.onOutput = { replies.append($0) }
        engine.feed(Data("\u{1b}[16t".utf8))   // cell size in pixels
        engine.feed(Data("\u{1b}[c".utf8))     // primary device attributes
        let text = String(decoding: replies, as: UTF8.self)
        #expect(text.contains("6;31;14t"))
        #expect(text.contains("\u{1b}[?"))
    }
}
