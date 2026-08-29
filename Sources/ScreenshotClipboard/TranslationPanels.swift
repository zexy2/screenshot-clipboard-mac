import AppKit

final class TranslationReviewPanel: NSPanel, NSWindowDelegate {
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    private var didResolve = false

    init(correctedText: String, translatedText: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "Çeviriyi incele"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        let correctedLabel = makeLabel("Düzeltilmiş Türkçe", frame: NSRect(x: 20, y: 366, width: 520, height: 24))
        let translatedLabel = makeLabel("İngilizce çeviri", frame: NSRect(x: 20, y: 194, width: 520, height: 24))
        root.addSubview(correctedLabel)
        root.addSubview(translatedLabel)
        root.addSubview(makeTextView(correctedText, frame: NSRect(x: 20, y: 224, width: 520, height: 132)))
        root.addSubview(makeTextView(translatedText, frame: NSRect(x: 20, y: 52, width: 520, height: 132)))

        let cancelButton = NSButton(frame: NSRect(x: 330, y: 14, width: 100, height: 28))
        cancelButton.title = "İptal"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTranslation(_:))
        cancelButton.bezelStyle = .rounded
        root.addSubview(cancelButton)

        let applyButton = NSButton(frame: NSRect(x: 440, y: 14, width: 100, height: 28))
        applyButton.title = "Uygula"
        applyButton.target = self
        applyButton.action = #selector(applyTranslation(_:))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        root.addSubview(applyButton)

        contentView = root
        center()
    }

    @objc private func applyTranslation(_ sender: Any?) {
        guard !didResolve else { return }
        didResolve = true
        onApply?()
        close()
    }

    @objc private func cancelTranslation(_ sender: Any?) {
        resolveCancel()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        resolveCancel()
    }

    private func resolveCancel() {
        guard !didResolve else { return }
        didResolve = true
        onCancel?()
    }

    private func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func makeTextView(_ text: String, frame: NSRect) -> NSScrollView {
        let textView = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        return scrollView
    }
}

final class TranslationFeedbackPanel: NSPanel, NSWindowDelegate {
    var onPrimaryAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var didResolve = false

    init(title: String, detail: String, primaryTitle: String?) {
        let panelWidth: CGFloat = 430
        let panelHeight: CGFloat = primaryTitle == nil ? 142 : 178
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 18, y: panelHeight - 42, width: panelWidth - 58, height: 24)
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        root.addSubview(titleLabel)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.frame = NSRect(x: 18, y: primaryTitle == nil ? 45 : 70, width: panelWidth - 36, height: primaryTitle == nil ? 60 : 72)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        root.addSubview(detailLabel)

        let closeButton = NSButton(frame: NSRect(x: panelWidth - 40, y: panelHeight - 42, width: 24, height: 24))
        closeButton.title = "×"
        closeButton.target = self
        closeButton.action = #selector(dismiss(_:))
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 18)
        root.addSubview(closeButton)

        if let primaryTitle {
            let primaryButton = NSButton(frame: NSRect(x: panelWidth - 160, y: 16, width: 140, height: 28))
            primaryButton.title = primaryTitle
            primaryButton.target = self
            primaryButton.action = #selector(primaryAction(_:))
            primaryButton.bezelStyle = .rounded
            root.addSubview(primaryButton)
        }

        contentView = root
        positionAtTopRight()
    }

    @objc private func primaryAction(_ sender: Any?) {
        guard !didResolve else { return }
        didResolve = true
        onPrimaryAction?()
        close()
    }

    @objc private func dismiss(_ sender: Any?) {
        resolveDismiss()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        resolveDismiss()
    }

    private func resolveDismiss() {
        guard !didResolve else { return }
        didResolve = true
        onDismiss?()
    }

    private func positionAtTopRight() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - frame.width - 24,
            y: visibleFrame.maxY - frame.height - 24
        ))
    }
}
