import Foundation
import TerminalCore
import Testing
import UIKit
@testable import TerminalRender

@MainActor
struct TerminalInputTests {
    @Test
    func JapanesePreeditUpdatesStayLocalAndUnmarkCommitsExactlyOnce() {
        let input = TerminalTextInputView()
        var commits: [String] = []
        input.onCommit = { commits.append($0) }
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        input.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        input.setMarkedText("日本", selectedRange: NSRange(location: 0, length: 2))
        #expect(input.hasComposition)
        #expect(input.markedTextRange != nil)
        #expect(input.text == "日本")
        #expect(commits.isEmpty)

        input.unmarkText()
        input.textViewDidChange(input) // UIKit may notify for the same completed edit.
        input.unmarkText()
        #expect(!input.hasComposition)
        #expect(commits == ["日本"])
    }

    @Test
    func confirmedCandidateReplacesPreeditAndPreservesUTF8() {
        let terminal = TerminalMetalView()
        var bytes: [Data] = []
        terminal.onInput = { bytes.append($0) }
        terminal.inputProxy.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
        #expect(bytes.isEmpty)
        terminal.insertText("日本語🧑🏽‍💻")
        terminal.inputProxy.unmarkText()
        #expect(bytes == [Data("日本語🧑🏽‍💻".utf8)])
    }

    @Test
    func replacingPartOfPreeditDoesNotDeleteOrWriteRemoteText() throws {
        let input = TerminalTextInputView()
        var commits: [String] = []
        var deletes = 0
        input.onCommit = { commits.append($0) }
        input.onRemoteDelete = { deletes += 1 }
        input.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
        let start = try #require(input.position(from: input.beginningOfDocument, offset: 1))
        let end = try #require(input.position(from: start, offset: 2))
        input.replace(try #require(input.textRange(from: start, to: end)), withText: "っぽん")
        #expect(input.text == "にっぽんご")
        #expect(input.hasComposition)
        #expect(commits.isEmpty)
        #expect(deletes == 0)
        input.unmarkText()
        #expect(commits == ["にっぽんご"])
    }

    @Test
    func backspaceOnlyEditsMarkedGraphemesUntilCompositionIsEmpty() {
        let input = TerminalTextInputView()
        var commits: [String] = []
        var deletes = 0
        input.onCommit = { commits.append($0) }
        input.onRemoteDelete = { deletes += 1 }
        let emoji = "🧑🏽‍💻"
        input.setMarkedText(emoji + "日", selectedRange: NSRange(location: emoji.utf16.count + 1, length: 0))
        input.deleteBackward()
        #expect(input.text == emoji)
        #expect(input.hasComposition)
        input.deleteBackward()
        #expect(input.text.isEmpty)
        #expect(!input.hasComposition)
        #expect(commits.isEmpty)
        #expect(deletes == 0)
        #expect(input.hasText)
        input.deleteBackward()
        #expect(deletes == 1)
    }

    @Test
    func nilMarkedTextEscapeAndResignationCancelWithoutRemoteOutput() {
        let input = TerminalTextInputView()
        var commits: [String] = []
        input.onCommit = { commits.append($0) }
        input.setMarkedText("変換中", selectedRange: NSRange(location: 3, length: 0))
        input.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        input.unmarkText()
        #expect(input.text.isEmpty)
        input.setMarkedText("取り消す", selectedRange: NSRange(location: 4, length: 0))
        #expect(input.consumeTerminalKey(.escape))
        #expect(input.text.isEmpty)
        input.setMarkedText("別セッションへ送らない", selectedRange: NSRange(location: 0, length: 0))
        input.resignFirstResponder()
        #expect(input.text.isEmpty)
        #expect(commits.isEmpty)
    }

    @Test
    func returnConfirmsJapaneseWithoutExecutingTheRemoteCommand() async throws {
        let terminal = TerminalMetalView()
        var bytes: [Data] = []
        terminal.onInput = { bytes.append($0) }
        terminal.inputProxy.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        terminal.insertText("\n")
        // Some keyboards unmark and then insert a newline in the same input event.
        terminal.insertText("\n")
        #expect(bytes == [Data("日本".utf8)])
        try await Task.sleep(for: .milliseconds(10))
        terminal.insertText("\n")
        #expect(bytes == [Data("日本".utf8), Data([13])])
    }

    @Test
    func candidateReplacementAlsoConsumesTheSameEventConfirmationReturn() async throws {
        let terminal = TerminalMetalView()
        var bytes: [Data] = []
        terminal.onInput = { bytes.append($0) }
        terminal.inputProxy.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        terminal.insertText("日本")
        terminal.insertText("\n")
        #expect(bytes == [Data("日本".utf8)])
        try await Task.sleep(for: .milliseconds(10))
        terminal.insertText("\n")
        #expect(bytes == [Data("日本".utf8), Data([13])])
    }

    @Test
    func nativeTextStorageUpdatesStayLocalUntilUIKitUnmarks() async throws {
        let terminal = TerminalMetalView()
        var bytes: [Data] = []
        terminal.onInput = { bytes.append($0) }
        let input = terminal.inputProxy
        input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        // A native UITextView.text update retains markedTextRange on iOS. A delegate
        // notification for that update must remain local until a real unmark occurs.
        input.text = "日本"
        #expect(input.markedTextRange != nil)
        input.textViewDidChange(input)
        #expect(bytes.isEmpty)
        input.unmarkText()
        input.insertText("\n")
        #expect(bytes == [Data("日本".utf8)])
        try await Task.sleep(for: .milliseconds(10))
        input.insertText("\n")
        #expect(bytes == [Data("日本".utf8), Data([13])])
    }

    @Test
    func accessoryLiteralsCommitPreeditBeforeInsertingTheirOwnCharacters() {
        let terminal = TerminalMetalView()
        var bytes: [Data] = []
        terminal.onInput = { bytes.append($0) }
        terminal.inputProxy.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        terminal.inputProxy.insertAccessoryText("|")
        terminal.inputProxy.setMarkedText("語", selectedRange: NSRange(location: 1, length: 0))
        terminal.inputProxy.insertAccessoryText("~")
        #expect(bytes == [Data("日本".utf8), Data("|".utf8), Data("語".utf8), Data("~".utf8)])
    }

    @Test
    func attributedPreeditAlsoStaysLocalUntilConfirmation() {
        let input = TerminalTextInputView()
        var commits: [String] = []
        input.onCommit = { commits.append($0) }
        input.setAttributedMarkedText(NSAttributedString(string: "日本語"), selectedRange: NSRange(location: 3, length: 0))
        #expect(input.hasComposition)
        #expect(commits.isEmpty)
        input.unmarkText()
        #expect(commits == ["日本語"])
    }

    @Test
    func repeatedIdenticalCommitsAndAccessoryActionsAreNotLost() {
        let input = TerminalTextInputView()
        var commits: [String] = []
        input.onCommit = { commits.append($0) }
        for _ in 0..<2 {
            input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
            input.unmarkText()
        }
        input.setMarkedText("語", selectedRange: NSRange(location: 1, length: 0))
        #expect(!input.consumeTerminalKey(.tab)) // Commit precedes the explicit terminal action.
        #expect(commits == ["日本", "日本", "語"])
    }

    @Test
    func UTF16SelectionsAndReplacementNeverSplitAnEmojiCluster() throws {
        let input = TerminalTextInputView()
        let emoji = "🧑🏽‍💻"
        input.setMarkedText(emoji + "日本", selectedRange: NSRange(location: 1, length: 0))
        #expect(input.selectedRange.location == emoji.utf16.count)
        let start = try #require(input.position(from: input.beginningOfDocument, offset: 1))
        let end = try #require(input.position(from: start, offset: 1))
        input.replace(try #require(input.textRange(from: start, to: end)), withText: "漢")
        #expect(input.text == "漢日本")
        #expect(input.hasComposition)
    }

    @Test
    func nativeCaretAndCompositionFitAboveTheAccessoryOnTheLastRow() {
        let input = TerminalTextInputView()
        input.font = TerminalFont.font(ofSize: 14)
        input.setMarkedText("日本語の変換", selectedRange: NSRange(location: 6, length: 0))
        let viewport = CGRect(x: 0, y: 0, width: 180, height: 100)
        let width: CGFloat = 120
        let fitting = input.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        input.frame = TerminalTextInputLayout.frame(
            cursor: CGRect(x: 170, y: 80, width: 10, height: 20), viewport: viewport,
            preferredSize: CGSize(width: width, height: ceil(fitting.height)))
        input.layoutIfNeeded()
        let caret = input.caretRect(for: input.endOfDocument).offsetBy(dx: input.frame.minX, dy: input.frame.minY)
        #expect(input.frame.maxY <= viewport.maxY)
        #expect(input.frame.maxX <= viewport.maxX)
        #expect(caret.maxY <= viewport.maxY + 1)
        #expect(caret.maxX <= viewport.maxX + 1)
    }

    @Test
    func switchingSessionsCancelsPreeditAndModifierWithoutChangingTheInputView() throws {
        let terminal = TerminalMetalView()
        defer { terminal.stop() }
        terminal.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let first = TerminalInputIdentity(sessionID: UUID(), attemptID: UUID())
        let second = TerminalInputIdentity(sessionID: UUID(), attemptID: UUID())
        terminal.setInputIdentity(first)
        var bytes: [Data] = []
        terminal.onInput = { bytes.append($0) }
        let proxy = terminal.inputProxy
        proxy.setMarkedText("送らない日本語", selectedRange: NSRange(location: 7, length: 0))
        terminal.setInputIdentity(first)
        #expect(proxy.hasComposition) // Ordinary SwiftUI updates must preserve the IME.
        terminal.setInputIdentity(second)
        proxy.unmarkText()
        #expect(terminal.inputProxy === proxy)
        #expect(!proxy.hasComposition)
        #expect(bytes.isEmpty)

        func controlButton(in view: UIView) -> UIButton? {
            if view.accessibilityIdentifier == "terminalAccessoryControl" { return view as? UIButton }
            return view.subviews.lazy.compactMap(controlButton).first
        }
        let accessory = try #require(terminal.inputAccessoryView)
        let control = try #require(controlButton(in: accessory))
        control.sendActions(for: .touchUpInside)
        #expect(control.isSelected)
        terminal.setInputIdentity(first)
        #expect(!control.isSelected)
        terminal.insertText("c")
        #expect(bytes == [Data("c".utf8)])
    }

    @Test
    func equalSnapshotRevisionsFromDifferentSessionsReplaceTheVisibleContent() {
        let terminal = TerminalMetalView()
        defer { terminal.stop() }
        let first = SwiftTermEngine(columns: 10, rows: 2)
        let second = SwiftTermEngine(columns: 10, rows: 2)
        first.feed(Data("first".utf8))
        second.feed(Data("日本語".utf8))
        let firstSnapshot = first.snapshot()
        let secondSnapshot = second.snapshot()
        #expect(firstSnapshot.revision == secondSnapshot.revision)
        terminal.setInputIdentity(.init(sessionID: UUID(), attemptID: UUID()))
        terminal.update(firstSnapshot)
        #expect(terminal.accessibilityValue?.contains("first") == true)
        terminal.setInputIdentity(.init(sessionID: UUID(), attemptID: UUID()))
        terminal.update(secondSnapshot)
        #expect(terminal.accessibilityValue?.contains("日本語") == true)
        #expect(terminal.accessibilityValue?.contains("first") == false)
    }

    @Test
    func activeSessionPublishesItsGridBeforeReceivingInput() {
        let terminal = TerminalMetalView()
        defer { terminal.stop() }
        terminal.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        var events: [String] = []
        terminal.onResize = { columns, rows in
            #expect(columns > 2 && rows > 1)
            events.append("resize")
        }
        terminal.onInput = { _ in events.append("input") }
        terminal.setInputIdentity(.init(sessionID: UUID(), attemptID: UUID()))
        terminal.insertText("a")
        #expect(events == ["resize", "input"])
        terminal.setInputIdentity(.init(sessionID: UUID(), attemptID: UUID()))
        terminal.insertText("b")
        #expect(events == ["resize", "input", "resize", "input"])
    }

    @Test(arguments: [false, true])
    func delayedPasteNeverMovesToAnotherSessionOrAttempt(reconnect: Bool) async throws {
        let terminal = TerminalMetalView()
        defer { terminal.stop() }
        terminal.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let original = TerminalInputIdentity(sessionID: UUID(), attemptID: UUID())
        terminal.setInputIdentity(original)
        var delivered: [String] = []
        var continuation: CheckedContinuation<String?, Never>?
        terminal.onPaste = { delivered.append($0) }
        terminal.pasteTextLoader = { await withCheckedContinuation { continuation = $0 } }
        terminal.paste(nil)
        try await Task.sleep(for: .milliseconds(20))
        let pending = try #require(continuation)
        terminal.setInputIdentity(.init(sessionID: reconnect ? original.sessionID : UUID(), attemptID: UUID()))
        if !reconnect { terminal.setInputIdentity(original) } // A → B → A still invalidates the paste.
        pending.resume(returning: "dangerous remote command\n")
        try await Task.sleep(for: .milliseconds(20))
        #expect(delivered.isEmpty)
        terminal.pasteTextLoader = { "日本語" }
        terminal.paste(nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(delivered == ["日本語"])
    }

    @Test
    func dismantledTerminalRejectsPendingPasteAndFutureInput() async throws {
        let terminal = TerminalMetalView()
        var delivered: [String] = []
        var continuation: CheckedContinuation<String?, Never>?
        terminal.onInput = { delivered.append(String(decoding: $0, as: UTF8.self)) }
        terminal.onPaste = { delivered.append($0) }
        terminal.pasteTextLoader = { await withCheckedContinuation { continuation = $0 } }
        terminal.paste(nil)
        try await Task.sleep(for: .milliseconds(20))
        let pending = try #require(continuation)
        terminal.stop()
        pending.resume(returning: "stale paste")
        terminal.insertText("stale key")
        try await Task.sleep(for: .milliseconds(20))
        #expect(delivered.isEmpty)
        #expect(terminal.delegate == nil)
    }

    @Test
    func workspaceShortcutsLeaveShellAndEditorShortcutsAlone() {
        #expect(TerminalWorkspaceCommand.from(input: "t", modifiers: .command) == .newSession)
        #expect(TerminalWorkspaceCommand.from(input: "w", modifiers: .command) == .closeSession)
        #expect(TerminalWorkspaceCommand.from(input: "[", modifiers: [.command, .shift]) == .previousSession)
        #expect(TerminalWorkspaceCommand.from(input: "}", modifiers: [.command, .shift]) == .nextSession)
        #expect(TerminalWorkspaceCommand.from(input: "4", modifiers: .command) == .selectSession(3))
        #expect(TerminalWorkspaceCommand.from(input: ",", modifiers: .command) == .settings)
        for key in ["c", "v", "a", "5", "t"] {
            #expect(TerminalWorkspaceCommand.from(input: key, modifiers: .control) == nil)
            #expect(TerminalWorkspaceCommand.from(input: key, modifiers: [.command, .alternate]) == nil)
        }
        let input = TerminalTextInputView()
        var commands: [TerminalWorkspaceCommand] = []
        input.onWorkspaceCommand = { commands.append($0) }
        // A settings editor/picker owns first responder: a retained terminal cannot
        // execute its workspace shortcuts just because the callback still exists.
        input.performWorkspaceCommand(UIKeyCommand(input: "w", modifierFlags: .command, action: #selector(TerminalTextInputView.performWorkspaceCommand(_:))))
        #expect(commands.isEmpty)
    }

    @Test
    func modalCancelsQueuedTerminalFocusUntilANewRequestArrives() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let terminal = TerminalMetalView()
        let editor = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        defer {
            terminal.stop()
            editor.resignFirstResponder()
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }
        terminal.frame = CGRect(x: 0, y: 100, width: 600, height: 400)
        controller.view.addSubview(terminal)
        controller.view.addSubview(editor)
        #expect(editor.becomeFirstResponder())
        let originalRequest = UUID()
        terminal.requestFocus(originalRequest)
        terminal.requestFocus(nil) // The sheet wins before the queued layout finishes.
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.isFirstResponder)
        #expect(!terminal.inputProxy.isFirstResponder)
        terminal.requestFocus(originalRequest)
        try await Task.sleep(for: .milliseconds(10))
        #expect(editor.isFirstResponder)
        terminal.requestFocus(UUID()) // Explicit restoration after the sheet closes.
        try await Task.sleep(for: .milliseconds(30))
        #expect(terminal.inputProxy.isFirstResponder)
        #expect(!editor.isFirstResponder)
    }
}
