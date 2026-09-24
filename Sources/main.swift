import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Constants

let ASPECT: CGFloat = 16.0 / 9.0     // height / width
let BORDER: CGFloat = 3              // frame thickness, drawn OUTSIDE the recorded region
let HANDLE: CGFloat = 18
let STEP_PX = 18                     // width step in pixels: keeps 9:16 exact and both sides even
let MIN_PX = 180
let PRESETS: [(String, Int)] = [("1080 × 1920", 1080), ("720 × 1280", 720), ("540 × 960", 540), ("360 × 640", 360)]

// Marzelle Design Studios palette (Design/MarzelleStudiosDesignSystem.md)
extension NSColor {
    static let mzHotPink   = NSColor(srgbRed: 1.00, green: 0.00, blue: 0.49, alpha: 1)   // #FF007D — interactive / selected frame
    static let mzPressPink = NSColor(srgbRed: 0.84, green: 0.00, blue: 0.42, alpha: 1)   // #D6006A — press / recording
}

// Global shortcut: ⌘⇧1 toggles recording from any app.
let HOTKEY_KEYCODE = UInt32(kVK_ANSI_1)
let HOTKEY_MODIFIERS = UInt32(cmdKey | shiftKey)
let HOTKEY_LABEL = "⌘⇧1"

/// Appends to ~/Library/Logs/Record916.log (and NSLog) so failures can be diagnosed.
func logLine(_ msg: String) {
    NSLog("Record916: %@", msg)
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Record916.log")
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

func primaryScreenHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

// MARK: - HUD toolbar panel (borderless, can take keyboard focus for the size fields)

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Solid brand-pink pill button. Drawn by hand because AppKit only tints a standard
/// button's bezel while its window is key, and the toolbar is a non-activating panel.
final class PinkButton: NSButton {
    var fill: NSColor = .mzHotPink { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: max(96, super.intrinsicContentSize.width + 28), height: 30) }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = (cell as? NSButtonCell)?.isHighlighted ?? false
        let color = isEnabled ? (pressed ? fill.blended(withFraction: 0.25, of: .black) ?? fill : fill) : fill.withAlphaComponent(0.4)
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let t = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        let sz = t.size()
        t.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
    }
}

/// Bool option stored in UserDefaults with a default.
func optionValue(_ key: String, default d: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) == nil ? d : UserDefaults.standard.bool(forKey: key)
}

// MARK: - Overlay window + frame view

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FrameView: NSView {
    weak var controller: RecorderController?
    var recording = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var label = ""
    private var dragging = false, resizing = false
    private var startMouse = NSPoint.zero, startRegion = NSRect.zero

    var regionInView: NSRect { bounds.insetBy(dx: BORDER, dy: BORDER) }
    var handleRect: NSRect {
        let r = regionInView
        return NSRect(x: r.maxX - HANDLE, y: r.minY, width: HANDLE, height: HANDLE)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Coloured ring around the region (never inside it)
        let ring = NSBezierPath(rect: bounds)
        ring.appendRect(regionInView)
        ring.windingRule = .evenOdd
        (recording ? NSColor.mzPressPink : NSColor.mzHotPink).setFill()
        ring.fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let outer = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); outer.lineWidth = 1; outer.stroke()
        let inner = NSBezierPath(rect: regionInView.insetBy(dx: -0.5, dy: -0.5)); inner.lineWidth = 1; inner.stroke()
        if recording { return }

        // Faint tint inside the box while idle. Besides showing the area, it makes the
        // whole box clickable: macOS passes clicks straight through fully transparent pixels.
        NSColor.mzHotPink.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: regionInView).fill()

        // Resize handle (bottom-right)
        let h = handleRect
        NSColor.mzHotPink.setFill(); NSBezierPath(rect: h).fill()
        NSColor.black.withAlphaComponent(0.7).setStroke()
        let grip = NSBezierPath(); grip.lineWidth = 1.5
        for i in 1...3 {
            let o = CGFloat(i) * 4.5
            grip.move(to: NSPoint(x: h.maxX - o, y: h.minY + 2))
            grip.line(to: NSPoint(x: h.maxX - 2, y: h.minY + o))
        }
        grip.stroke()

        // Size label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: label, attributes: attrs)
        let size = s.size(), pad: CGFloat = 6
        let box = NSRect(x: regionInView.midX - size.width / 2 - pad,
                         y: regionInView.maxY - size.height - 2 * pad - 10,
                         width: size.width + 2 * pad, height: size.height + 2 * pad)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        s.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad))
    }

    override func resetCursorRects() {
        if recording { return }
        addCursorRect(regionInView, cursor: .openHand)
        addCursorRect(handleRect, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller, !recording else { return }
        let p = convert(event.locationInWindow, from: nil)
        resizing = handleRect.contains(p)
        dragging = !resizing
        startMouse = NSEvent.mouseLocation
        startRegion = c.region
        window?.makeKey()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller else { return }
        let m = NSEvent.mouseLocation
        if dragging {
            c.moveRegion(to: NSPoint(x: startRegion.minX + (m.x - startMouse.x),
                                     y: startRegion.minY + (m.y - startMouse.y)))
        } else if resizing {
            // Top-left corner stays put; width follows the mouse, height follows the ratio.
            c.resizeRegion(widthPt: m.x - startRegion.minX,
                           anchorTopLeft: NSPoint(x: startRegion.minX, y: startRegion.maxY))
        }
    }

    override func mouseUp(with event: NSEvent) { dragging = false; resizing = false }

    override func keyDown(with event: NSEvent) {
        guard let c = controller, !recording else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var o = c.region.origin
        switch event.keyCode {
        case 123: o.x -= step   // left
        case 124: o.x += step   // right
        case 125: o.y -= step   // down
        case 126: o.y += step   // up
        default: super.keyDown(with: event); return
        }
        c.moveRegion(to: o)
    }
}

// MARK: - Controller (region model + control panel + recording)

@MainActor
final class RecorderController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private(set) var region = NSRect.zero        // recorded region, global AppKit coords (points, bottom-left origin)

    let overlay: OverlayWindow
    let frameView = FrameView()
    let panel: HUDPanel

    // Toolbar widgets (styled after the macOS screenshot toolbar)
    let closeButton = NSButton(title: "", target: nil, action: nil)
    let presetControl = NSSegmentedControl(labels: PRESETS.map { String($0.1) }, trackingMode: .selectOne, target: nil, action: nil)
    let widthField = NSTextField(string: "")
    let heightField = NSTextField(string: "")
    let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let cursorItem = NSMenuItem(title: "Show Mouse Pointer", action: #selector(toggleOption(_:)), keyEquivalent: "")
    let clicksItem = NSMenuItem(title: "Show Mouse Clicks", action: #selector(toggleOption(_:)), keyEquivalent: "")
    let micItem = NSMenuItem(title: "Record Microphone", action: #selector(toggleOption(_:)), keyEquivalent: "")
    let monoItem = NSMenuItem(title: "Mic to Mono (Left Channel Only)", action: #selector(toggleOption(_:)), keyEquivalent: "")
    let hideFrameItem = NSMenuItem(title: "Hide Frame While Recording", action: #selector(toggleOption(_:)), keyEquivalent: "")
    let folderItem = NSMenuItem(title: "Save To…", action: #selector(chooseFolder), keyEquivalent: "")
    let revealItem = NSMenuItem(title: "Show Last Recording in Finder", action: #selector(reveal), keyEquivalent: "")
    let recordButton = PinkButton(title: "Record", target: nil, action: nil)
    let timeLabel = NSTextField(labelWithString: "")
    private var hotKeyRef: EventHotKeyRef?

    // Menu bar item; the app keeps running (and the hotkey keeps working) while the panel is hidden.
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) var uiVisible = true
    private let showHideItem = NSMenuItem(title: "Hide Frame & Panel", action: #selector(toggleUI), keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private var process: Process?
    private var timer: Timer?
    private var startDate: Date?
    private var lastFile: URL?

    // Derived
    /// The display the region lives on (by its centre point), so scale and clamping follow the region, not the window.
    var screen: NSScreen {
        let c = NSPoint(x: region.midX, y: region.midY)
        return NSScreen.screens.first { NSPointInRect(c, $0.frame) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    var scale: CGFloat { screen.backingScaleFactor }
    var pxWidth: Int { Int((region.width * scale).rounded()) }
    var pxHeight: Int { pxWidth * 16 / 9 }
    var isRecording: Bool { process != nil }

    var outputFolder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "outputFolder"), FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "outputFolder"); syncFolderItem() }
    }

    override init() {
        overlay = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                styleMask: .borderless, backing: .buffered, defer: false)
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 56),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        // Overlay
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        overlay.isReleasedWhenClosed = false
        overlay.contentView = frameView
        frameView.controller = self

        // Panel
        buildPanel()
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // Default region: 1080×1920 px, shrunk to fit the visible screen, centred
        let s = NSScreen.main ?? NSScreen.screens[0]
        let vis = s.visibleFrame
        let maxPxByH = Int(vis.height * s.backingScaleFactor) * 9 / 16
        let px = min(1080, maxPxByH)
        region = NSRect(x: vis.midX, y: vis.midY, width: 0, height: 0)
        setPixelWidth(px, keepingTopLeft: nil)
        // centre after sizing
        region.origin = NSPoint(x: (vis.midX - region.width / 2).rounded(), y: (vis.midY - region.height / 2).rounded())
        applyRegion()

        overlay.orderFront(nil)
        let pf = panel.frame
        // Bottom centre of the screen, like the system screenshot toolbar.
        panel.setFrameOrigin(NSPoint(x: (vis.midX - pf.width / 2).rounded(), y: vis.minY + 28))
        panel.orderFront(nil)
        syncFolderItem()
        registerHotKey()
        buildStatusItem()
        logLine("launch: screen capture access = \(CGPreflightScreenCaptureAccess()), bundle = \(Bundle.main.bundlePath)")
    }

    // MARK: Menu bar item, show / hide

    private func buildStatusItem() {
        for it in [showHideItem, recordItem, loginItem] { it.target = self }
        let m = NSMenu()
        m.addItem(showHideItem)
        m.addItem(recordItem)
        m.addItem(.separator())
        m.addItem(loginItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Record 9:16", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = m
        refreshLoginItem()
        updateStatusItem()
    }

    private func updateStatusItem() {
        let text = isRecording ? "● REC" : "9:16"
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.mzHotPink,
            .font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        // The shortcut label sits on whatever the key will do next.
        let tag = "   \(HOTKEY_LABEL)"
        recordItem.title = (isRecording ? "Stop Recording" : "Start Recording") + ((isRecording || uiVisible) ? tag : "")
        showHideItem.title = uiVisible ? "Hide Frame & Panel" : "Show Frame & Panel" + tag
    }

    @objc func toggleUI() { if uiVisible { hideUI() } else { showUI() } }

    func showUI() {
        uiVisible = true
        if !isRecording || hideFrameItem.state == .off { overlay.orderFront(nil) }
        panel.orderFront(nil)
        updateStatusItem()
    }

    func hideUI() {
        uiVisible = false
        overlay.orderOut(nil)
        panel.orderOut(nil)
        updateStatusItem()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            showAlert("Couldn't change Open at Login", error.localizedDescription)
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Global hotkey (Carbon; needs no Accessibility permission)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            logLine("hotkey pressed")
            Task { @MainActor in delegate.controller?.hotkeyPressed() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: 0x4D5A3136 /* MZ16 */, id: 1)
        let err = RegisterEventHotKey(HOTKEY_KEYCODE, HOTKEY_MODIFIERS, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        logLine("RegisterEventHotKey status \(err)")
        if err != noErr {
            showAlert("Couldn't claim \(HOTKEY_LABEL)", "Another app already uses that shortcut (error \(err)). Use the Record button instead.")
        }
    }

    // MARK: Region maths (always 9:16)

    func clampedPxWidth(_ px: Int) -> Int {
        let f = screen.frame
        let maxPx = min(Int(f.height * scale) * 9 / 16, Int(f.width * scale))
        var v = px
        v = (v + STEP_PX / 2) / STEP_PX * STEP_PX          // nearest step
        if v > maxPx { v = maxPx - maxPx % STEP_PX }        // floor into the screen
        return max(MIN_PX, v)
    }

    func setPixelWidth(_ px: Int, keepingTopLeft: NSPoint?) {
        let w = clampedPxWidth(px)
        let wPt = CGFloat(w) / scale
        let hPt = CGFloat(w * 16 / 9) / scale
        let tl = keepingTopLeft ?? NSPoint(x: region.midX - wPt / 2, y: region.midY + hPt / 2)
        region = NSRect(x: tl.x, y: tl.y - hPt, width: wPt, height: hPt)
        clampPosition()
        applyRegion()
    }

    func moveRegion(to origin: NSPoint) {
        region.origin = origin
        let f = screen.frame
        if region.width > f.width || region.height > f.height {
            // Crossed onto a smaller display: shrink to fit it, keeping the top-left corner.
            setPixelWidth(pxWidth, keepingTopLeft: NSPoint(x: region.minX, y: region.maxY))
            return
        }
        clampPosition()
        applyRegion()
    }

    func resizeRegion(widthPt: CGFloat, anchorTopLeft: NSPoint) {
        setPixelWidth(Int((widthPt * scale).rounded()), keepingTopLeft: anchorTopLeft)
    }

    private func clampPosition() {
        let f = screen.frame
        region.origin.x = min(max(region.minX, f.minX), f.maxX - region.width).rounded()
        region.origin.y = min(max(region.minY, f.minY), f.maxY - region.height).rounded()
    }

    func applyRegion() {
        overlay.setFrame(region.insetBy(dx: -BORDER, dy: -BORDER), display: true)
        frameView.label = "\(pxWidth) × \(pxHeight) px · 9:16"
        frameView.needsDisplay = true
        syncPanel()
    }

    private func syncPanel() {
        widthField.integerValue = pxWidth
        heightField.integerValue = pxHeight
        presetControl.selectedSegment = PRESETS.firstIndex(where: { $0.1 == pxWidth }) ?? -1
    }

    // MARK: Toolbar UI

    private func buildPanel() {
        // Close (hide) button
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self; closeButton.action = #selector(toggleUI)
        closeButton.toolTip = "Hide frame and toolbar (the menu-bar item or \(HOTKEY_LABEL) brings them back)"

        // Size presets
        presetControl.target = self; presetControl.action = #selector(presetChanged)
        presetControl.segmentStyle = .rounded
        for (i, p) in PRESETS.enumerated() { presetControl.setToolTip("\(p.0) px", forSegment: i) }

        for f in [widthField, heightField] {
            f.delegate = self
            f.alignment = .center
            f.controlSize = .regular
            f.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            f.bezelStyle = .roundedBezel
            f.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let nf = NumberFormatter(); nf.minimum = 0; nf.maximum = 100_000; nf.allowsFloats = false
            f.formatter = nf
        }

        // Options pull-down
        optionsButton.addItem(withTitle: "Options")
        let om = optionsButton.menu!
        cursorItem.state = optionValue("showCursor", default: true) ? .on : .off
        clicksItem.state = optionValue("showClicks", default: false) ? .on : .off
        micItem.state = optionValue("recordMic", default: false) ? .on : .off
        hideFrameItem.state = optionValue("hideFrame", default: true) ? .on : .off
        monoItem.state = optionValue("monoMic", default: true) ? .on : .off
        monoItem.representedObject = "monoMic"
        cursorItem.representedObject = "showCursor"; clicksItem.representedObject = "showClicks"
        micItem.representedObject = "recordMic"; hideFrameItem.representedObject = "hideFrame"
        for it in [cursorItem, clicksItem, micItem, monoItem, hideFrameItem, folderItem, revealItem] { it.target = self }
        revealItem.isEnabled = false
        om.autoenablesItems = false
        om.addItem(cursorItem); om.addItem(clicksItem); om.addItem(micItem); om.addItem(monoItem)
        om.addItem(.separator())
        om.addItem(hideFrameItem)
        om.addItem(.separator())
        om.addItem(folderItem); om.addItem(revealItem)
        optionsButton.bezelStyle = .rounded
        optionsButton.controlSize = .large

        // Record button: brand pink, white text
        recordButton.target = self; recordButton.action = #selector(toggleRecording)
        recordButton.isBordered = false
        recordButton.wantsLayer = true
        setRecordTitle("Record")

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .left
        timeLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true

        func label(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t); l.textColor = .secondaryLabelColor; return l
        }
        func vsep() -> NSBox {
            let b = NSBox(); b.boxType = .separator
            b.widthAnchor.constraint(equalToConstant: 1).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }

        let times = label("×"), px = label("px")
        let stack = NSStackView(views: [
            closeButton, vsep(),
            presetControl, widthField, times, heightField, px, vsep(),
            optionsButton, recordButton, timeLabel,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(6, after: widthField)
        stack.setCustomSpacing(6, after: times)
        stack.setCustomSpacing(4, after: heightField)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Frosted dark background with rounded corners and a hairline edge
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        effect.layoutSubtreeIfNeeded()
        panel.setContentSize(stack.fittingSize)
    }

    private func setRecordTitle(_ t: String) {
        recordButton.title = t
        recordButton.invalidateIntrinsicContentSize()
        recordButton.needsDisplay = true
    }

    private func syncFolderItem() {
        folderItem.title = "Save To: \(outputFolder.lastPathComponent)…"
    }

    private func setControlsEnabled(_ on: Bool) {
        for c in [presetControl, widthField, heightField, optionsButton] as [NSControl] { c.isEnabled = on }
    }

    private func showAlert(_ title: String, _ text: String, settings: Bool = false) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        if settings { a.addButton(withTitle: "Open Screen Recording Settings") }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { openSettings() }
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        if let key = sender.representedObject as? String { UserDefaults.standard.set(sender.state == .on, forKey: key) }
    }

    @objc private func presetChanged() {
        let i = presetControl.selectedSegment
        if i >= 0 && i < PRESETS.count { setPixelWidth(PRESETS[i].1, keepingTopLeft: nil) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === widthField { setPixelWidth(widthField.integerValue, keepingTopLeft: nil) }
        else if f === heightField { setPixelWidth(Int((Double(heightField.integerValue) * 9.0 / 16.0).rounded()), keepingTopLeft: nil) }
        panel.makeFirstResponder(nil)
    }

    @objc private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = outputFolder
        p.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { outputFolder = u }
    }

    @objc private func reveal() {
        if let u = lastFile { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    @objc private func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Recording

    /// Hotkey: stop if recording; otherwise show the frame first so it can be positioned,
    /// and only start recording when the frame is already visible.
    @objc func hotkeyPressed() {
        if isRecording { stopRecording() }
        else if !uiVisible { showUI() }
        else { startRecording() }
    }

    @objc func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func fileName() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording 9x16 \(df.string(from: Date())).mov"
    }

    /// The region in the top-left-origin point coordinates that `screencapture -R` expects.
    func captureRect() -> (x: Int, y: Int, w: Int, h: Int) {
        (Int(region.minX.rounded()),
         Int((primaryScreenHeight() - region.maxY).rounded()),
         Int(region.width.rounded()),
         Int(region.height.rounded()))
    }

    /// Returns true if Screen Recording is granted to this app. If not, asks macOS once (the system
    /// prompt appears only the first time; afterwards the user must enable it in System Settings).
    func ensureScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        logLine("screen capture access not granted; requesting")
        let granted = CGRequestScreenCaptureAccess()
        logLine("CGRequestScreenCaptureAccess returned \(granted)")
        if !granted {
            showUI()
            showAlert("Screen Recording permission needed",
                      "Turn on Record 9:16 under System Settings → Privacy & Security → Screen & System Audio Recording (if it's already on, switch it off and on again), then record again.",
                      settings: true)
        }
        return granted
    }

    func startRecording() {
        guard ensureScreenAccess() else { return }
        let r = captureRect()
        let url = outputFolder.appendingPathComponent(fileName())
        var args = ["-v", "-x", "-R", "\(r.x),\(r.y),\(r.w),\(r.h)"]
        if cursorItem.state == .on { args.append("-C") }
        if clicksItem.state == .on { args.append("-k") }
        if micItem.state == .on { args.append("-g") }
        args.append(url.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        p.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let log = String(data: data, encoding: .utf8) ?? ""
            let status = proc.terminationStatus
            Task { @MainActor in self.recordingEnded(url: url, status: status, log: log) }
        }
        logLine("starting screencapture " + args.joined(separator: " "))
        do { try p.run() } catch {
            showAlert("Couldn't start recording", error.localizedDescription)
            return
        }

        process = p
        lastFile = url
        startDate = Date()
        frameView.recording = true
        overlay.ignoresMouseEvents = true
        if hideFrameItem.state == .on { overlay.orderOut(nil) }
        setControlsEnabled(false)
        setRecordTitle("Stop")
        recordButton.fill = .mzPressPink
        updateStatusItem()
        timeLabel.textColor = .mzHotPink
        timeLabel.stringValue = "00:00"
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    func stopRecording() {
        guard let p = process else { return }
        timeLabel.stringValue = "Saving…"
        recordButton.isEnabled = false
        p.interrupt()   // SIGINT: screencapture finalises the movie
    }

    /// Called on quit: stop and wait so the file is finalised.
    func stopAndWait() {
        guard let p = process else { return }
        p.interrupt()
        p.waitUntilExit()
    }

    @objc private func tick() {
        guard let s = startDate else { return }
        let t = Int(Date().timeIntervalSince(s))
        timeLabel.stringValue = String(format: "%02d:%02d", t / 60, t % 60)
    }

    private func recordingEnded(url: URL, status: Int32, log: String) {
        logLine("screencapture exited \(status), file exists \(FileManager.default.fileExists(atPath: url.path)), output: \(log.trimmingCharacters(in: .whitespacesAndNewlines))")
        process = nil
        timer?.invalidate(); timer = nil
        startDate = nil
        frameView.recording = false
        overlay.ignoresMouseEvents = false
        setControlsEnabled(true)
        recordButton.isEnabled = true
        setRecordTitle("Record")
        recordButton.fill = .mzHotPink
        updateStatusItem()
        showUI()   // bring the toolbar back so the result is visible
        timeLabel.textColor = .secondaryLabelColor

        if FileManager.default.fileExists(atPath: url.path) {
            timeLabel.stringValue = "Saved ✓"
            revealItem.isEnabled = true
            if micItem.state == .on && monoItem.state == .on { makeMono(url) }
        } else {
            timeLabel.stringValue = ""
            let detail = log.trimmingCharacters(in: .whitespacesAndNewlines)
            showAlert("No video was saved",
                      (detail.isEmpty ? "" : detail + "\n\n") + "Make sure Record 9:16 is allowed under System Settings → Privacy & Security → Screen & System Audio Recording, then try again.",
                      settings: true)
        }
    }

    // MARK: Mono microphone audio

    private func ffmpegPath() -> String? {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// screencapture writes the microphone into the LEFT channel of a stereo track; the right
    /// channel is whatever is on the interface's second input. Keep only the left channel as a
    /// mono track. The video stream is copied untouched.
    private func makeMono(_ url: URL) {
        guard let ff = ffmpegPath() else { logLine("ffmpeg not found; audio left as recorded"); return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".mono-" + url.lastPathComponent)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-y", "-v", "error", "-i", url.path, "-map", "0", "-c:v", "copy",
                       "-c:a", "aac", "-b:a", "192k", "-af", "pan=mono|c0=c0",
                       "-movflags", "+faststart", tmp.path]
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        timeLabel.stringValue = "Audio…"
        p.terminationHandler = { proc in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = proc.terminationStatus
            Task { @MainActor in
                if status == 0 {
                    do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp); logLine("mic audio folded to mono (left channel only)") }
                    catch { logLine("couldn't replace file after mono conversion: \(error)") }
                } else {
                    logLine("mono conversion failed (\(status)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                try? FileManager.default.removeItem(at: tmp)
                self.timeLabel.stringValue = "Saved ✓"
            }
        }
        do { try p.run() } catch { logLine("couldn't run ffmpeg: \(error)") }
    }

    // Closing the panel hides it; the app stays in the menu bar so the hotkey keeps working.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { hideUI(); return false }
        return true
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: RecorderController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = RecorderController()
        buildMenu()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            // Debug: render the toolbar's content to a PNG and quit.
            let v = controller.panel.contentView!
            v.layoutSubtreeIfNeeded()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            print("toolbar size: \(v.bounds.size)")
            NSApp.terminate(nil)
        }
        if CommandLine.arguments.contains("--print-region") {
            let c = controller!, r = c.captureRect(), f = c.screen.frame
            for (i, sc) in NSScreen.screens.enumerated() { print("screen[\(i)] frame=\(sc.frame) visible=\(sc.visibleFrame) scale=\(sc.backingScaleFactor) main=\(sc == NSScreen.main)") }
            print("screen=\(Int(f.width))x\(Int(f.height))pt scale=\(c.scale) region_pt=\(c.region) capture=-R \(r.x),\(r.y),\(r.w),\(r.h) output=\(c.pxWidth)x\(c.pxHeight)px")
            for px in [1080, 720, 1000, 5000, 10] { c.setPixelWidth(px, keepingTopLeft: nil); print("request \(px) -> \(c.pxWidth)x\(c.pxHeight)px  ratio=\(Double(c.pxHeight)/Double(c.pxWidth))  pt=\(c.region.size)") }
            NSApp.terminate(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.stopAndWait()
        return .terminateNow
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let hide = appMenu.addItem(withTitle: "Hide Frame & Panel", action: #selector(RecorderController.toggleUI), keyEquivalent: "w")
        hide.target = controller
        appMenu.addItem(withTitle: "Quit Record 9:16", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let recItem = NSMenuItem(); main.addItem(recItem)
        let rec = NSMenu(title: "Recording")
        let toggle = rec.addItem(withTitle: "Start / Stop Recording", action: #selector(RecorderController.toggleRecording), keyEquivalent: "r")
        toggle.target = controller
        recItem.submenu = rec

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
