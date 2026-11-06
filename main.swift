import AppKit
import Carbon.HIToolbox

// MARK: - Model

func log(_ s: String) {
    let url = Store.shared.logURL
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct Clip: Codable, Identifiable {
    enum Kind: String, Codable { case text, image, file, color }
    var id: UUID = UUID()
    var date: Date = Date()
    var kind: Kind
    var text: String
    var blob: String?
    var pinned: Bool?

    var isPinned: Bool { pinned ?? false }
}

// MARK: - Store

final class Store {
    static let shared = Store()

    private let fm = FileManager.default
    private let root: URL
    private let blobs: URL
    private let index: URL
    let logURL: URL
    private(set) var clips: [Clip] = []
    let maxItems = 300

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shelf", isDirectory: true)
        root = base
        blobs = base.appendingPathComponent("Blobs", isDirectory: true)
        index = base.appendingPathComponent("history.json")
        logURL = base.appendingPathComponent("shelf.log")
        try? fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: index) else { return }
        clips = (try? JSONDecoder().decode([Clip].self, from: data)) ?? []
    }

    func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: index, options: .atomic)
    }

    func add(_ clip: Clip) {
        if let first = clips.first, first.text == clip.text, first.kind == clip.kind {
            clips[0].date = Date()
            save()
            return
        }
        if let existing = clips.firstIndex(where: { $0.text == clip.text && $0.kind == clip.kind }) {
            var moved = clips.remove(at: existing)
            moved.date = Date()
            clips.insert(moved, at: 0)
        } else {
            clips.insert(clip, at: 0)
        }
        clips.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.date > b.date
        }
        while clips.count > maxItems {
            let dropped = clips.removeLast()
            if let b = dropped.blob {
                try? fm.removeItem(at: blobs.appendingPathComponent(b))
            }
        }
        save()
    }

    func blobURL(_ name: String) -> URL { blobs.appendingPathComponent(name) }

    func togglePin(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[i].pinned = !(clips[i].pinned ?? false)
        clips.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.date > b.date
        }
        save()
    }

    func remove(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let dropped = clips.remove(at: i)
        if let b = dropped.blob { try? fm.removeItem(at: blobs.appendingPathComponent(b)) }
        save()
    }

    func clear() {
        clips.removeAll()
        try? fm.removeItem(at: blobs)
        try? fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        save()
    }
}

// MARK: - Pasteboard watcher

final class Watcher {
    private var lastChange = -1
    private var timer: Timer?
    var onChange: (() -> Void)?

    func start() {
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func markCurrent() { lastChange = NSPasteboard.general.changeCount }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        capture(pb)
        onChange?()
    }

    private func capture(_ pb: NSPasteboard) {
        let types = pb.types ?? []

        if types.contains(.fileURL), let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.path }.joined(separator: "\n")
            Store.shared.add(Clip(kind: .file, text: paths))
            log("captured file")
            return
        }

        if types.contains(.color), let color = NSColor(from: pb) {
            let c = color.usingColorSpace(.sRGB) ?? color
            let hex = String(format: "#%02X%02X%02X",
                             Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            Store.shared.add(Clip(kind: .color, text: hex))
            log("captured color")
            return
        }

        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Store.shared.add(Clip(kind: .text, text: s))
            log("captured text")
            return
        }

        if let img = imageFrom(pb) {
            let name = UUID().uuidString + ".png"
            if let png = img.pngData {
                try? png.write(to: Store.shared.blobURL(name))
                Store.shared.add(Clip(kind: .image, text: "Image \(Int(img.size.width))x\(Int(img.size.height))", blob: name))
                log("captured image")
            }
            return
        }
    }

    private func imageFrom(_ pb: NSPasteboard) -> (pngData: Data?, size: NSSize)? {
        if let data = pb.data(forType: .png), let rep = NSBitmapImageRep(data: data) {
            return (data, NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        }
        if let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff) {
            let png = img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            return (png, img.size)
        }
        return nil
    }
}

// MARK: - Row view

final class ShelfRowView: NSTableRowView {
    private var hovered = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        (subviews.first as? ClipRowView)?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        (subviews.first as? ClipRowView)?.setHovered(false)
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        let r = bounds.insetBy(dx: 20, dy: 3)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 20, dy: 3)
        let color = isEmphasized
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }
}

final class ClipRowView: NSTableCellView {
    let thumb = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let copyButton = NSButton()
    let pinButton = NSButton()
    private var pinned = false
    private var selected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func setHovered(_ hovered: Bool) {
        pinButton.isHidden = !(hovered || pinned)
        copyButton.alphaValue = hovered || selected ? 1 : 0.4
    }

    func applySelection(_ isSelected: Bool) {
        selected = isSelected
        copyButton.alphaValue = isSelected ? 1 : 0.4
        let primary: NSColor = isSelected ? .white : .labelColor
        let secondary: NSColor = isSelected ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        title.textColor = primary
        subtitle.textColor = secondary
        copyButton.contentTintColor = secondary
        if !pinned {
            pinButton.contentTintColor = secondary
        }
    }

    private func build() {
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true

        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true

        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isBordered = false
        copyButton.imagePosition = .imageOnly
        copyButton.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.alphaValue = 0.4
        copyButton.toolTip = "Copy"
        copyButton.setAccessibilityLabel("Copy clip")

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
        pinButton.toolTip = "Pin"
        pinButton.setAccessibilityLabel("Pin clip")
        pinButton.isHidden = true

        addSubview(thumb)
        addSubview(title)
        addSubview(subtitle)
        addSubview(pinButton)
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 40),
            thumb.heightAnchor.constraint(equalToConstant: 40),

            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            title.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -10),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),

            pinButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 20),
            pinButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    func configure(clip: Clip, thumbnail: (image: NSImage?, tint: NSColor)) {
        thumb.image = thumbnail.image
        thumb.contentTintColor = thumbnail.tint
        title.stringValue = Self.titleText(for: clip)
        subtitle.stringValue = Self.subtitleText(for: clip)
        pinned = clip.isPinned
        pinButton.isHidden = !pinned
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                  accessibilityDescription: "Pin")
        pinButton.contentTintColor = pinned ? .labelColor : .secondaryLabelColor
    }

    private static func titleText(for clip: Clip) -> String {
        switch clip.kind {
        case .text:
            let flat = clip.text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.isEmpty ? "Text" : flat
        case .image:
            return "Image"
        case .file:
            let paths = clip.text.split(separator: "\n").map(String.init)
            if paths.count == 1 { return (paths[0] as NSString).lastPathComponent }
            return "\(paths.count) files"
        case .color:
            return clip.text
        }
    }

    private static func subtitleText(for clip: Clip) -> String {
        let kind: String
        switch clip.kind {
        case .text: kind = "\(clip.text.count) characters"
        case .image:
            let dims = clip.text.replacingOccurrences(of: "Image ", with: "")
                .replacingOccurrences(of: "x", with: " \u{00D7} ")
            kind = dims
        case .file:
            kind = (clip.text.split(separator: "\n").first.map(String.init) ?? "")
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .color: kind = "Color"
        }
        return kind + "   " + relative(clip.date)
    }

    private static func relative(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 604_800 { return "\(Int(s / 86_400))d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#"), s.count == 7 else { return nil }
        s.removeFirst()
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Image viewer

final class ViewerPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == " " {
            onDismiss?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

final class ViewerContentView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class ImageViewer {
    static let shared = ImageViewer()
    private var panel: ViewerPanel?

    func isShowing() -> Bool { panel?.isVisible ?? false }

    func show(_ image: NSImage, caption: String) {
        close()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let maxW = visible.width * 0.82
        let maxH = visible.height * 0.82
        let imgSize = image.size
        let scale = min(1, min(maxW / max(imgSize.width, 1), maxH / max(imgSize.height, 1)))
        let w = max(320, imgSize.width * scale)
        let h = max(240, imgSize.height * scale)
        let captionH: CGFloat = 46

        let panel = ViewerPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h + captionH),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = ViewerContentView(frame: NSRect(x: 0, y: 0, width: w, height: h + captionH))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        content.onClick = { [weak self] in self?.close() }

        let iv = NSImageView(frame: NSRect(x: 0, y: captionH, width: w, height: h))
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: caption)
        label.frame = NSRect(x: 18, y: 15, width: w - 36, height: 16)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor.white.withAlphaComponent(0.55)
        label.alignment = .center

        let rule = NSBox(frame: NSRect(x: 0, y: captionH - 1, width: w, height: 1))
        rule.boxType = .separator
        rule.autoresizingMask = [.width, .maxYMargin]

        content.addSubview(iv)
        content.addSubview(rule)
        content.addSubview(label)
        panel.contentView = content
        panel.onDismiss = { [weak self] in self?.close() }

        let origin = NSPoint(x: visible.midX - w / 2, y: visible.midY - (h + captionH) / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h + captionH)), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class PreviewClickCatcher: NSView, NSDraggingSource {
    var onSingle: (() -> Void)?
    var onDouble: (() -> Void)?
    var onAlternate: (() -> Void)?
    var makeDraggingItem: ((NSEvent) -> NSDraggingItem?)?

    private var downPoint: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !dragged else { return }
        let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard distance > 3 else { return }
        dragged = true
        guard let item = makeDraggingItem?(event) else { return }
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downPoint = nil
            dragged = false
        }
        guard !dragged else { return }
        if event.clickCount >= 2 {
            onDouble?()
        } else if event.modifierFlags.contains(.option) {
            onAlternate?()
        } else {
            onSingle?()
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : .copy
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Search bar

final class SearchBar: NSView {
    let field = NSTextField()
    private let icon = NSImageView()
    private let clearButton = NSButton()
    var onChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        // No fill: the field matches the panel exactly and is drawn by a hairline stroke only.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search"
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false

        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearText)
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(field)
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),

            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 13),
            clearButton.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var query: String { field.stringValue }

    func reset() {
        field.stringValue = ""
        updateClear()
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    @objc private func clearText() {
        field.stringValue = ""
        updateClear()
        onChange?()
    }

    fileprivate func updateClear() {
        clearButton.isHidden = field.stringValue.isEmpty
    }
}
// MARK: - Preview pane

final class PreviewPane: NSView {
    private let kindLabel = NSTextField(labelWithString: "")
    private let image = NSImageView()
    private let textScroll = NSScrollView()
    private let text = NSTextView()
    private let meta = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Select a clip to preview")
    private let hitCatcher = PreviewClickCatcher()
    private var current: Clip?
    var onActivate: (() -> Void)?
    var onCopyOnly: (() -> Void)?
    var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        kindLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.stringValue = ""

        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.masksToBounds = true
        image.layer?.borderWidth = 0

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 0, height: 0)
        textScroll.documentView = text
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textScroll.scrollerStyle = .overlay

        meta.font = .systemFont(ofSize: 11)
        meta.toolTip = "Click to open, double-click to paste, opt-click to copy"
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingMiddle
        meta.alignment = .right

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        hitCatcher.isHidden = true
        hitCatcher.onSingle = { [weak self] in self?.singleClick() }
        hitCatcher.onDouble = { [weak self] in self?.onActivate?() }
        hitCatcher.onAlternate = { [weak self] in self?.onCopyOnly?() }
        hitCatcher.makeDraggingItem = { [weak self] event in self?.draggingItem(for: event) }

        addSubview(kindLabel)
        addSubview(image)
        addSubview(textScroll)
        addSubview(meta)
        addSubview(hint)
        addSubview(hitCatcher)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 20
        let w = bounds.width - pad * 2
        kindLabel.frame = NSRect(x: pad, y: bounds.height - 26, width: 90, height: 14)
        meta.frame = NSRect(x: pad, y: bounds.height - 26, width: w, height: 14)
        let top = bounds.height - 42
        let bottom: CGFloat = 18
        let h = max(0, top - bottom)

        // The preview card hugs the image: aspect-fit inside the pane, then take that rect.
        if let img = image.image, img.size.width > 0, img.size.height > 0 {
            let scale = min(w / img.size.width, h / img.size.height)
            let dw = max(1, img.size.width * scale)
            let dh = max(1, img.size.height * scale)
            image.frame = NSRect(x: pad + (w - dw) / 2, y: top - dh, width: dw, height: dh)
        } else {
            image.frame = NSRect(x: pad, y: bottom, width: w, height: h)
        }
        hitCatcher.frame = image.frame
        textScroll.frame = NSRect(x: pad, y: bottom, width: w, height: h)
        hint.frame = NSRect(x: pad, y: bounds.midY - 10, width: w, height: 20)
    }

    private func draggingItem(for event: NSEvent) -> NSDraggingItem? {
        guard let clip = current else { return nil }
        let pb = NSPasteboardItem()
        var preview: NSImage?

        switch clip.kind {
        case .image:
            guard let name = clip.blob,
                  let data = try? Data(contentsOf: Store.shared.blobURL(name)),
                  let img = NSImage(data: data) else { return nil }
            preview = img
            pb.setData(data, forType: .png)
            pb.setData(data, forType: .tiff)
            let label = clip.text.replacingOccurrences(of: "Image ", with: "")
                .replacingOccurrences(of: "x", with: "x")
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Shelf Image \(label).png")
            try? data.write(to: tmp)
            pb.setString(tmp.absoluteString, forType: .fileURL)
        case .file:
            guard let first = clip.text.split(separator: "\n").first.map(String.init) else { return nil }
            pb.setString(URL(fileURLWithPath: first).absoluteString, forType: .fileURL)
            preview = NSWorkspace.shared.icon(forFile: first)
        case .color, .text:
            pb.setString(clip.text, forType: .string)
            preview = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        }

        guard let image = preview else { return nil }
        let maxSide: CGFloat = 132
        let ratio = image.size.height / max(image.size.width, 1)
        let w = min(maxSide, image.size.width == 0 ? maxSide : image.size.width)
        let h = w * ratio
        let item = NSDraggingItem(pasteboardWriter: pb)
        let origin = NSPoint(x: hitCatcher.bounds.midX - w / 2, y: hitCatcher.bounds.midY - h / 2)
        item.setDraggingFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), contents: image)
        log("drag started kind=\(clip.kind.rawValue)")
        return item
    }

    private func singleClick() {
        guard let clip = current else { return }
        if clip.kind == .image || clip.kind == .file || clip.kind == .color {
            onOpen?()
        } else {
            onActivate?()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !hitCatcher.isHidden {
            addCursorRect(hitCatcher.frame, cursor: .pointingHand)
        }
    }

    func show(_ clip: Clip?) {
        current = clip
        needsLayout = true
        layoutSubtreeIfNeeded()
        hitCatcher.isHidden = true
        guard let clip else {
            image.isHidden = true
            textScroll.isHidden = true
            kindLabel.stringValue = ""
            meta.stringValue = ""
            hint.isHidden = false
            return
        }
        hint.isHidden = true
        meta.stringValue = Self.metaText(for: clip)

        switch clip.kind {
        case .image:
            kindLabel.stringValue = "IMAGE"
            image.isHidden = false
            textScroll.isHidden = true
            hitCatcher.isHidden = false
            window?.invalidateCursorRects(for: self)
            if let name = clip.blob, let img = NSImage(contentsOf: Store.shared.blobURL(name)) {
                image.image = img
            } else {
                image.image = nil
            }
        case .color:
            kindLabel.stringValue = "COLOR"
            image.isHidden = false
            textScroll.isHidden = true
            hitCatcher.isHidden = false
            window?.invalidateCursorRects(for: self)
            image.image = Self.swatch(clip.text)
        case .file:
            kindLabel.stringValue = "FILE"
            image.isHidden = false
            textScroll.isHidden = true
            hitCatcher.isHidden = false
            window?.invalidateCursorRects(for: self)
            image.image = NSWorkspace.shared.icon(forFile: clip.text.split(separator: "\n").first.map(String.init) ?? clip.text)
        case .text:
            kindLabel.stringValue = "TEXT"
            image.isHidden = true
            textScroll.isHidden = false
            text.string = clip.text
            text.scrollToBeginningOfDocument(nil)
        }
    }

    private static func metaText(for clip: Clip) -> String {
        switch clip.kind {
        case .text: return "\(clip.text.count) characters"
        case .image:
            return clip.text.replacingOccurrences(of: "Image ", with: "")
                .replacingOccurrences(of: "x", with: " \u{00D7} ")
        case .file:
            return (clip.text.split(separator: "\n").first.map(String.init) ?? "")
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .color: return clip.text
        }
    }

    private static func swatch(_ hex: String) -> NSImage {
        let size = NSSize(width: 240, height: 160)
        let img = NSImage(size: size)
        img.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
        (NSColor(hex: hex) ?? .gray).setFill()
        path.fill()
        img.unlockFocus()
        return img
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    private static let label = "com.shelf.clipboard.loginitem"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    private static var libraryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    private static var agentURL: URL {
        libraryURL.appendingPathComponent("LaunchAgents/\(label).plist")
    }

    static func set(_ enabled: Bool) {
        if enabled {
            try? FileManager.default.createDirectory(at: libraryURL.appendingPathComponent("LaunchAgents"),
                                                     withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.bundlePath + "/Contents/MacOS/Shelf"],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: agentURL)
            }
        } else {
            try? FileManager.default.removeItem(at: agentURL)
        }
    }
}

// MARK: - Panel

final class ShelfPanel: NSPanel {
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onDelete: (() -> Void)?
    var onPasteAll: (() -> Void)?
    var onOpen: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            // If the search field has selected text, that selection is what ⌘C means.
            if let editor = firstResponder as? NSTextView, editor.selectedRange().length > 0 { break }
            onCopy?()
            return true
        case "p": onPin?(); return true
        case "o": onOpen?(); return true
        case "\r": onPasteAll?(); return true
        default: break
        }
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class ShelfController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {

    private var panel: ShelfPanel!
    private let search = SearchBar()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hints = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
    private let count = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let previewPane = PreviewPane()
    private let emptyIcon = NSImageView()
    private var filtered: [Clip] = []
    private var targetApp: NSRunningApplication?
    private var watcher: Watcher!
    private var hotKeyRef: EventHotKeyRef?
    private var resignArmed = false
    private var outsideClickMonitor: Any?

    private static let hotKeyID = EventHotKeyID(signature: OSType(0x5348464C), id: 1) // 'SHFL'

    func start() {
        Store.shared.save()
        buildMainMenu()
        buildPanel()
        buildStatusItem()
        watcher = Watcher()
        watcher.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.reload()
        }
        watcher.start()
        registerHotKey()
        log("started pid=\(ProcessInfo.processInfo.processIdentifier) trusted=\(AXIsProcessTrusted())")
        // Outside clicks are handled by the app-resign-active observer below: clicking any other
        // app deactivates us and the shelf closes. A global mouse monitor fired on synthetic and
        // non-mouse events with bogus coordinates, closing the shelf mid-interaction.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            log("app resigned active -> hide")
            self.hide()
        }
        promptForAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Onboarding.shared.showIfNeeded() }
    }

    // MARK: Menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Shelf", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "Hide Shelf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Shelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close Shelf", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window

        NSApp.mainMenu = main
    }

    // MARK: UI

    private func buildPanel() {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 620)
        panel = ShelfPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onCopy = { [weak self] in self?.copySelection() }
        panel.onPin = { [weak self] in self?.pinSelection() }
        panel.onDelete = { [weak self] in self?.deleteSelection() }
        panel.onPasteAll = { [weak self] in self?.pasteSelection() }
        panel.onOpen = { [weak self] in
            guard let self, let row = self.table.selectedRowIndexes.first, row < self.filtered.count else { return }
            self.openPreview(self.filtered[row])
        }
        previewPane.onActivate = { [weak self] in
            guard let self, let row = self.table.selectedRowIndexes.first, row < self.filtered.count else { return }
            self.paste(self.filtered[row])
        }
        previewPane.onCopyOnly = { [weak self] in self?.copySelection() }
        previewPane.onOpen = { [weak self] in
            guard let self, let row = self.table.selectedRowIndexes.first, row < self.filtered.count else { return }
            self.openPreview(self.filtered[row])
        }

        let effect = NSVisualEffectView(frame: rect)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        effect.autoresizingMask = [.width, .height]

        let container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]

        search.frame = NSRect(x: 20, y: rect.height - 58, width: rect.width - 40, height: 32)
        search.autoresizingMask = [.width, .minYMargin]
        search.field.delegate = self
        search.onChange = { [weak self] in
            self?.search.updateClear()
            self?.reload()
        }

        let divider = NSBox(frame: NSRect(x: 0, y: rect.height - 66, width: rect.width, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = [.width, .minYMargin]

        let listWidth: CGFloat = 462
        let tableRect = NSRect(x: 0, y: 46, width: listWidth, height: rect.height - 112)
        table.headerView = nil
        table.rowHeight = 74
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = listWidth
        column.resizingMask = .autoresizingMask
        column.minWidth = 240
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)

        scroll.frame = tableRect
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        hints.frame = NSRect(x: 20, y: 14, width: rect.width - 200, height: 16)
        hints.autoresizingMask = [.width, .maxYMargin]
        hints.attributedStringValue = Self.hintsAttributed()

        count.frame = NSRect(x: rect.width - 190, y: 14, width: 170, height: 16)
        count.autoresizingMask = [.minXMargin, .maxYMargin]
        count.alignment = .right
        count.font = .systemFont(ofSize: 11.5)
        count.textColor = NSColor.labelColor.withAlphaComponent(0.55)
        count.stringValue = ""

        emptyIcon.frame = NSRect(x: listWidth / 2 - 16, y: rect.height / 2 + 6, width: 32, height: 32)
        emptyIcon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        emptyIcon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.imageScaling = .scaleProportionallyDown

        emptyLabel.frame = NSRect(x: 0, y: rect.height / 2 - 24, width: listWidth, height: 20)
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.stringValue = "Copy something, then press \u{2325}V"
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.isHidden = true

        let backing = NSView(frame: rect)
        backing.autoresizingMask = [.width, .height]
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        effect.addSubview(backing)

        let vDivider = NSBox(frame: NSRect(x: listWidth, y: 46, width: 1, height: rect.height - 112))
        vDivider.boxType = .separator
        vDivider.autoresizingMask = [.height, .maxXMargin]

        previewPane.frame = NSRect(x: listWidth + 1, y: 46, width: rect.width - listWidth - 1, height: rect.height - 112)
        previewPane.autoresizingMask = [.width, .height]

        container.addSubview(search)
        container.addSubview(divider)
        container.addSubview(vDivider)
        container.addSubview(previewPane)
        container.addSubview(scroll)
        container.addSubview(hints)
        container.addSubview(count)
        container.addSubview(emptyIcon)
        container.addSubview(emptyLabel)
        effect.addSubview(container)
        panel.contentView = effect
    }

    static func hintsAttributed() -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.72)
        ]
        // No permanent nag when Accessibility is missing: the paste attempt itself shows a HUD
        // explaining it. The footer always documents the keys.

        let key: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.78)
        ]
        let out = NSMutableAttributedString()
        func add(_ k: String, _ d: String) {
            out.append(NSAttributedString(string: k + " ", attributes: key))
            out.append(NSAttributedString(string: d + "     ", attributes: base))
        }
        add("\u{21A9}", "paste")
        add("\u{2318}C", "copy")
        add("\u{2318}P", "pin")
        add("\u{2318}\u{232B}", "delete")
        add("\u{2318}O", "open")
        add("\u{238B}", "close")
        return out
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Shelf")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Shelf", action: #selector(toggleFromMenu), keyEquivalent: "v").keyEquivalentModifierMask = [.option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginItem = login
        menu.addItem(login)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Shelf", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?

    // MARK: Hotkey

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            log("hotkey fired")
            DispatchQueue.main.async { shelf.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let st = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(optionKey),
                            ShelfController.hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        log("hotkey register status=\(st) ref=\(hotKeyRef != nil)")
    }

    @objc private func toggleFromMenu() { toggle() }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
        log("launch at login = \(LaunchAtLogin.isEnabled)")
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Shelf",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: "A local clipboard shelf. Nothing leaves this Mac.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        log("show requested")
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            targetApp = targetApp ?? NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular }
            present()
            return
        }
        targetApp = app
        log("target=\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
        present()
    }

    private func present() {
        search.reset()
        reload()
        let desired = min(620, max(452, CGFloat(min(filtered.count, 7)) * 74 + 118))
        var frame = panel.frame
        frame.size.height = desired
        panel.setFrame(frame, display: false)
        positionPanel()
        let finalFrame = panel.frame
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: finalFrame.origin.x, y: finalFrame.origin.y - 8))
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search.field)
        if !filtered.isEmpty { selectRow(0) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalFrame.origin)
        }
        log("present frame=\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)),\(Int(panel.frame.width)),\(Int(panel.frame.height)) key=\(panel.isKeyWindow)")
        resignArmed = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            self.panel.makeFirstResponder(self.search.field)
            log("reassert key=\(self.panel.isKeyWindow) active=\(NSApp.isActive)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.resignArmed = true
            if !self.panel.isKeyWindow { self.panel.makeKey() }
            log("armed key=\(self.panel.isKeyWindow) visible=\(self.panel.isVisible)")
        }
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40)
        panel.isMovableByWindowBackground = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func hide() {
        log("hide")
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    func windowDidResignKey(_ notification: Notification) {
        log("resignKey (ignored) appActive=\(NSApp.isActive)")
        reassertKeySoon()
    }

    private func reassertKeySoon() {
        guard panel.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.makeKey()
            if self.panel.firstResponder !== self.search {
                self.panel.makeFirstResponder(self.search.field)
            }
        }
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            // CGEvent.location is in Quartz (top-left origin) global coordinates; convert to
            // AppKit (bottom-left origin, main screen) so it can be compared with the panel frame.
            let quartz = event.cgEvent?.location ?? NSPoint(x: NSEvent.mouseLocation.x,
                                                           y: NSEvent.mouseLocation.y)
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            let point = NSPoint(x: quartz.x, y: mainH - quartz.y)
            if !self.panel.frame.contains(point) {
                log("outside click at \(Int(point.x)),\(Int(point.y)) -> hide")
                self.hide()
            }
        }
    }

    // MARK: Data

    private func reload() {
        let q = search.query.trimmingCharacters(in: .whitespaces)
        let all = Store.shared.clips
        filtered = q.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        emptyLabel.isHidden = !filtered.isEmpty
        emptyIcon.isHidden = !filtered.isEmpty
        count.stringValue = filtered.isEmpty ? "" : "\(filtered.count) item\(filtered.count == 1 ? "" : "s")"
        if !filtered.isEmpty {
            let keep = min(table.selectedRow, filtered.count - 1)
            selectRow(max(0, keep))
            previewPane.show(filtered[max(0, keep)])
        } else {
            previewPane.show(nil)
        }
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < filtered.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clipRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ClipRowView ?? {
            let v = ClipRowView()
            v.identifier = id
            v.copyButton.target = self
            v.copyButton.action = #selector(copyRowButton(_:))
            v.pinButton.target = self
            v.pinButton.action = #selector(pinRowButton(_:))
            return v
        }()
        guard row < filtered.count else { return cell }
        let clip = filtered[row]
        cell.copyButton.tag = row
        cell.pinButton.tag = row
        cell.configure(clip: clip, thumbnail: thumbnail(for: clip))
        cell.applySelection(table.selectedRowIndexes.contains(row))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ShelfRowView()
    }

    private func selectedClips() -> [Clip] {
        table.selectedRowIndexes.sorted().compactMap { $0 < filtered.count ? filtered[$0] : nil }
    }

    private func pinSelection() {
        guard let clip = selectedClips().first else { return }
        Store.shared.togglePin(clip)
        reload()
        log("pin toggled \(!clip.isPinned)")
    }

    private func deleteSelection() {
        let picked = selectedClips()
        guard !picked.isEmpty else { return }
        picked.forEach { Store.shared.remove($0) }
        reload()
        log("deleted \(picked.count)")
    }

    private func openPreview(_ clip: Clip) {
        switch clip.kind {
        case .image:
            guard let name = clip.blob, let img = NSImage(contentsOf: Store.shared.blobURL(name)) else { return }
            let dims = clip.text.replacingOccurrences(of: "Image ", with: "")
            ImageViewer.shared.show(img, caption: "\(dims)   \u{00B7}   click or esc to close")
            log("open image viewer")
        case .file:
            let first = clip.text.split(separator: "\n").first.map(String.init) ?? clip.text
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
            log("reveal file in finder")
            hide()
        case .color:
            copySelection()
        case .text:
            break
        }
    }

    private func copySelection() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let clip = filtered[row]
        writeToPasteboard(clip)
        log("copy \(clip.kind.rawValue)")
        HUD.flash("Copied \u{00B7} \u{2318}V to paste")
    }

    @objc private func pinRowButton(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < filtered.count else { return }
        Store.shared.togglePin(filtered[row])
        reload()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for row in 0..<filtered.count {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipRowView else { continue }
            cell.applySelection(table.selectedRowIndexes.contains(row))
        }
        if let row = table.selectedRowIndexes.first, row < filtered.count {
            previewPane.show(filtered[row])
        } else {
            previewPane.show(nil)
        }
    }

    @objc private func copyRowButton(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < filtered.count else { return }
        let clip = filtered[row]
        writeToPasteboard(clip)
        HUD.flash("Copied")
    }

    private func thumbnail(for clip: Clip) -> (image: NSImage?, tint: NSColor) {
        switch clip.kind {
        case .image:
            if let name = clip.blob, let img = NSImage(contentsOf: Store.shared.blobURL(name)) {
                return (img, .clear)
            }
            return (NSImage(systemSymbolName: "photo", accessibilityDescription: nil), .secondaryLabelColor)
        case .file:
            let first = clip.text.split(separator: "\n").first.map(String.init) ?? clip.text
            let icon = NSWorkspace.shared.icon(forFile: first)
            icon.size = NSSize(width: 34, height: 34)
            return (icon, .clear)
        case .color:
            return (colorSwatch(clip.text), .clear)
        case .text:
            return (NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil), .secondaryLabelColor)
        }
    }

    private func colorSwatch(_ hex: String) -> NSImage {
        let size = NSSize(width: 34, height: 34)
        let img = NSImage(size: size)
        img.lockFocus()
        let color = NSColor(hex: hex) ?? .gray
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 7, yRadius: 7)
        color.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        img.unlockFocus()
        return img
    }

    private func badge(_ k: Clip.Kind) -> String {
        switch k {
        case .text: return "\u{1F4C4}"
        case .image: return "\u{1F5BC}"
        case .file: return "\u{1F4C1}"
        case .color: return "\u{1F3A8}"
        }
    }

    private func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " \u{21B5} ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 110 ? String(flat.prefix(110)) + "\u{2026}" : flat
    }

    // MARK: Search field keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            selectRow(min(table.selectedRow + 1, filtered.count - 1)); return true
        case #selector(NSResponder.moveUp(_:)):
            selectRow(max(table.selectedRow - 1, 0)); return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        search.updateClear()
        reload()
    }

    @objc private func doubleClicked() { commitSelection() }

    private func pasteSelection() {
        let picked = selectedClips()
        guard !picked.isEmpty else { return }
        guard picked.count > 1 else { paste(picked[0]); return }
        let joined = picked.compactMap { $0.kind == .image ? nil : $0.text }.joined(separator: "\n")
        guard !joined.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
        watcher.markCurrent()
        log("paste \(picked.count) joined")
        hide()
        guard AXIsProcessTrusted(), let target = targetApp else { return }
        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { Self.sendCommandV() }
    }

    private func commitSelection() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        paste(filtered[row])
    }

    // MARK: Paste

    private func writeToPasteboard(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clip.kind {
        case .text, .color:
            pb.setString(clip.text, forType: .string)
        case .file:
            pb.writeObjects(clip.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL })
        case .image:
            if let name = clip.blob, let data = try? Data(contentsOf: Store.shared.blobURL(name)) {
                pb.setData(data, forType: .png)
            }
        }
        watcher.markCurrent()
    }

    private func paste(_ clip: Clip) {
        log("paste kind=\(clip.kind.rawValue) trusted=\(AXIsProcessTrusted())")
        writeToPasteboard(clip)
        hide()
        guard AXIsProcessTrusted() else {
            HUD.flash("Copied. Grant Accessibility to auto-paste")
            return
        }
        guard let target = targetApp else { log("no target"); return }
        log("activating \(target.localizedName ?? "?") ok=\(target.activate())")
        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            Self.sendCommandV()
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func promptForAccessibility() {
        let key = "didPromptAccessibility"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc private func clearHistory() {
        Store.shared.clear()
        reload()
    }
}

// MARK: - Onboarding

/// Shown once per launch when Accessibility has not been granted. Without it the app can still
/// copy, but it cannot paste into another app, which is the whole point of the tool.
final class Onboarding: NSObject, NSWindowDelegate {
    static let shared = Onboarding()
    private var window: NSWindow?
    private var timer: Timer?

    private var forced = false

    func showIfNeeded() {
        forced = ProcessInfo.processInfo.environment["SHELF_FORCE_ONBOARDING"] == "1"
        guard forced || !AXIsProcessTrusted() else { return }
        guard window == nil else { return }
        build()
    }

    private func build() {
        let w: CGFloat = 420, h: CGFloat = 280
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Shelf"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.delegate = self
        win.level = .floating
        win.backgroundColor = .windowBackgroundColor

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let icon = NSImageView(frame: NSRect(x: w / 2 - 20, y: h - 80, width: 40, height: 40))
        icon.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyDown
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "One step and you are set")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 24, y: h - 104, width: w - 48, height: 20)
        content.addSubview(title)

        let body = NSTextField(wrappingLabelWithString:
            "Shelf needs Accessibility to paste into the app you are in. macOS keeps it on your machine and nothing is sent anywhere.")
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.frame = NSRect(x: 40, y: h - 164, width: w - 80, height: 56)
        content.addSubview(body)

        let open = NSButton(title: "Open Accessibility settings", target: self, action: #selector(openSettings))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.controlSize = .large
        open.frame = NSRect(x: w / 2 - 100, y: 76, width: 200, height: 32)
        content.addSubview(open)

        let check = NSButton(title: "Check again", target: self, action: #selector(recheck))
        check.bezelStyle = .inline
        check.isBordered = false
        check.contentTintColor = .controlAccentColor
        check.frame = NSRect(x: w / 2 - 55, y: 48, width: 110, height: 20)
        content.addSubview(check)

        let foot = NSTextField(labelWithString: "\u{2325}V opens Shelf from anywhere")
        foot.font = .systemFont(ofSize: 11.5)
        foot.textColor = .tertiaryLabelColor
        foot.alignment = .center
        foot.frame = NSRect(x: 24, y: 22, width: w - 48, height: 16)
        content.addSubview(foot)

        win.contentView = content
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        guard !forced else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, let w = self.window else { return }
            if AXIsProcessTrusted() {
                HUD.flash("Accessibility on \u{2014} press \u{2325}V")
                self.finish()
                w.orderOut(nil)
            }
        }
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheck() {
        if AXIsProcessTrusted() {
            HUD.flash("Accessibility on \u{2014} press \u{2325}V")
            finish()
            window?.orderOut(nil)
        } else {
            NSSound.beep()
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        window?.delegate = nil
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

// MARK: - HUD

enum HUD {
    static func flash(_ text: String) {
        let w: CGFloat = 260, h: CGFloat = 46
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]

        let eff = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        eff.material = .hudWindow
        eff.blendingMode = .behindWindow
        eff.state = .active
        eff.wantsLayer = true
        eff.layer?.cornerRadius = 12
        eff.layer?.masksToBounds = true

        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.alignment = .center
        l.frame = NSRect(x: 12, y: 15, width: w - 24, height: 16)
        eff.addSubview(l)
        p.contentView = eff

        if let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = s.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - w / 2, y: f.midY - 140))
        }
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { p.orderOut(nil) }
    }
}

// MARK: - App

let shelf = ShelfController()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        shelf.start()
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()