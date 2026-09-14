import MetalKit
import SwiftUI
import TerminalCore
import UIKit

/// Identifies the shell receiving keyboard and paste input. A reconnect is a new
/// attempt even when it reuses the same tab.
public struct TerminalInputIdentity: Equatable, Sendable {
    public var sessionID: UUID
    public var attemptID: UUID

    public init(sessionID: UUID, attemptID: UUID) {
        self.sessionID = sessionID
        self.attemptID = attemptID
    }
}

public enum TerminalWorkspaceCommand: Equatable, Sendable {
    case newSession, closeSession, previousSession, nextSession, selectSession(Int), settings
}

/// Carries snapshots to the view without going through SwiftUI.
///
/// A snapshot published as observable state re-evaluates the screen's body, rebuilds the
/// representable and runs its update path — for every frame, to deliver a value only the
/// Metal view reads. Holding the surface itself is enough: the reference never changes, so
/// the body does not re-run, and the view is handed each snapshot directly.
@MainActor
public final class TerminalSurface {
    private weak var view: TerminalMetalView?
    private var latest: TerminalSnapshot?

    public init() {}

    public func publish(_ snapshot: TerminalSnapshot?) {
        latest = snapshot
        // The workspace gives every session a surface but reuses one renderer across its tabs,
        // so a hidden session still holds a reference to the view the visible one is drawing
        // in. Only the surface the view is currently showing may write to it.
        guard let view, view.isShowing(self) else { return }
        view.update(snapshot)
    }

    /// Called as the representable makes or updates its view; the last snapshot is replayed so
    /// a view created after one was published still has something to draw, and so does a view
    /// that has since drawn another session's grid.
    ///
    /// This used to skip the replay whenever it was handed the view it already held, because
    /// the representable calls it on every SwiftUI update and re-sending an unchanged grid is
    /// wasted work. That test asks whether the surface saw this view last, which is not the
    /// question: the workspace reuses one renderer for every tab, so a surface can hold a view
    /// that has since drawn another session. Returning to such a tab took the early exit and
    /// nothing repainted it — TerminalView.configure(_:) had just called setInputIdentity(_:),
    /// which blanks the grid for the incoming session, and ConnectionModel.publish(_:) drops a
    /// snapshot equal to the one it last sent, so an idle shell never offered a replacement.
    /// The tab came back empty until the shell wrote something new.
    func attach(_ view: TerminalMetalView) {
        self.view = view
        guard !view.isShowing(self) else { return }
        // Forced, because update(_:) compares revision, columns and rows, and a revision counts
        // one session's own updates. Two shells that have each drawn the same number of times
        // at the same size produce equal triples, so the dedupe would discard the handover and
        // leave the previous session's grid on screen.
        view.adopt(self, snapshot: latest)
    }
}

/// A terminal surface driven by immutable engine snapshots. All callbacks run on MainActor.
@MainActor
public struct TerminalView: UIViewRepresentable {
    public var surface: TerminalSurface
    public var configuration: TerminalConfiguration
    public var onInput: @MainActor (Data) -> Void
    public var onResize: @MainActor (Int, Int) -> Void
    public var onKey: (@MainActor (TerminalKey) -> Void)?
    public var onPaste: (@MainActor (String) -> Void)?
    public var onScroll: (@MainActor (Int) -> Void)?
    public var onCellSize: (@MainActor (Int, Int) -> Void)?
    public var onCopySelection: (@MainActor (TerminalSelection) async -> String)?
    public var inputIdentity: TerminalInputIdentity?
    public var focusRequest: UUID?
    public var onWorkspaceCommand: (@MainActor (TerminalWorkspaceCommand) -> Void)?

    public init(surface: TerminalSurface, configuration: TerminalConfiguration = .init(),
                onInput: @escaping @MainActor (Data) -> Void,
                onResize: @escaping @MainActor (Int, Int) -> Void,
                onKey: (@MainActor (TerminalKey) -> Void)? = nil,
                onPaste: (@MainActor (String) -> Void)? = nil,
                onScroll: (@MainActor (Int) -> Void)? = nil,
                onCellSize: (@MainActor (Int, Int) -> Void)? = nil,
                onCopySelection: (@MainActor (TerminalSelection) async -> String)? = nil,
                inputIdentity: TerminalInputIdentity? = nil,
                focusRequest: UUID? = nil,
                onWorkspaceCommand: (@MainActor (TerminalWorkspaceCommand) -> Void)? = nil) {
        self.surface = surface
        self.configuration = configuration
        self.onInput = onInput
        self.onResize = onResize
        self.onKey = onKey
        self.onPaste = onPaste
        self.onScroll = onScroll
        self.onCellSize = onCellSize
        self.onCopySelection = onCopySelection
        self.inputIdentity = inputIdentity
        self.focusRequest = focusRequest
        self.onWorkspaceCommand = onWorkspaceCommand
    }

    public func makeUIView(context: Context) -> TerminalMetalView {
        let view = TerminalMetalView(configuration: configuration)
        configure(view)
        return view
    }

    public func updateUIView(_ uiView: TerminalMetalView, context: Context) { configure(uiView) }

    public static func dismantleUIView(_ uiView: TerminalMetalView, coordinator: ()) { uiView.stop() }

    private func configure(_ view: TerminalMetalView) {
        view.setInputIdentity(inputIdentity)
        view.onInput = onInput
        view.onResize = onResize
        view.onKey = onKey
        view.onPaste = onPaste
        view.onScroll = onScroll
        view.onCellSize = onCellSize
        view.onCopySelection = onCopySelection
        view.onWorkspaceCommand = onWorkspaceCommand
        view.configure(configuration)
        surface.attach(view)
        view.requestFocus(focusRequest)
    }
}

/// UIKit keyboard input and selection around a damage-driven MTKView.
@MainActor
public final class TerminalMetalView: MTKView, UIKeyInput, @preconcurrency UIEditMenuInteractionDelegate,
    UIContextMenuInteractionDelegate, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    public var onInput: (@MainActor (Data) -> Void)?
    public var onResize: (@MainActor (Int, Int) -> Void)?
    public var onKey: (@MainActor (TerminalKey) -> Void)?
    public var onPaste: (@MainActor (String) -> Void)?
    public var onScroll: (@MainActor (Int) -> Void)?
    public var onCellSize: (@MainActor (Int, Int) -> Void)?
    public var onCopySelection: (@MainActor (TerminalSelection) async -> String)?
    public var onWorkspaceCommand: (@MainActor (TerminalWorkspaceCommand) -> Void)? {
        didSet {
            inputProxy.onWorkspaceCommand = onWorkspaceCommand == nil ? nil : { [weak self] command in
                guard let self else { return }
                self.resetTransientInput()
                self.onWorkspaceCommand?(command)
            }
        }
    }
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
    private var visibleViewport = CGRect.zero
    private var viewportPublicationScheduled = false
    private var inputIdentity: TerminalInputIdentity?
    private var inputGeneration: UInt64 = 0
    private var lastFocusRequest: UUID?
    private var pendingFocusRequest = false
    private var inputNeedsViewport = false
    private var permanentlyStopped = false
    private var keyboardScreenFrame: CGRect?
    private var pasteTasks: [UUID: Task<Void, Never>] = [:]
    // An asynchronous provider allows UIKit paste permission/loading to finish after
    // a tab transition. Its result must retain its original input generation.
    var pasteTextLoader: @MainActor () async -> String? = { UIPasteboard.general.string }
    private var snapshot: TerminalSnapshot?
    /// The surface whose grid this view currently shows; see TerminalSurface.attach(_:).
    private weak var showingSurface: TerminalSurface?
    private var cursorTimer: Timer?
    private var controlPressed = false
    private var selectionAnchor: Int?
    private var selectedRange: ClosedRange<Int>?
    private var panRemainder: CGFloat = 0
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private lazy var accessory = makeAccessory()
    private weak var controlButton: UIButton?
    private var errorLabel: UILabel?
    let inputProxy = TerminalTextInputView()

    public init(configuration: TerminalConfiguration = .init()) {
        self.terminalConfiguration = configuration
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm_srgb
        // A paused view must resize and redraw even when the shell sends no new
        // snapshot. Until that frame arrives, keep the previous pixels at their
        // native scale instead of stretching them with keyboard animations.
        autoResizeDrawable = false
        contentMode = .redraw
        layer.contentsGravity = .topLeft
        // Keep floating iPad keyboards from reducing the entire terminal viewport.
        keyboardLayoutGuide.followsUndockedKeyboard = false
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
        addSubview(inputProxy)
        inputProxy.inputAccessoryView = accessory
        inputProxy.onCommit = { [weak self] in self?.sendCommittedText($0) }
        inputProxy.onRemoteDelete = { [weak self] in self?.send(.backspace) }
        inputProxy.onCompositionChange = { [weak self] in self?.updateInputProxyLayout() }
        inputProxy.onResponderChange = { [weak self] in self?.requestViewportRefresh() }
        inputProxy.onHardwarePress = { [weak self] in self?.handleHardwarePress($0) ?? false }
        inputProxy.onTerminalCopy = { [weak self] in self?.copy(nil) }
        inputProxy.onTerminalPaste = { [weak self] in self?.paste(nil) }
        inputProxy.onTerminalSelectAll = { [weak self] in self?.selectAll(nil) }
        inputProxy.terminalCanCopy = { [weak self] in self?.selectedRange != nil }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(selectText(_:))))
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollHistory(_:)))
        scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.allowedScrollTypesMask = .all
        addGestureRecognizer(scroll)
        let pointerSelection = UIPanGestureRecognizer(target: self, action: #selector(selectText(_:)))
        pointerSelection.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerSelection.delegate = self
        addGestureRecognizer(pointerSelection)
        addInteraction(editMenu)
        addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(UIPointerInteraction(delegate: self))
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        configure(configuration)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(configuration:)") }

    public override var canBecomeFirstResponder: Bool { true }
    public override var inputAccessoryView: UIView? { accessory }
    public override var accessibilityValue: String? {
        get {
            let visible = snapshot.map(visibleText) ?? ""
            return inputProxy.hasComposition ? visible + "\n" + (inputProxy.text ?? "") : visible
        }
        set { }
    }
    public override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(visibleViewport, in: self) }
        set { }
    }

    @discardableResult public override func becomeFirstResponder() -> Bool {
        let result = inputProxy.becomeFirstResponder()
        requestViewportRefresh()
        return result
    }

    @discardableResult public override func resignFirstResponder() -> Bool {
        let result = inputProxy.resignFirstResponder()
        requestViewportRefresh()
        return result
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        requestViewportRefresh()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !permanentlyStopped else { return }
        if let screen = window?.screen {
            contentScaleFactor = screen.scale
            preferredFramesPerSecond = screen.maximumFramesPerSecond
            renderer?.configure(terminalConfiguration, scale: screen.scale)
            renderer?.isActive = UIApplication.shared.applicationState == .active
            restartCursorTimer()
            requestViewportRefresh(forcePublication: true)
            setNeedsDisplay()
        } else { suspend() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        synchronizeDrawableSize()
        errorLabel?.frame = bounds.insetBy(dx: 16, dy: 16)
        visibleViewport = TerminalViewportLayout.visibleBounds(
            in: bounds, safeAreaBottom: safeAreaInsets.bottom,
            keyboardFrame: keyboardFrameInTerminal(), accessoryFrame: accessoryFrameInTerminal()
        )
        updateInputProxyLayout()
        scheduleViewportPublication()
    }

    private func synchronizeDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: max(1, (bounds.width * contentScaleFactor).rounded()),
                          height: max(1, (bounds.height * contentScaleFactor).rounded()))
        guard drawableSize != size else { return }
        drawableSize = size
        setNeedsDisplay()
    }

    private func keyboardFrameInTerminal() -> CGRect? {
        if let window, let keyboardScreenFrame {
            let inWindow = window.convert(keyboardScreenFrame, from: window.screen.coordinateSpace)
            // On iPad the guide can retain the dismissed 52-point accessory even
            // after the keyboard's reported end frame has moved offscreen. That
            // stale rectangle must not shorten an otherwise restored terminal.
            // A live hardware-keyboard accessory is accounted for separately.
            guard !inWindow.intersection(window.bounds).isEmpty else { return nil }
        }
        return keyboardLayoutGuide.layoutFrame
    }

    private func updateInputProxyLayout() {
        guard let cell = renderer?.cellSize, visibleViewport.width > 0, visibleViewport.height > 0 else { return }
        let composing = inputProxy.hasComposition
        let font = TerminalFont.font(named: terminalConfiguration.fontName, size: terminalConfiguration.fontSize)
        if inputProxy.font != font { inputProxy.font = font }
        inputProxy.textColor = composing ? terminalConfiguration.theme.foreground.terminalUIColor : .clear
        inputProxy.backgroundColor = composing ? terminalConfiguration.theme.background.terminalUIColor : .clear
        inputProxy.tintColor = composing ? terminalConfiguration.theme.cursor.terminalUIColor : .clear
        inputProxy.markedTextStyle = [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                     .foregroundColor: terminalConfiguration.theme.foreground.terminalUIColor]
        let column = max(0, snapshot?.cursor.column ?? 0)
        let row = max(0, snapshot?.cursor.row ?? 0)
        let cursor = CGRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height,
                            width: cell.width, height: cell.height)
        let textWidth = ((inputProxy.text ?? "") as NSString).size(withAttributes: [.font: font]).width
        let width = min(visibleViewport.width, max(cell.width * 2, ceil(textWidth) + cell.width))
        let fitting = inputProxy.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let frame = TerminalTextInputLayout.frame(cursor: cursor, viewport: visibleViewport,
                                                  preferredSize: CGSize(width: width, height: ceil(fitting.height)),
                                                  avoiding: floatingKeyboardOcclusion())
        if inputProxy.frame != frame { inputProxy.frame = frame }
    }

    private func floatingKeyboardOcclusion() -> CGRect? {
        guard let window, let keyboardScreenFrame else { return nil }
        let inWindow = window.convert(keyboardScreenFrame, from: window.screen.coordinateSpace)
        let keyboard = convert(inWindow, from: window).intersection(visibleViewport)
        guard !keyboard.isNull, !keyboard.isEmpty,
              keyboard.width < visibleViewport.width - 1 else { return nil }
        if let accessory = accessoryFrameInTerminal(), accessory.intersects(visibleViewport) {
            return keyboard.union(accessory).intersection(visibleViewport)
        }
        return keyboard
    }

    private func accessoryFrameInTerminal() -> CGRect? {
        // UIKit may keep a dismissed accessory attached to its keyboard window.
        // Its old frame no longer obscures this terminal after focus is released.
        guard inputProxy.isFirstResponder,
              let terminalWindow = window, let accessoryWindow = accessory.window,
              terminalWindow.screen === accessoryWindow.screen, !accessoryWindow.isHidden else { return nil }
        var ancestor: UIView? = accessory
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0 { return nil }
            ancestor = view.superview
        }
        // The keyboard owns a separate UIWindow. UIView.convert requires a shared
        // window, so bridge through UIWindow's cross-window conversion explicitly.
        let inAccessoryWindow = accessory.convert(accessory.bounds, to: accessoryWindow)
        let inTerminalWindow = accessoryWindow.convert(inAccessoryWindow, to: terminalWindow)
        return convert(inTerminalWindow, from: terminalWindow)
    }

    private func requestViewportRefresh(forcePublication: Bool = false) {
        if forcePublication {
            lastGridSize = .zero
            lastCellPixels = .zero
        }
        setNeedsLayout()
        scheduleViewportPublication()
    }

    private func scheduleViewportPublication() {
        guard !viewportPublicationScheduled else { return }
        viewportPublicationScheduled = true
        // Read the latest geometry after UIKit and SwiftUI finish their layout changes;
        // queued callbacks must not replay an obsolete pre-keyboard PTY size.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.permanentlyStopped else { return }
            self.layoutIfNeeded()
            self.publishViewport()
            self.viewportPublicationScheduled = false
        }
    }

    private func publishViewport() {
        guard !permanentlyStopped else { return }
        guard let size = renderer?.cellSize,
              let grid = TerminalViewportLayout.gridSize(in: visibleViewport, cellSize: size) else { return }
        let pixels = CGSize(width: round(size.width * contentScaleFactor), height: round(size.height * contentScaleFactor))
        if pixels != lastCellPixels {
            lastCellPixels = pixels
            onCellSize?(Int(pixels.width), Int(pixels.height))
        }
        if grid != lastGridSize {
            lastGridSize = grid
            onResize?(Int(grid.width), Int(grid.height))
        }
        inputNeedsViewport = false
        if pendingFocusRequest, window != nil {
            pendingFocusRequest = false
            becomeFirstResponder()
        }
    }

    public func setInputIdentity(_ identity: TerminalInputIdentity?) {
        guard identity != inputIdentity else { return }
        resetTransientInput()
        inputIdentity = identity
        snapshot = nil
        // A new session's identity means the grid on screen is no longer anybody's, so the
        // surface that follows has to hand its own back rather than find the view still claimed.
        showingSurface = nil
        renderer?.update(nil)
        panRemainder = 0
        inputNeedsViewport = true
        requestViewportRefresh(forcePublication: true)
    }

    /// A token change requests focus after the active tab has a measured PTY size.
    /// Keeping the same token across normal snapshot updates preserves a hidden keyboard.
    public func requestFocus(_ token: UUID?) {
        guard let token else {
            // A modal may appear before a queued viewport publication. It owns
            // focus now, so that publication must not reactivate the terminal.
            pendingFocusRequest = false
            return
        }
        guard token != lastFocusRequest else { return }
        lastFocusRequest = token
        pendingFocusRequest = true
        requestViewportRefresh()
    }

    private func resetTransientInput() {
        inputGeneration &+= 1
        for task in pasteTasks.values { task.cancel() }
        pasteTasks.removeAll()
        inputProxy.cancelComposition()
        controlPressed = false
        controlButton?.isSelected = false
        clearSelection()
    }

    private func prepareForInput() -> Bool {
        guard !permanentlyStopped else { return false }
        if inputNeedsViewport {
            layoutIfNeeded()
            publishViewport()
        }
        return !inputNeedsViewport
    }

    public func configure(_ configuration: TerminalConfiguration) {
        let changed = configuration != terminalConfiguration
        terminalConfiguration = configuration
        renderer?.configure(configuration, scale: contentScaleFactor)
        backgroundColor = configuration.theme.background.terminalUIColor
        let color = configuration.theme.background.linearColor
        clearColor = MTLClearColor(red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: 1)
        keyboardAppearance = configuration.theme.background < 0x808080 ? .dark : .light
        inputProxy.keyboardAppearance = keyboardAppearance
        updateInputProxyLayout()
        if changed {
            restartCursorTimer()
            inputProxy.reloadInputViews()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    func isShowing(_ surface: TerminalSurface) -> Bool { showingSurface === surface }

    /// Hands the view to another session's surface. The grid has to be replayed whether or not
    /// it looks like the one already there, which is why this bypasses update(_:)'s dedupe.
    func adopt(_ surface: TerminalSurface, snapshot value: TerminalSnapshot?) {
        showingSurface = surface
        apply(value, force: true)
    }

    public func update(_ value: TerminalSnapshot?) { apply(value, force: false) }

    private func apply(_ value: TerminalSnapshot?, force: Bool) {
        guard force || snapshot?.revision != value?.revision || snapshot?.columns != value?.columns || snapshot?.rows != value?.rows else { return }
        if snapshot?.columns != value?.columns || snapshot?.rows != value?.rows || snapshot?.scrollbackOffset != value?.scrollbackOffset {
            clearSelection()
        }
        if snapshot?.columns != value?.columns || snapshot?.rows != value?.rows { requestViewportRefresh() }
        let cursorChanged = snapshot?.cursor != value?.cursor
        snapshot = value
        renderer?.update(value)
        updateInputProxyLayout()
        if let value {
            let color = value.defaultBackground.linearColor
            clearColor = MTLClearColor(red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: 1)
        }
        if cursorChanged { renderer?.cursorVisible = true }
        restartCursorTimer()
        setNeedsDisplay()
    }

    public func stop() {
        permanentlyStopped = true
        pendingFocusRequest = false
        suspend()
        inputProxy.resignFirstResponder()
        NotificationCenter.default.removeObserver(self)
        delegate = nil
        renderer = nil
        snapshot = nil
        showingSurface = nil
        onInput = nil
        onResize = nil
        onKey = nil
        onPaste = nil
        onScroll = nil
        onCellSize = nil
        onCopySelection = nil
        onWorkspaceCommand = nil
    }

    private func suspend() {
        resetTransientInput()
        cursorTimer?.invalidate()
        cursorTimer = nil
        renderer?.isActive = false
    }

    public func insertText(_ text: String) {
        inputProxy.insertText(text)
    }

    private func sendCommittedText(_ text: String) {
        guard prepareForInput() else { return }
        clearSelection()
        if text == "\n" { send(.enter); return }
        if controlPressed {
            controlPressed = false
            controlButton?.isSelected = false
            if let data = controlBytes(text) { onInput?(data); return }
        }
        onInput?(Data(text.utf8))
    }

    public func deleteBackward() { inputProxy.deleteBackward() }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if inputProxy.hasComposition { super.pressesBegan(presses, with: event); return }
        var unhandled = Set<UIPress>()
        for press in presses {
            if !handleHardwarePress(press) { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func handleHardwarePress(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        let modifiers = key.modifierFlags
        if modifiers.contains(.command) { return false }
        guard prepareForInput() else { return true }
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
        } else { return false }
        return true
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
            // The text comes from the parser, which answers after the output queued ahead of
            // this call. Copying a selection is not on the drawing path, so it can wait.
            Task { UIPasteboard.general.string = await onCopySelection(selection) }
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
        guard prepareForInput() else { return }
        inputProxy.commitComposition()
        clearSelection()
        let generation = inputGeneration
        let identity = inputIdentity
        let load = pasteTextLoader
        let taskID = UUID()
        pasteTasks[taskID] = Task { [weak self] in
            let text = await load()
            guard let self else { return }
            defer { self.pasteTasks[taskID] = nil }
            guard !Task.isCancelled, generation == self.inputGeneration,
                  identity == self.inputIdentity, !self.permanentlyStopped, let text else { return }
            self.deliverPaste(text)
        }
    }

    private func deliverPaste(_ text: String) {
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
        terminalEditMenu()
    }

    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                       configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let generation = inputGeneration
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, self.inputGeneration == generation else { return nil }
            return self.terminalEditMenu()
        }
    }

    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: UIPointerShape.verticalBeam(length: renderer?.cellSize.height ?? 20))
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        // This delegate is used only by pointer selection. Secondary-click belongs
        // to the context menu, and wheel/trackpad scrolling has its own recognizer.
        event.buttonMask.contains(.primary)
    }

    private func terminalEditMenu() -> UIMenu {
        let generation = inputGeneration
        func action(_ title: String, image: UIImage? = nil, perform: @escaping @MainActor (TerminalMetalView) -> Void) -> UIAction {
            UIAction(title: title, image: image) { [weak self] _ in
                guard let self, self.inputGeneration == generation, !self.permanentlyStopped else { return }
                perform(self)
            }
        }
        var actions: [UIMenuElement] = []
        if selectedRange != nil {
            actions.append(action("Copy", image: UIImage(systemName: "doc.on.doc")) { $0.copy(nil) })
        }
        actions.append(action("Paste", image: UIImage(systemName: "doc.on.clipboard")) { $0.paste(nil) })
        actions.append(action("Select All") { $0.selectAll(nil) })
        return UIMenu(children: actions)
    }

    private func send(_ key: TerminalKey, modifiers: UIKeyModifierFlags = []) {
        guard prepareForInput() else { return }
        if inputProxy.consumeTerminalKey(key) { return }
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

    @objc private func selectText(_ gesture: UIGestureRecognizer) {
        guard !inputProxy.hasComposition else { return }
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
        guard !inputProxy.hasComposition else { return }
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

    @objc private func resignedActive() { suspend() }
    @objc private func keyboardFrameChanged(_ notification: Notification) {
        if let screen = notification.object as? UIScreen, let window, screen !== window.screen { return }
        keyboardScreenFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        requestViewportRefresh()
    }
    @objc private func memoryWarning() {
        renderer?.purgeCaches()
        setNeedsDisplay()
    }
    @objc private func becameActive() {
        guard !permanentlyStopped else { return }
        renderer?.isActive = window != nil
        requestViewportRefresh(forcePublication: true)
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
        // `.keyboard` draws the same translucent material the software keyboard sits on, which
        // the opaque `.secondarySystemBackground` band used to hide. That band met the terminal
        // as a hard square edge while every button on it is rounded, and the terminal surface
        // above is clipped to a 14pt radius — three corner treatments in one strip. Letting the
        // system material show through removes the edge instead of adding a fourth.
        let container = TerminalAccessoryView(frame: CGRect(x: 0, y: 0, width: 390, height: 52), inputViewStyle: .keyboard)
        container.backgroundColor = .clear
        container.isOpaque = false
        container.onGeometryChange = { [weak self] in self?.requestViewportRefresh() }
        container.accessibilityIdentifier = "terminalAccessory"
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
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
            return button
        }
        let control = button("Ctrl") { [weak self] in
            guard let self else { return }
            self.inputProxy.cancelComposition()
            self.controlPressed.toggle()
            self.controlButton?.isSelected = self.controlPressed
        }
        control.accessibilityLabel = "Control modifier"
        control.accessibilityIdentifier = "terminalAccessoryControl"
        controlButton = control
        let keys: [(String, TerminalKey)] = [("Esc", .escape), ("Tab", .tab), ("←", .left), ("↓", .down), ("↑", .up), ("→", .right)]
        for (title, key) in keys { _ = button(title) { [weak self] in self?.send(key) } }
        for text in ["|", "~"] { _ = button(text) { [weak self] in self?.inputProxy.insertAccessoryText(text) } }
        let dismiss = button("⌄") { [weak self] in self?.resignFirstResponder() }
        dismiss.accessibilityLabel = "Hide keyboard"
        dismiss.accessibilityIdentifier = "terminalDismissKeyboard"
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

/// UIKit can reattach the accessory after scene activation without resizing the
/// SwiftUI representable. Its actual geometry is another viewport invalidation source.
@MainActor
private final class TerminalAccessoryView: UIInputView {
    var onGeometryChange: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onGeometryChange?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onGeometryChange?()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onGeometryChange?()
    }
}
