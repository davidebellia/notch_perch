import AppKit
import QuartzCore
import ServiceManagement

final class DropView: NSView, CAAnimationDelegate {
    var onDrop: (([URL]) -> Void)?
    var onDragActiveChanged: ((Bool) -> Void)?
    private var hasActiveIncomingDrag = false
    var isExpanded = false { didSet { needsDisplay = true } }
    private let revealMask = CAShapeLayer()
    private var revealOriginWidth: CGFloat = 76
    private var revealOriginHeight: CGFloat = 8
    private var revealTarget: CGFloat = 1
    private var revealAnimationToken: String?
    private var revealCompletion: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        revealMask.fillColor = NSColor.black.cgColor
        layer?.mask = revealMask
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func layout() {
        super.layout()
        revealMask.frame = bounds
        if revealAnimationToken == nil { revealMask.path = path(for: revealTarget) }
    }

    func configureRevealOrigin(notchWidth: CGFloat, notchHeight: CGFloat) {
        revealOriginWidth = min(max(1, notchWidth), max(1, bounds.width))
        revealOriginHeight = min(max(1, notchHeight), max(1, bounds.height))
        if revealAnimationToken == nil { revealMask.path = path(for: revealTarget) }
    }

    func setRevealImmediately(_ fraction: CGFloat) {
        stopRevealAnimation()
        revealTarget = min(max(fraction, 0), 1)
        revealMask.path = path(for: revealTarget)
    }

    func animateReveal(to fraction: CGFloat, completion: ((Bool) -> Void)? = nil) {
        let target = min(max(fraction, 0), 1)
        let startPath = revealMask.presentation()?.path ?? revealMask.path ?? path(for: revealTarget)
        stopRevealAnimation()
        revealTarget = target
        let targetPath = path(for: target)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            revealMask.path = targetPath
            completion?(true)
            return
        }
        revealMask.path = targetPath
        let token = UUID().uuidString
        revealAnimationToken = token
        revealCompletion = completion
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = startPath
        animation.toValue = targetPath
        animation.duration = 0.24
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.delegate = self
        animation.setValue(token, forKey: "drop-reveal-token")
        revealMask.add(animation, forKey: "drop-reveal")
    }

    private func stopRevealAnimation() {
        revealAnimationToken = nil
        revealCompletion = nil
        revealMask.removeAnimation(forKey: "drop-reveal")
    }

    private func path(for fraction: CGFloat) -> CGPath {
        let bounds = self.bounds
        let width = revealOriginWidth + (bounds.width - revealOriginWidth) * fraction
        let height = revealOriginHeight + (bounds.height - revealOriginHeight) * fraction
        let left = bounds.midX - width / 2
        let right = bounds.midX + width / 2
        let top = bounds.maxY
        let bottom = max(bounds.minY, top - height)
        let radius = min(24 * fraction, width / 2, height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom + radius))
        path.addCurve(to: CGPoint(x: right - radius, y: bottom),
                      control1: CGPoint(x: right, y: bottom + radius * 0.45),
                      control2: CGPoint(x: right - radius * 0.45, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom + radius),
                      control1: CGPoint(x: left + radius * 0.45, y: bottom),
                      control2: CGPoint(x: left, y: bottom + radius * 0.45))
        path.closeSubpath()
        return path
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard let token = anim.value(forKey: "drop-reveal-token") as? String,
              token == revealAnimationToken else { return }
        revealAnimationToken = nil
        let completion = revealCompletion
        revealCompletion = nil
        completion?(flag)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isExpanded = true
        let accepted = !fileURLs(from: sender.draggingPasteboard).isEmpty
        setIncomingDragActive(accepted)
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !fileURLs(from: sender.draggingPasteboard).isEmpty
        setIncomingDragActive(accepted)
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isExpanded = false; setIncomingDragActive(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender.draggingPasteboard).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isExpanded = false
        setIncomingDragActive(false)
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { setIncomingDragActive(false) }
    private func setIncomingDragActive(_ active: Bool) {
        guard active != hasActiveIncomingDrag else { return }
        hasActiveIncomingDrag = active
        onDragActiveChanged?(active)
    }
    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(\.isFileURL)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
    }
}

final class ShelfWindowController: NSWindowController {
    private let store: ShelfStore
    private let root = DropView(frame: .zero)
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Drop files here")
    private var currentScreen: NSScreen?
    private var hideTimer: Timer?
    private var shelfShouldBeVisible = false
    private var interactionDepth = 0
    private var pinnedByIncomingDrag = false
    private var activeFileMoves: [UUID: VerifiedFileMove] = [:]

    init(store: ShelfStore) {
        self.store = store
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 128), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        super.init(window: panel)

        root.translatesAutoresizingMaskIntoConstraints = false
        root.onDrop = { [weak store] in store?.add($0) }
        root.onDragActiveChanged = { [weak self] active in self?.setIncomingDragActive(active) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .white
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let heading = NSTextField(labelWithString: "NotchPerch")
        heading.textColor = .white
        heading.font = .systemFont(ofSize: 11, weight: .bold)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(emptyLabel)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        panel.contentView = root
        store.changed = { [weak self] in self?.render() }
        render()
        panel.orderOut(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    @objc private func screensChanged() {
        if let currentScreen { positionPanel(on: currentScreen) }
    }

    func showShelf(at point: NSPoint? = nil) {
        let screen = point.flatMap(screen(containing:)) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        currentScreen = screen
        shelfShouldBeVisible = true
        hideTimer?.invalidate()
        hideTimer = nil
        guard let panel = window else { return }
        let target = panelFrame(on: screen)
        panel.setFrame(target, display: false)
        let notchWidth = screen.auxiliaryTopLeftArea.flatMap { left in
            screen.auxiliaryTopRightArea.map { right in max(1, right.minX - left.maxX) }
        } ?? 76
        root.configureRevealOrigin(notchWidth: notchWidth,
                                   notchHeight: screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 8)
        if !panel.isVisible {
            root.setRevealImmediately(0)
            panel.alphaValue = 1
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        }
        root.animateReveal(to: 1) { [weak self] finished in
            guard let self, finished, self.shelfShouldBeVisible else { return }
            self.window?.ignoresMouseEvents = false
        }
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let width = min(max(360, screen.safeAreaInsets.top > 0 ? 560 : 500), screen.frame.width - 32)
        let height = max(128, min(420, CGFloat(store.items.count) * 46 + 104))
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func positionPanel(on screen: NSScreen) {
        guard let panel = window else { return }
        let expanded = panelFrame(on: screen)
        panel.setFrame(expanded, display: true)
        let notchWidth = screen.auxiliaryTopLeftArea.flatMap { left in
            screen.auxiliaryTopRightArea.map { right in max(1, right.minX - left.maxX) }
        } ?? 76
        root.configureRevealOrigin(notchWidth: notchWidth,
                                   notchHeight: screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 8)
        if !panel.isVisible { root.setRevealImmediately(0) }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func triggerFrame(on screen: NSScreen) -> NSRect? {
        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              rightArea.minX > leftArea.maxX else { return nil }
        let notchHeight = min(screen.safeAreaInsets.top, 32)
        return NSRect(x: leftArea.maxX,
                      y: screen.frame.maxY - notchHeight,
                      width: rightArea.minX - leftArea.maxX,
                      height: notchHeight)
    }

    func updatePointer(_ point: NSPoint, duringDrag: Bool = false) {
        let pointedScreen = screen(containing: point) ?? currentScreen
        let inTrigger = pointedScreen.flatMap { triggerFrame(on: $0) }.map { $0.contains(point) } ?? false
        let inPanel = window?.isVisible == true && window?.frame.contains(point) == true
        if inTrigger || inPanel {
            hideTimer?.invalidate()
            hideTimer = nil
            if let pointedScreen, (inTrigger || !shelfShouldBeVisible) {
                if currentScreen?.frame != pointedScreen.frame || window?.isVisible != true || !shelfShouldBeVisible {
                    showShelf(at: point)
                }
            }
            if duringDrag { window?.ignoresMouseEvents = false }
        } else if window?.isVisible == true && interactionDepth == 0 {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        guard hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            guard let self, self.interactionDepth == 0 else { return }
            let point = NSEvent.mouseLocation
            let screen = self.screen(containing: point) ?? self.currentScreen
            let inTrigger = screen.flatMap { self.triggerFrame(on: $0) }.map { $0.contains(point) } ?? false
            let inPanel = self.window?.frame.contains(point) == true
            if !inTrigger && !inPanel { self.hideShelf() }
            self.hideTimer = nil
        }
    }

    private func hideShelf() {
        guard let panel = window, panel.isVisible else { return }
        shelfShouldBeVisible = false
        panel.ignoresMouseEvents = true
        root.animateReveal(to: 0) { [weak self] finished in
            guard let self, finished, !self.shelfShouldBeVisible else { return }
            self.window?.orderOut(nil)
        }
    }

    private func setIncomingDragActive(_ active: Bool) {
        if active == pinnedByIncomingDrag { return }
        pinnedByIncomingDrag = active
        if active { interactionBegan() } else { interactionEnded() }
    }

    func interactionBegan() {
        interactionDepth += 1
        hideTimer?.invalidate()
        hideTimer = nil
        if !shelfShouldBeVisible { showShelf(at: NSEvent.mouseLocation) }
    }

    func interactionEnded() {
        interactionDepth = max(0, interactionDepth - 1)
        if interactionDepth == 0 { scheduleHide() }
    }

    private func render() {
        stack.arrangedSubviews.dropFirst(2).forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        emptyLabel.isHidden = !store.items.isEmpty
        for item in store.items {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 9
            let drag = DragFileView(item: item, store: store) { [weak self] active in
                if active { self?.interactionBegan() } else { self?.interactionEnded() }
            } onTransactionCreated: { [weak self] transaction in
                guard let self else { return }
                self.activeFileMoves[transaction.id] = transaction
                transaction.onFinished = { [weak self] id, _ in self?.activeFileMoves.removeValue(forKey: id) }
            }
            drag.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(drag)
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeItem(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(item.identity)
            remove.bezelStyle = .rounded
            remove.font = .systemFont(ofSize: 10)
            remove.isBordered = true
            remove.bezelColor = .controlAccentColor
            remove.contentTintColor = .white
            remove.attributedTitle = NSAttributedString(string: "Remove", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            remove.setAccessibilityLabel("Remove reference to \(item.url.lastPathComponent); keep original file")
            row.addArrangedSubview(remove)
            stack.addArrangedSubview(row)
            if let notice = store.transferNotices[item.identity] {
                let status = NSTextField(labelWithString: notice)
                status.textColor = .systemOrange
                status.font = .systemFont(ofSize: 10)
                status.lineBreakMode = .byWordWrapping
                stack.addArrangedSubview(status)
            }
        }
        if let currentScreen { positionPanel(on: currentScreen) }
    }

    @objc private func removeItem(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let item = store.items.first(where: { $0.identity == key }) else { return }
        store.remove(item)
    }
}

final class DragFileView: NSView {
    let item: ShelfItem
    private let store: ShelfStore
    private let onDragStateChanged: (Bool) -> Void
    private let onTransactionCreated: (VerifiedFileMove) -> Void
    private var start: NSPoint?
    private var activeMove: VerifiedFileMove?
    init(item: ShelfItem, store: ShelfStore, onDragStateChanged: @escaping (Bool) -> Void, onTransactionCreated: @escaping (VerifiedFileMove) -> Void) {
        self.item = item
        self.store = store
        self.onDragStateChanged = onDragStateChanged
        self.onTransactionCreated = onTransactionCreated
        super.init(frame: NSRect(x: 0, y: 0, width: 392, height: 32))
        setAccessibilityLabel("Drag \(item.url.lastPathComponent) to Finder to move")
        setAccessibilityHelp("NotchPerch asks Finder to write a promised file, verifies its bytes, and only then removes the original to complete the move.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }
    override var intrinsicContentSize: NSSize { NSSize(width: 392, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.draw(in: NSRect(x: 2, y: 4, width: 24, height: 24))
        let title = item.url.lastPathComponent + (item.exists ? "" : "  (missing)")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: item.exists ? NSColor.white : NSColor.systemOrange,
            .paragraphStyle: paragraph
        ]
        (title as NSString).draw(in: NSRect(x: 34, y: 7, width: max(0, bounds.width - 40), height: 18), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start, hypot(convert(event.locationInWindow, from: nil).x - start.x, convert(event.locationInWindow, from: nil).y - start.y) > 4 else { return }
        guard VerifiedFileMove.supportsVerifiedMove(item.url) else {
            store.setTransferNotice("Verified Move currently supports regular files only. This item was not dragged.", for: item)
            self.start = nil
            return
        }
        guard let transaction = try? VerifiedFileMove(item: item, store: store) else {
            store.setTransferNotice("Move could not start. The original and shelf reference were kept.", for: item)
            self.start = nil
            return
        }
        activeMove = transaction
        onTransactionCreated(transaction)
        let draggingItem = NSDraggingItem(pasteboardWriter: transaction.provider)
        draggingItem.setDraggingFrame(NSRect(x: 2, y: 4, width: 24, height: 24), contents: NSWorkspace.shared.icon(forFile: item.url.path))
        onDragStateChanged(true)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        self.start = nil
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        activeMove?.recordDragEnd(operation)
        activeMove = nil
        onDragStateChanged(false)
    }
}

extension DragFileView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : .copy
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

@main
final class NotchPerchApplication {
    // Keep the delegate alive for the full duration of NSApplication.run().
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ShelfStore()
    private var shelf: ShelfWindowController!
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!
    private var pointerMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        shelf = ShelfWindowController(store: store)
        let arguments = ProcessInfo.processInfo.arguments
        let restoreURLs = arguments.enumerated().compactMap { index, argument -> URL? in
            guard argument == "--restore-url", arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        }
        if !restoreURLs.isEmpty { store.add(restoreURLs) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "NotchPerch"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mostra mensola", action: #selector(showShelf), keyEquivalent: ""))
        loginItem = NSMenuItem(title: "Avvia al login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchPerch", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        syncLoginState()
        installPointerMonitors()
        if arguments.contains("--show-on-launch") { shelf.showShelf(at: NSEvent.mouseLocation) }
    }

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.shelf?.updatePointer(NSEvent.mouseLocation, duringDrag: event.type == .leftMouseDragged || event.type == .rightMouseDragged)
        }) { pointerMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.shelf?.updatePointer(NSEvent.mouseLocation, duringDrag: event.type == .leftMouseDragged || event.type == .rightMouseDragged)
            return event
        }) { pointerMonitors.append(monitor) }
    }

    @objc private func showShelf() { shelf.showShelf() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("NotchPerch login item: %@", error.localizedDescription) }
        syncLoginState()
    }
    private func syncLoginState() { loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off }
}
