import MetalKit
import SwiftUI
import TerminalCore
import UIKit

/// A terminal surface driven by immutable engine snapshots. All callbacks run on MainActor.
@MainActor
public struct TerminalView: UIViewRepresentable {
    public var snapshot: TerminalSnapshot?
    public var configuration: TerminalConfiguration
    public var onInput: @MainActor (Data) -> Void
    public var onResize: @MainActor (Int, Int) -> Void
    public var onKey: (@MainActor (TerminalKey) -> Void)?
    public var onPaste: (@MainActor (String) -> Void)?
    public var onScroll: (@MainActor (Int) -> Void)?
    public var onCellSize: (@MainActor (Int, Int) -> Void)?
    public var onCopySelection: (@MainActor (TerminalSelection) -> String)?

    public init(snapshot: TerminalSnapshot?, configuration: TerminalConfiguration = .init(),
                onInput: @escaping @MainActor (Data) -> Void,
                onResize: @escaping @MainActor (Int, Int) -> Void,
                onKey: (@MainActor (TerminalKey) -> Void)? = nil,
                onPaste: (@MainActor (String) -> Void)? = nil,
                onScroll: (@MainActor (Int) -> Void)? = nil,
                onCellSize: (@MainActor (Int, Int) -> Void)? = nil,
                onCopySelection: (@MainActor (TerminalSelection) -> String)? = nil) {
        self.snapshot = snapshot
        self.configuration = configuration
        self.onInput = onInput
        self.onResize = onResize
        self.onKey = onKey
        self.onPaste = onPaste
        self.onScroll = onScroll
        self.onCellSize = onCellSize
        self.onCopySelection = onCopySelection
    }

    public func makeUIView(context: Context) -> TerminalMetalView {
        let view = TerminalMetalView(configuration: configuration)
        configure(view)
        return view
    }

    public func updateUIView(_ uiView: TerminalMetalView, context: Context) { configure(uiView) }

    public static func dismantleUIView(_ uiView: TerminalMetalView, coordinator: ()) { uiView.stop() }

    private func configure(_ view: TerminalMetalView) {
        view.onInput = onInput
        view.onResize = onResize
        view.onKey = onKey
        view.onPaste = onPaste
        view.onScroll = onScroll
        view.onCellSize = onCellSize
        view.onCopySelection = onCopySelection
        view.configure(configuration)
        view.update(snapshot)
    }
}

/// UIKit keyboard input and selection around a damage-driven MTKView.
@MainActor
public final class TerminalMetalView: MTKView, UIKeyInput, @preconcurrency UIEditMenuInteractionDelegate {
    public var onInput: (@MainActor (Data) -> Void)?
    public var onResize: (@MainActor (Int, Int) -> Void)?
    public var onKey: (@MainActor (TerminalKey) -> Void)?
    public var onPaste: (@MainActor (String) -> Void)?
    public var onScroll: (@MainActor (Int) -> Void)?
    public var onCellSize: (@MainActor (Int, Int) -> Void)?
    public var onCopySelection: (@MainActor (TerminalSelection) -> String)?
    public var hasText: Bool { true }
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var keyboardType: UIKeyboardType = .default
    public var keyboardAppearance: UIKeyboardAppearance = .dark
    public var returnKeyType: UIReturnKeyType = .default
    public var enablesReturnKeyAutomatically = false

    private var renderer: MetalRenderer?
    private var terminalConfiguration: TerminalConfiguration
    private var lastGridSize = CGSize.zero
    private var lastCellPixels = CGSize.zero
    private var snapshot: TerminalSnapshot?
    private var cursorTimer: Timer?
    private var controlPressed = false
    private var selectionAnchor: Int?
    private var selectedRange: ClosedRange<Int>?
    private var panRemainder: CGFloat = 0
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private lazy var accessory = makeAccessory()
    private weak var controlButton: UIButton?
    private var errorLabel: UILabel?

    public init(configuration: TerminalConfiguration = .init()) {
        self.terminalConfiguration = configuration
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm_srgb
        autoResizeDrawable = true
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityIdentifier = "terminal"
        accessibilityTraits = [.allowsDirectInteraction]
        if let device {
            do {
                let renderer = try MetalRenderer(device: device, configuration: configuration, scale: contentScaleFactor)
                self.renderer = renderer
                delegate = renderer
            } catch { showError("Terminal rendering could not start: \(error.localizedDescription)") }
        } else { showError("Metal is unavailable on this device.") }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(selectText(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrollHistory(_:))))
        addInteraction(editMenu)
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        configure(configuration)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(configuration:)") }

    public override var canBecomeFirstResponder: Bool { true }
    public override var inputAccessoryView: UIView? { accessory }
    public override var accessibilityValue: String? {
        get { snapshot.map(visibleText) }
        set { }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.screen {
            contentScaleFactor = screen.scale
            preferredFramesPerSecond = screen.maximumFramesPerSecond
            renderer?.configure(terminalConfiguration, scale: screen.scale)
            renderer?.isActive = UIApplication.shared.applicationState == .active
            restartCursorTimer()
            setNeedsLayout()
            setNeedsDisplay()
        } else { stop() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        errorLabel?.frame = bounds.insetBy(dx: 16, dy: 16)
        guard let size = renderer?.cellSize, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let grid = CGSize(width: max(2, floor(bounds.width / size.width)), height: max(1, floor(bounds.height / size.height)))
        let pixels = CGSize(width: round(size.width * contentScaleFactor), height: round(size.height * contentScaleFactor))
        // Dispatch out of SwiftUI's update/layout transaction before publishing engine state.
        if pixels != lastCellPixels {
            lastCellPixels = pixels
            DispatchQueue.main.async { [weak self] in self?.onCellSize?(Int(pixels.width), Int(pixels.height)) }
        }
        if grid != lastGridSize {
            lastGridSize = grid
            DispatchQueue.main.async { [weak self] in self?.onResize?(Int(grid.width), Int(grid.height)) }
        }
    }

    public func configure(_ configuration: TerminalConfiguration) {
        let changed = configuration != terminalConfiguration
        terminalConfiguration = configuration
        renderer?.configure(configuration, scale: contentScaleFactor)
        backgroundColor = configuration.theme.background.terminalUIColor
        let color = configuration.theme.background.linearColor
        clearColor = MTLClearColor(red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: 1)
        keyboardAppearance = configuration.theme.background < 0x808080 ? .dark : .light
        if changed {
            restartCursorTimer()
            reloadInputViews()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    public func update(_ value: TerminalSnapshot?) {
        guard snapshot?.revision != value?.revision || snapshot?.columns != value?.columns || snapshot?.rows != value?.rows else { return }
        if snapshot?.columns != value?.columns || snapshot?.rows != value?.rows || snapshot?.scrollbackOffset != value?.scrollbackOffset {
            clearSelection()
        }
        let cursorChanged = snapshot?.cursor != value?.cursor
        snapshot = value
        renderer?.update(value)
        if let value {
            let color = value.defaultBackground.linearColor
            clearColor = MTLClearColor(red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: 1)
        }
        if cursorChanged { renderer?.cursorVisible = true }
        restartCursorTimer()
        setNeedsDisplay()
    }

    public func stop() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        renderer?.isActive = false
    }

    public func insertText(_ text: String) {
        clearSelection()
        if text == "\n" { send(.enter); return }
        if controlPressed {
            controlPressed = false
            controlButton?.isSelected = false
            if let data = controlBytes(text) { onInput?(data); return }
        }
        onInput?(Data(text.utf8))
    }

    public func deleteBackward() { send(.backspace) }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            let modifiers = key.modifierFlags
            if modifiers.contains(.command) { unhandled.insert(press); continue }
            if let terminalKey = terminalKey(for: key.keyCode) {
                send(terminalKey, modifiers: modifiers)
            } else if let sequence = functionSequence(for: key.keyCode, modifiers: modifiers) {
                clearSelection()
                onInput?(Data(sequence.utf8))
            } else if modifiers.contains(.control), let data = controlBytes(key.charactersIgnoringModifiers) {
                clearSelection()
                onInput?(modifiers.contains(.alternate) ? Data([0x1B]) + data : data)
            } else if modifiers.contains(.alternate), !key.charactersIgnoringModifiers.isEmpty {
                clearSelection()
                onInput?(Data(("\u{1B}" + key.charactersIgnoringModifiers).utf8))
            } else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    public override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:))),
         UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))),
         UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:)))]
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selectedRange != nil }
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        if action == #selector(selectAll(_:)) { return snapshot != nil }
        return false
    }

    public override func copy(_ sender: Any?) {
        guard let range = selectedRange, let snapshot else { return }
        if let onCopySelection {
            let selection = TerminalSelection(
                start: TerminalPosition(column: range.lowerBound % snapshot.columns, row: range.lowerBound / snapshot.columns),
                end: TerminalPosition(column: range.upperBound % snapshot.columns + 1, row: range.upperBound / snapshot.columns)
            )
            UIPasteboard.general.string = onCopySelection(selection)
            return
        }
        var result: [String] = []
        let startRow = range.lowerBound / snapshot.columns
        let endRow = range.upperBound / snapshot.columns
        for row in startRow...endRow {
            let start = row == startRow ? range.lowerBound % snapshot.columns : 0
            let end = row == endRow ? range.upperBound % snapshot.columns : snapshot.columns - 1
            var line = ""
            for column in start...end {
                let cell = snapshot[column, row]
                if cell.width > 0 { line += cell.text }
            }
            while line.last == " " { line.removeLast() }
            result.append(line)
        }
        UIPasteboard.general.string = result.joined(separator: "\n")
    }

    public override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        clearSelection()
        if let onPaste { onPaste(text) }
        else {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let safe = String(normalized.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\n" || $0 == "\t" })
                .replacingOccurrences(of: "\n", with: "\r")
            let data = snapshot?.bracketedPaste == true ? "\u{1B}[200~" + safe + "\u{1B}[201~" : safe
            onInput?(Data(data.utf8))
        }
    }

    public override func selectAll(_ sender: Any?) {
        guard let snapshot, !snapshot.cells.isEmpty else { return }
        selectedRange = 0...(snapshot.cells.count - 1)
        renderer?.selection = selectedRange
        setNeedsDisplay()
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                    suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = []
        if selectedRange != nil {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(nil) })
        }
        actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste(nil) })
        actions.append(UIAction(title: "Select All") { [weak self] _ in self?.selectAll(nil) })
        return UIMenu(children: actions)
    }

    private func send(_ key: TerminalKey, modifiers: UIKeyModifierFlags = []) {
        clearSelection()
        var significant = modifiers.intersection([.shift, .control, .alternate])
        if controlPressed {
            significant.insert(.control)
            controlPressed = false
            controlButton?.isSelected = false
        }
        if significant.isEmpty, let onKey { onKey(key); return }
        let modifier = 1 + (significant.contains(.shift) ? 1 : 0) + (significant.contains(.alternate) ? 2 : 0) + (significant.contains(.control) ? 4 : 0)
        let normalPrefix = snapshot?.applicationCursor == true ? "\u{1B}O" : "\u{1B}["
        func directional(_ suffix: String) -> String {
            modifier == 1 ? normalPrefix + suffix : "\u{1B}[1;\(modifier)" + suffix
        }
        let text: String
        switch key {
        case .escape: text = significant.contains(.alternate) ? "\u{1B}\u{1B}" : "\u{1B}"
        case .tab: text = significant.contains(.shift) ? "\u{1B}[Z" : (significant.contains(.alternate) ? "\u{1B}\t" : "\t")
        case .enter: text = significant.contains(.alternate) ? "\u{1B}\r" : "\r"
        case .backspace: text = significant.contains(.alternate) ? "\u{1B}\u{7F}" : "\u{7F}"
        case .up: text = directional("A")
        case .down: text = directional("B")
        case .right: text = directional("C")
        case .left: text = directional("D")
        case .home: text = directional("H")
        case .end: text = directional("F")
        case .pageUp: text = modifier == 1 ? "\u{1B}[5~" : "\u{1B}[5;\(modifier)~"
        case .pageDown: text = modifier == 1 ? "\u{1B}[6~" : "\u{1B}[6;\(modifier)~"
        }
        onInput?(Data(text.utf8))
    }

    private func terminalKey(for code: UIKeyboardHIDUsage) -> TerminalKey? {
        switch code {
        case .keyboardEscape: .escape
        case .keyboardTab: .tab
        case .keyboardReturnOrEnter, .keypadEnter: .enter
        case .keyboardDeleteOrBackspace: .backspace
        case .keyboardUpArrow: .up
        case .keyboardDownArrow: .down
        case .keyboardLeftArrow: .left
        case .keyboardRightArrow: .right
        case .keyboardHome: .home
        case .keyboardEnd: .end
        case .keyboardPageUp: .pageUp
        case .keyboardPageDown: .pageDown
        default: nil
        }
    }

    private func functionSequence(for code: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> String? {
        let modifier = 1 + (modifiers.contains(.shift) ? 1 : 0) + (modifiers.contains(.alternate) ? 2 : 0) + (modifiers.contains(.control) ? 4 : 0)
        let suffix = modifier == 1 ? "~" : ";\(modifier)~"
        switch code {
        case .keyboardInsert: return "\u{1B}[2" + suffix
        case .keyboardDeleteForward: return "\u{1B}[3" + suffix
        case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4:
            let index = Int(code.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue)
            let letter = ["P", "Q", "R", "S"][index]
            return modifier == 1 ? "\u{1B}O" + letter : "\u{1B}[1;\(modifier)" + letter
        case .keyboardF5, .keyboardF6, .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
            let index = Int(code.rawValue - UIKeyboardHIDUsage.keyboardF5.rawValue)
            return "\u{1B}[\([15, 17, 18, 19, 20, 21, 23, 24][index])" + suffix
        default: return nil
        }
    }

    private func controlBytes(_ text: String) -> Data? {
        guard let scalar = text.uppercased().unicodeScalars.first else { return nil }
        if scalar.value == 0x20 || scalar.value == 0x32 { return Data([0]) }
        if (0x33...0x37).contains(scalar.value) { return Data([UInt8(scalar.value - 0x18)]) }
        if scalar.value == 0x38 { return Data([127]) }
        if scalar.value == 0x3F { return Data([127]) }
        if (0x40...0x5F).contains(scalar.value) { return Data([UInt8(scalar.value & 0x1F)]) }
        return nil
    }

    @objc private func tapped() { clearSelection(); becomeFirstResponder() }

    @objc private func selectText(_ gesture: UILongPressGestureRecognizer) {
        guard let snapshot, snapshot.columns > 0, snapshot.rows > 0, let size = renderer?.cellSize else { return }
        let point = gesture.location(in: self)
        let column = min(snapshot.columns - 1, max(0, Int(point.x / size.width)))
        let row = min(snapshot.rows - 1, max(0, Int(point.y / size.height)))
        var index = row * snapshot.columns + column
        while index > row * snapshot.columns && snapshot.cells[index].width == 0 { index -= 1 }
        if gesture.state == .began { selectionAnchor = index; becomeFirstResponder() }
        guard let anchor = selectionAnchor else { return }
        selectedRange = min(anchor, index)...max(anchor, index)
        renderer?.selection = selectedRange
        setNeedsDisplay()
        if gesture.state == .ended {
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
    }

    @objc private func scrollHistory(_ gesture: UIPanGestureRecognizer) {
        guard let height = renderer?.cellSize.height, height > 0, let onScroll else { return }
        if gesture.state == .began { panRemainder = 0; clearSelection() }
        let amount = gesture.translation(in: self).y + panRemainder
        let lines = Int(amount / height)
        panRemainder = amount - CGFloat(lines) * height
        gesture.setTranslation(.zero, in: self)
        if lines != 0 { onScroll(lines) }
    }

    private func clearSelection() {
        guard selectedRange != nil else { return }
        selectedRange = nil
        selectionAnchor = nil
        renderer?.selection = nil
        editMenu.dismissMenu()
        setNeedsDisplay()
    }

    private func restartCursorTimer() {
        let blinkingCursor = terminalConfiguration.cursorBlinks && snapshot?.cursor.blinking == true && snapshot?.cursor.visible == true
            && snapshot?.scrollbackOffset == 0
        let shouldBlink = (blinkingCursor || renderer?.hasBlinkingText == true) && window != nil && renderer?.isActive == true
        guard shouldBlink else {
            cursorTimer?.invalidate()
            cursorTimer = nil
            renderer?.cursorVisible = true
            return
        }
        guard cursorTimer == nil else { return }
        cursorTimer = Timer.scheduledTimer(timeInterval: 0.55, target: self, selector: #selector(blinkCursor), userInfo: nil, repeats: true)
    }

    @objc private func blinkCursor() {
        guard let renderer, renderer.isActive else { return }
        renderer.cursorVisible.toggle()
        setNeedsDisplay()
    }

    @objc private func resignedActive() { stop() }
    @objc private func memoryWarning() {
        renderer?.purgeCaches()
        setNeedsDisplay()
    }
    @objc private func becameActive() {
        renderer?.isActive = window != nil
        restartCursorTimer()
        setNeedsDisplay()
    }

    private func visibleText(_ snapshot: TerminalSnapshot) -> String {
        guard snapshot.columns > 0, snapshot.cells.count >= snapshot.columns * snapshot.rows else { return "" }
        return (0..<snapshot.rows).map { row in
            var line = (0..<snapshot.columns).map { snapshot[$0, row] }.filter { $0.width > 0 }.map(\.text).joined()
            while line.last == " " { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    private func makeAccessory() -> UIView {
        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 44), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        container.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        func button(_ title: String, action: @escaping @MainActor () -> Void) -> UIButton {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.gray()
            configuration.title = title
            configuration.cornerStyle = .medium
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            button.configuration = configuration
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
            stack.addArrangedSubview(button)
            return button
        }
        let control = button("Ctrl") { [weak self] in
            guard let self else { return }
            self.controlPressed.toggle()
            self.controlButton?.isSelected = self.controlPressed
        }
        control.accessibilityLabel = "Control modifier"
        controlButton = control
        let keys: [(String, TerminalKey)] = [("Esc", .escape), ("Tab", .tab), ("←", .left), ("↓", .down), ("↑", .up), ("→", .right)]
        for (title, key) in keys { _ = button(title) { [weak self] in self?.send(key) } }
        for text in ["|", "~"] { _ = button(text) { [weak self] in self?.insertText(text) } }
        let dismiss = button("⌄") { [weak self] in self?.resignFirstResponder() }
        dismiss.accessibilityLabel = "Hide keyboard"
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -8)
        ])
        return container
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        addSubview(label)
        errorLabel = label
    }
}
