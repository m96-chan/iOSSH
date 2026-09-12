import TerminalCore
import UIKit

/// A native UITextInput editor for the unconfirmed part of terminal input. UIKit owns
/// positions, tokenization, Japanese conversion, and candidate geometry; the remote
/// terminal only receives confirmed text. Acknowledged text is cleared between edits.
@MainActor
final class TerminalTextInputView: UITextView, UITextViewDelegate {
    var onCommit: ((String) -> Void)?
    var onRemoteDelete: (() -> Void)?
    var onCompositionChange: (() -> Void)?
    var onResponderChange: (() -> Void)?
    var onHardwarePress: ((UIPress) -> Bool)?
    var onTerminalCopy: (() -> Void)?
    var onTerminalPaste: (() -> Void)?
    var onTerminalSelectAll: (() -> Void)?
    var terminalCanCopy: (() -> Bool)?
    var onWorkspaceCommand: ((TerminalWorkspaceCommand) -> Void)?

    private var editDepth = 0
    private var compositionActive = false
    private var acknowledgedText = ""
    private var clearScheduled = false
    private var confirmationReturnPending = false
    private var clearing = false

    var hasComposition: Bool { compositionActive || markedTextRange != nil }
    // The local buffer is emptied after confirmation; the remote terminal may still
    // contain editable text. Keep the software keyboard's Backspace action available.
    override var hasText: Bool { true }

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .default
        returnKeyType = .default
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        contentInset = .zero
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hasComposition && super.point(inside: point, with: event)
    }

    @discardableResult override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        onResponderChange?()
        return result
    }

    @discardableResult override func resignFirstResponder() -> Bool {
        // Dismissing a screen or backgrounding must not send unconfirmed text to a
        // disconnected shell (or a newly opened session).
        cancelComposition()
        let result = super.resignFirstResponder()
        onResponderChange?()
        return result
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if editDepth > 0 { super.setMarkedText(markedText, selectedRange: selectedRange); return }
        guard let markedText, !markedText.isEmpty else { cancelComposition(); return }
        clearAcknowledgedTextBeforeEdit()
        compositionActive = true
        performEdit(commitWhenUnmarked: false) {
            super.setMarkedText(markedText, selectedRange: TerminalTextInputRange.selection(selectedRange, in: markedText))
        }
    }

    override func unmarkText() {
        guard !clearing, editDepth == 0 else { super.unmarkText(); return }
        performEdit(commitWhenUnmarked: true) {
            super.unmarkText()
        }
    }

    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        if editDepth > 0 { super.setAttributedMarkedText(markedText, selectedRange: selectedRange); return }
        guard let markedText, markedText.length > 0 else { cancelComposition(); return }
        clearAcknowledgedTextBeforeEdit()
        compositionActive = true
        performEdit(commitWhenUnmarked: false) {
            super.setAttributedMarkedText(markedText, selectedRange: TerminalTextInputRange.selection(selectedRange, in: markedText.string))
        }
    }

    override func insertText(_ text: String) {
        if editDepth > 0 { super.insertText(text); return }
        if text == "\n", hasComposition {
            commitComposition()
            return
        }
        if text == "\n", confirmationReturnPending { return }
        clearAcknowledgedTextBeforeEdit()
        performEdit(commitWhenUnmarked: true) {
            super.insertText(text)
        }
    }

    override func deleteBackward() {
        if editDepth > 0 { super.deleteBackward(); return }
        guard hasComposition else {
            clearAcknowledgedTextBeforeEdit()
            onRemoteDelete?()
            return
        }
        performEdit(commitWhenUnmarked: false) {
            let selected = TerminalTextInputRange.selection(selectedRange, in: text)
            if selected.length > 0 {
                if let range = nativeRange(selected) { super.replace(range, withText: "") }
            } else if selected.location > 0 {
                let range = (text as NSString).rangeOfComposedCharacterSequence(at: selected.location - 1)
                if let native = nativeRange(range) { super.replace(native, withText: "") }
            }
            restoreMarkAfterLocalEdit()
        }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        if editDepth > 0 { super.replace(range, withText: text); return }
        let wasComposing = hasComposition
        let offsets = NSRange(location: offset(from: beginningOfDocument, to: range.start),
                              length: offset(from: range.start, to: range.end))
        let safeRange = TerminalTextInputRange.selection(offsets, in: self.text)
        guard let native = nativeRange(safeRange) else { return }
        performEdit(commitWhenUnmarked: !wasComposing) {
            super.replace(native, withText: text)
            if wasComposing { restoreMarkAfterLocalEdit() }
        }
    }

    func commitComposition() {
        guard hasComposition else { return }
        unmarkText()
    }

    func insertAccessoryText(_ text: String) {
        commitComposition()
        insertText(text)
    }

    func cancelComposition() {
        guard !clearing else { return }
        clearing = true
        editDepth += 1
        compositionActive = false
        // Clear before unmarking: UIKit may otherwise interpret resignation as commit.
        super.text = ""
        super.unmarkText()
        selectedRange = NSRange(location: 0, length: 0)
        acknowledgedText = ""
        confirmationReturnPending = false
        editDepth -= 1
        clearing = false
        onCompositionChange?()
    }

    /// Accessory keys are explicit terminal actions. Escape cancels conversion; Return
    /// confirms it; Backspace edits locally. Other actions commit before being sent.
    func consumeTerminalKey(_ key: TerminalKey) -> Bool {
        guard hasComposition else { return false }
        switch key {
        case .escape: cancelComposition(); return true
        case .enter: commitComposition(); return true
        case .backspace: deleteBackward(); return true
        default: commitComposition(); return false
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            // The IME must receive conversion, candidate navigation, and Return keys.
            // Explicit Control shortcuts cancel preedit and retain terminal semantics.
            let controlShortcut = press.key?.modifierFlags.contains(.control) == true
                && press.key?.modifierFlags.contains(.command) != true
            if hasComposition && !controlShortcut {
                unhandled.insert(press)
            } else {
                if controlShortcut { cancelComposition() }
                if onHardwarePress?(press) != true { unhandled.insert(press) }
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func copy(_ sender: Any?) {
        if hasComposition { super.copy(sender) } else { onTerminalCopy?() }
    }

    override func paste(_ sender: Any?) {
        commitComposition()
        onTerminalPaste?()
    }

    override func selectAll(_ sender: Any?) {
        if hasComposition { super.selectAll(sender) } else { onTerminalSelectAll?() }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        guard onWorkspaceCommand != nil else { return commands }
        let definitions: [(String, UIKeyModifierFlags, String)] = [
            ("t", .command, "New Session"), ("w", .command, "Close Session"),
            ("[", [.command, .shift], "Previous Session"),
            ("]", [.command, .shift], "Next Session"),
            ("1", .command, "Session 1"), ("2", .command, "Session 2"),
            ("3", .command, "Session 3"), ("4", .command, "Session 4"),
            (",", .command, "Settings")
        ]
        commands += definitions.map { input, modifiers, title in
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(performWorkspaceCommand(_:)))
            command.discoverabilityTitle = title
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return commands
    }

    @objc func performWorkspaceCommand(_ sender: UIKeyCommand) {
        guard isFirstResponder,
              let command = TerminalWorkspaceCommand.from(input: sender.input, modifiers: sender.modifierFlags) else { return }
        onWorkspaceCommand?(command)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(performWorkspaceCommand(_:)) { return onWorkspaceCommand != nil && isFirstResponder }
        if hasComposition { return super.canPerformAction(action, withSender: sender) }
        if action == #selector(copy(_:)) { return terminalCanCopy?() == true }
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        if action == #selector(selectAll(_:)) { return true }
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        guard editDepth == 0, !clearing else { return }
        synchronize(commitWhenUnmarked: true)
    }

    private func performEdit(commitWhenUnmarked: Bool, _ edit: () -> Void) {
        editDepth += 1
        edit()
        editDepth -= 1
        if editDepth == 0 { synchronize(commitWhenUnmarked: commitWhenUnmarked) }
    }

    private func synchronize(commitWhenUnmarked: Bool) {
        if markedTextRange != nil { compositionActive = true }
        if commitWhenUnmarked && markedTextRange == nil {
            let confirmedComposition = compositionActive && !(text ?? "").isEmpty
            compositionActive = false
            // Public input methods and native text-storage/delegate edits converge
            // here. Protect the confirmation Return before delivering any callback.
            if confirmedComposition { suppressConfirmationReturnForCurrentEvent() }
            // UIKit can deliver didChange and unmark callbacks for the same edit.
            // Acknowledging before callback delivery prevents duplicate UTF-8 output.
            let current = text ?? ""
            let previousBytes = acknowledgedText.utf8
            if current.utf8.starts(with: previousBytes) {
                let suffix = String(decoding: current.utf8.dropFirst(previousBytes.count), as: UTF8.self)
                acknowledgedText = current
                onCompositionChange?()
                if !suffix.isEmpty { onCommit?(suffix) }
            } else {
                acknowledgedText = current
                onCompositionChange?()
            }
            scheduleAcknowledgedTextClear()
        } else { onCompositionChange?() }
    }

    private func restoreMarkAfterLocalEdit() {
        guard !text.isEmpty else {
            compositionActive = false
            super.unmarkText()
            return
        }
        guard markedTextRange == nil else { return }
        let selection = TerminalTextInputRange.selection(selectedRange, in: text)
        let pending = text ?? ""
        selectedRange = NSRange(location: 0, length: pending.utf16.count)
        super.setMarkedText(pending, selectedRange: selection)
        compositionActive = true
    }

    private func nativeRange(_ range: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length) else { return nil }
        return textRange(from: start, to: end)
    }

    private func clearAcknowledgedTextBeforeEdit() {
        guard editDepth == 0, !hasComposition, !acknowledgedText.isEmpty else { return }
        clearing = true
        super.text = ""
        selectedRange = NSRange(location: 0, length: 0)
        acknowledgedText = ""
        clearing = false
    }

    private func scheduleAcknowledgedTextClear() {
        guard !clearScheduled else { return }
        clearScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearScheduled = false
            self.clearAcknowledgedTextBeforeEdit()
        }
    }

    private func suppressConfirmationReturnForCurrentEvent() {
        confirmationReturnPending = true
        DispatchQueue.main.async { [weak self] in self?.confirmationReturnPending = false }
    }
}

enum TerminalTextInputRange {
    /// UITextInput uses UTF-16 offsets. Never split a surrogate pair or composed
    /// character when a replacement or selection arrives at an intermediate offset.
    static func selection(_ proposed: NSRange, in text: String) -> NSRange {
        let string = text as NSString
        let start = min(proposed.location, string.length)
        let length = min(proposed.length, string.length - start)
        if length > 0 { return string.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length)) }
        guard start > 0, start < string.length else { return NSRange(location: start, length: 0) }
        let character = string.rangeOfComposedCharacterSequence(at: start)
        return NSRange(location: start == character.location ? start : NSMaxRange(character), length: 0)
    }
}

enum TerminalTextInputLayout {
    static func frame(cursor: CGRect, viewport: CGRect, preferredSize: CGSize, avoiding occlusion: CGRect? = nil) -> CGRect {
        let width = min(viewport.width, max(cursor.width, preferredSize.width))
        let height = min(viewport.height, max(cursor.height, preferredSize.height))
        func fit(in area: CGRect) -> CGRect {
            let width = min(width, area.width)
            let height = min(height, area.height)
            return CGRect(x: max(area.minX, min(cursor.minX, area.maxX - width)),
                          y: max(area.minY, min(cursor.minY, area.maxY - height)), width: width, height: height)
        }
        let normal = fit(in: viewport)
        guard let occlusion, normal.intersects(occlusion) else { return normal }
        let blocked = occlusion.intersection(viewport)
        guard !blocked.isNull, !blocked.isEmpty else { return normal }
        // A floating keyboard only occludes a local rectangle. Move the native
        // conversion/caret anchor into the nearest clear region, leaving the PTY
        // dimensions and all terminal rows unchanged.
        let regions = [
            CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: blocked.minY - viewport.minY),
            CGRect(x: viewport.minX, y: blocked.maxY, width: viewport.width, height: viewport.maxY - blocked.maxY),
            CGRect(x: viewport.minX, y: viewport.minY, width: blocked.minX - viewport.minX, height: viewport.height),
            CGRect(x: blocked.maxX, y: viewport.minY, width: viewport.maxX - blocked.maxX, height: viewport.height)
        ].filter { $0.width >= cursor.width && $0.height >= cursor.height }
        let fullSize = regions.filter { $0.width >= width && $0.height >= height }
        let candidates = (fullSize.isEmpty ? regions : fullSize).map(fit)
        return candidates.min {
            hypot($0.minX - normal.minX, $0.minY - normal.minY) < hypot($1.minX - normal.minX, $1.minY - normal.minY)
        } ?? normal
    }
}

extension TerminalWorkspaceCommand {
    static func from(input: String?, modifiers: UIKeyModifierFlags) -> Self? {
        // Ignore Caps Lock, but never consume shell Control/Option combinations.
        let modifiers = modifiers.intersection([.command, .shift, .control, .alternate])
        if modifiers == [.command, .shift] {
            if input == "[" || input == "{" { return .previousSession }
            if input == "]" || input == "}" { return .nextSession }
            return nil
        }
        guard modifiers == .command else { return nil }
        switch input?.lowercased() {
        case "t": return .newSession
        case "w": return .closeSession
        case ",": return .settings
        case "1": return .selectSession(0)
        case "2": return .selectSession(1)
        case "3": return .selectSession(2)
        case "4": return .selectSession(3)
        default: return nil
        }
    }
}
