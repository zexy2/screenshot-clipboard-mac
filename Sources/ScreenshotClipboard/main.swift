import AppKit
import Foundation
import ImageIO
import Vision

final class PreviewActionContext {
    weak var panel: NSPanel?
    let fileURL: URL?
    let canonicalFileURL: URL?
    let imageData: Data?

    init(panel: NSPanel?, fileURL: URL?, canonicalFileURL: URL?, imageData: Data?) {
        self.panel = panel
        self.fileURL = fileURL
        self.canonicalFileURL = canonicalFileURL
        self.imageData = imageData
    }
}

private struct SavedImage {
    let canonicalURL: URL
    let applicationURL: URL?

    var preferredURL: URL {
        applicationURL ?? canonicalURL
    }
}

private final class ScreenshotDragDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let imageData: Data

    init(imageData: Data) {
        self.imageData = imageData
        super.init()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .png else { return }
        item.setData(imageData, forType: type)
    }
}

final class DraggableImageView: NSImageView {
    private let imageData: Data?
    private let fileURL: URL?
    private let dragImage: NSImage
    private var dragStart: NSPoint?
    private var dragStartTimestamp: TimeInterval = 0
    private var didMovePointer = false
    private var didBeginDragging = false
    var onDragBegan: (() -> Void)?
    var onClicked: (() -> Void)?
    var onSwipeRight: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    init(frame frameRect: NSRect, imageData: Data?, fileURL: URL?, image: NSImage) {
        self.imageData = imageData
        self.fileURL = fileURL
        self.dragImage = Self.makeDragImage(image, size: frameRect.size)
        super.init(frame: frameRect)
        registerForDraggedTypes([])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeDragImage(_ image: NSImage, size: NSSize) -> NSImage {
        let targetSize = NSSize(
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
        let result = NSImage(size: targetSize)
        result.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        result.unlockFocus()
        return result
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragStartTimestamp = event.timestamp
        didMovePointer = false
        didBeginDragging = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        let deltaX = current.x - dragStart.x
        let deltaY = current.y - dragStart.y
        let distance = hypot(deltaX, deltaY)
        guard distance >= 8 else { return }
        didMovePointer = true

        let elapsed = max(event.timestamp - dragStartTimestamp, 0.001)
        let horizontalVelocity = deltaX / elapsed
        if deltaX > 0 && abs(deltaY) <= 45 {
            guard deltaX >= 80, elapsed <= 0.45, horizontalVelocity >= 450 else { return }
            didBeginDragging = true
            onSwipeRight?()
            self.dragStart = nil
            return
        }

        let item = NSPasteboardItem()
        if let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        } else if let imageData {
            let dataProvider = ScreenshotDragDataProvider(imageData: imageData)
            if !item.setDataProvider(dataProvider, forTypes: [.png]) {
                item.setData(imageData, forType: .png)
            }
        } else {
            return
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: dragImage)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = false
        didBeginDragging = true
        onDragBegan?()
        self.dragStart = nil
    }

    override func mouseUp(with event: NSEvent) {
        if !didMovePointer && !didBeginDragging {
            onClicked?()
        }
        dragStart = nil
        didMovePointer = false
        didBeginDragging = false
    }
}

extension DraggableImageView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

final class ScreenshotClipboardDelegate: NSObject, NSApplicationDelegate {
    private let pasteboard = NSPasteboard.general
    private var screenshotRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("Ekran Görüntüleri", isDirectory: true)
            .appendingPathComponent("Mac Ekran Görüntüleri", isDirectory: true)
    }
    private var generalScreenshotFolder: URL {
        screenshotRoot.appendingPathComponent("Genel Ekran Görüntüleri", isDirectory: true)
    }
    private var applicationsFolder: URL {
        screenshotRoot.appendingPathComponent("Uygulamalar", isDirectory: true)
    }
    private let maximumImageDataSize = 50 * 1024 * 1024
    private let maximumImageDimension = 10_000
    private let maximumImagePixelCount = 50_000_000
    private let currentCloseButtonTag = 8142
    private let allCloseButtonTag = 8143
    private let galleryToggleButtonTag = 8144
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastUserApplicationName: String?
    private var applicationActivationObserver: NSObjectProtocol?
    private var pasteboardTimer: DispatchSourceTimer?
    private var previewPanels: [NSPanel] = []
    private var pendingPreviews: [(data: Data, fileURL: URL?, canonicalFileURL: URL?)] = []
    private var isDrainingPreviewQueue = false
    private var galleryExpanded = false
    private let pasteboardQueue = DispatchQueue(
        label: "com.zekiakgul.screenshot-clipboard.pasteboard-monitor",
        qos: .userInitiated
    )
    private let imageProcessingQueue = DispatchQueue(
        label: "com.zekiakgul.screenshot-clipboard.image-processing",
        qos: .utility
    )
    private let pendingImageLock = NSLock()
    private var pendingImageCount = 0
    private let maximumPendingImageCount = 20
    private let normalPasteboardInterval = DispatchTimeInterval.milliseconds(100)
    private let activePasteboardInterval = DispatchTimeInterval.milliseconds(50)
    private let activePollingBurstLength = 4
    private var activePollingChecksRemaining = 0
    private let externalAppTranslator = ExternalAppTranslator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updateLastUserApplicationName()

        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateLastUserApplicationName()
        }

        let pasteboardTimer = DispatchSource.makeTimerSource(queue: pasteboardQueue)
        pasteboardTimer.schedule(deadline: .now(), repeating: normalPasteboardInterval, leeway: .milliseconds(10))
        pasteboardTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let didDetectImage = self.checkPasteboard()
            self.adjustPasteboardPolling(afterDetectingImage: didDetectImage)
        }
        pasteboardTimer.resume()
        self.pasteboardTimer = pasteboardTimer
    }

    deinit {
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        }
        pasteboardTimer?.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func adjustPasteboardPolling(afterDetectingImage didDetectImage: Bool) {
        if didDetectImage {
            activePollingChecksRemaining = activePollingBurstLength
            pasteboardTimer?.schedule(
                deadline: .now() + activePasteboardInterval,
                repeating: activePasteboardInterval,
                leeway: .milliseconds(5)
            )
            return
        }

        guard activePollingChecksRemaining > 0 else { return }
        activePollingChecksRemaining -= 1
        if activePollingChecksRemaining == 0 {
            pasteboardTimer?.schedule(
                deadline: .now() + normalPasteboardInterval,
                repeating: normalPasteboardInterval,
                leeway: .milliseconds(10)
            )
        }
    }

    private func checkPasteboard() -> Bool {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return false }
        lastChangeCount = changeCount

        guard let imageData = pasteboard.data(forType: .png), !imageData.isEmpty else { return false }

        guard reservePendingImageSlot() else {
            NSLog("Screenshot Clipboard: görüntü kuyruğu dolu; yeni pano görüntüsü atlandı")
            return true
        }

        let applicationName = currentUserApplicationName()
        imageProcessingQueue.async { [weak self] in
            guard let self else { return }

            do {
                let validatedData = try self.validatePNGData(imageData)
                let savedImage: SavedImage?
                var saveError: Error?
                do {
                    savedImage = try self.saveImage(validatedData, applicationName: applicationName)
                } catch {
                    savedImage = nil
                    saveError = error
                }

                DispatchQueue.main.async {
                    self.releasePendingImageSlot()
                    if let saveError {
                        self.showError(title: "Ekran görüntüsü kaydedilemedi", detail: saveError.localizedDescription)
                    }
                    self.enqueuePreview(
                        validatedData,
                        fileURL: savedImage?.preferredURL,
                        canonicalFileURL: savedImage?.canonicalURL
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.releasePendingImageSlot()
                    self.showError(title: "Geçersiz ekran görüntüsü", detail: error.localizedDescription)
                }
            }
        }
        return true
    }

    @objc private func updateLastUserApplicationName() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let name = application.localizedName
        else { return }

        let ignoredNames = ["screenshot clipboard", "screenshot", "systemuiserver"]
        guard !ignoredNames.contains(name.lowercased()),
              let cleaned = sanitizedApplicationName(name)
        else { return }

        pendingImageLock.lock()
        lastUserApplicationName = cleaned
        pendingImageLock.unlock()
    }

    private func currentUserApplicationName() -> String? {
        pendingImageLock.lock()
        defer { pendingImageLock.unlock() }
        return lastUserApplicationName
    }

    private func reservePendingImageSlot() -> Bool {
        pendingImageLock.lock()
        defer { pendingImageLock.unlock() }
        guard pendingImageCount < maximumPendingImageCount else { return false }
        pendingImageCount += 1
        return true
    }

    private func releasePendingImageSlot() {
        pendingImageLock.lock()
        pendingImageCount = max(pendingImageCount - 1, 0)
        pendingImageLock.unlock()
    }

    private func sanitizedApplicationName(_ name: String) -> String? {
        var invalidCharacters = CharacterSet.controlCharacters
        invalidCharacters.insert(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }

    private func validatePNGData(_ data: Data) throws -> Data {
        guard data.count <= maximumImageDataSize else {
            throw NSError(
                domain: "ScreenshotClipboard",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PNG boyutu 50 MB sınırını aşıyor."
                ]
            )
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else {
            throw NSError(
                domain: "ScreenshotClipboard",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Pano içeriği geçerli bir PNG değil."
                ]
            )
        }

        let pixelCount = Int64(width) * Int64(height)
        guard width <= maximumImageDimension,
              height <= maximumImageDimension,
              pixelCount <= Int64(maximumImagePixelCount)
        else {
            throw NSError(
                domain: "ScreenshotClipboard",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Görüntü boyutları güvenli sınırı aşıyor."
                ]
            )
        }

        guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw NSError(
                domain: "ScreenshotClipboard",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "PNG görüntüsü çözümlenemedi."
                ]
            )
        }

        return data
    }

    private func saveImage(_ data: Data, applicationName: String?) throws -> SavedImage {
        try FileManager.default.createDirectory(at: screenshotRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: screenshotRoot.path)
        try FileManager.default.createDirectory(at: generalScreenshotFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: generalScreenshotFolder.path)
        try FileManager.default.createDirectory(at: applicationsFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: applicationsFolder.path)

        let folderName = sanitizedApplicationName(applicationName ?? "") ?? "Diğer"
        let applicationFolder = applicationsFolder.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: applicationFolder.path)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"

        let timestamp = formatter.string(from: Date())
        let appSuffix = " - \(folderName)"
        let baseName = "Ekran Resmi \(timestamp)\(appSuffix)"
        var canonicalURL = generalScreenshotFolder.appendingPathComponent(baseName).appendingPathExtension("png")
        var applicationURL = applicationFolder.appendingPathComponent(baseName).appendingPathExtension("png")
        var suffix = 2

        while FileManager.default.fileExists(atPath: canonicalURL.path)
                || FileManager.default.fileExists(atPath: applicationURL.path) {
            canonicalURL = generalScreenshotFolder
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("png")
            applicationURL = applicationFolder
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("png")
            suffix += 1
        }

        try data.write(to: canonicalURL, options: .atomic)

        do {
            try FileManager.default.linkItem(at: canonicalURL, to: applicationURL)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: canonicalURL.path)
            return SavedImage(canonicalURL: canonicalURL, applicationURL: applicationURL)
        } catch {
            NSLog("Screenshot Clipboard: uygulama hard linki oluşturulamadı: %@", error.localizedDescription)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: canonicalURL.path)
            return SavedImage(canonicalURL: canonicalURL, applicationURL: nil)
        }
    }

    private func showError(title: String, detail: String) {
        NSLog("Screenshot Clipboard: %@ - %@", title, detail)
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func enqueuePreview(_ data: Data, fileURL: URL?, canonicalFileURL: URL?) {
        pendingPreviews.append((data: data, fileURL: fileURL, canonicalFileURL: canonicalFileURL))
        while pendingPreviews.count > 3 {
            pendingPreviews.removeFirst()
        }

        guard !isDrainingPreviewQueue else { return }
        isDrainingPreviewQueue = true
        showNextPreview()
    }

    private func showNextPreview() {
        guard !pendingPreviews.isEmpty else {
            isDrainingPreviewQueue = false
            return
        }

        let next = pendingPreviews.removeFirst()
        showPreview(next.data, fileURL: next.fileURL, canonicalFileURL: next.canonicalFileURL)
        if pendingPreviews.isEmpty {
            isDrainingPreviewQueue = false
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showNextPreview()
            }
        }
    }

    private func controlButtons(in panel: NSPanel) -> [NSButton] {
        panel.contentView?.subviews
            .compactMap { $0 as? NSButton }
            .filter {
                $0.tag == currentCloseButtonTag
                    || $0.tag == allCloseButtonTag
                    || $0.tag == galleryToggleButtonTag
            } ?? []
    }

    private func panel(containing control: NSControl) -> NSPanel? {
        previewPanels.first { panel in
            panel.contentView?.subviews.contains { $0 === control } == true
        }
    }

    private func configureSymbolButton(
        _ button: NSButton,
        systemName: String,
        accessibilityLabel: String,
        toolTip: String
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = toolTip
    }

    private func relayoutPreviewPanels() {
        previewPanels.removeAll { !$0.isVisible }
        guard !previewPanels.isEmpty else { return }

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let compactHorizontalSpacing: CGFloat = 8
        let compactVerticalSpacing: CGFloat = 14
        let widestPanel = previewPanels.map { $0.frame.width }.max() ?? 0
        let fanHorizontalStep = min(82, max(58, widestPanel * 0.27))
        let fanRise = min(56, max(36, visibleFrame.height * 0.065))
        let fanCurve = min(12, max(6, fanRise * 0.2))
        let expandedWidth = widestPanel
            + CGFloat(max(previewPanels.count - 1, 0)) * fanHorizontalStep
        let expandedFits = expandedWidth <= visibleFrame.width - 48
        let canToggleGallery = previewPanels.count > 1
        if !canToggleGallery {
            galleryExpanded = false
        }

        if galleryExpanded && expandedFits {
            var x = visibleFrame.maxX - expandedWidth - 24
            for (index, panel) in previewPanels.enumerated() {
                let progress = previewPanels.count > 1
                    ? CGFloat(index) / CGFloat(previewPanels.count - 1)
                    : 0
                let arcProgress = progress * fanRise
                let centerLift = progress * (1 - progress) * fanCurve
                panel.setFrameOrigin(NSPoint(
                    x: x,
                    y: visibleFrame.minY + 24 + arcProgress + centerLift
                ))
                x += fanHorizontalStep
                panel.orderFront(nil)
            }
        } else {
            for (index, panel) in previewPanels.enumerated() {
                let depth = previewPanels.count - index - 1
                panel.setFrameOrigin(NSPoint(
                    x: visibleFrame.maxX - panel.frame.width - 24 - CGFloat(depth) * compactHorizontalSpacing,
                    y: visibleFrame.minY + 24 + CGFloat(depth) * compactVerticalSpacing
                ))
            }
        }

        for panel in previewPanels {
            controlButtons(in: panel).forEach { button in
                let isGalleryButton = button.tag == galleryToggleButtonTag
                button.isHidden = panel !== previewPanels.last || (isGalleryButton && !canToggleGallery)
                if button.tag == currentCloseButtonTag {
                    configureSymbolButton(
                        button,
                        systemName: "xmark",
                        accessibilityLabel: "Bu görüntüyü kapat",
                        toolTip: "Bu görüntüyü kapat"
                    )
                } else if button.tag == allCloseButtonTag {
                    configureSymbolButton(
                        button,
                        systemName: "xmark.circle",
                        accessibilityLabel: "Tüm görüntüleri kapat",
                        toolTip: "Tüm görüntüleri kapat"
                    )
                } else if isGalleryButton {
                    let isExpanded = galleryExpanded && expandedFits && canToggleGallery
                    configureSymbolButton(
                        button,
                        systemName: isExpanded ? "rectangle.stack" : "square.grid.2x2",
                        accessibilityLabel: isExpanded ? "Kart görünümünü kapat" : "Görüntüleri kart olarak aç",
                        toolTip: isExpanded
                            ? "Kart görünümünü kapat"
                            : "Görüntüleri kart olarak aç"
                    )
                }
            }
        }
    }

    private func dismissPreview(_ panel: NSPanel) {
        panel.orderOut(nil)
        previewPanels.removeAll { $0 === panel || !$0.isVisible }
        relayoutPreviewPanels()
    }

    @objc private func dismissCurrentPreview(_ sender: Any?) {
        guard let control = sender as? NSControl, let panel = panel(containing: control) else { return }
        dismissPreview(panel)
    }

    @objc private func dismissAllPreviews(_ sender: Any?) {
        previewPanels.forEach { $0.orderOut(nil) }
        previewPanels.removeAll()
        galleryExpanded = false
    }

    @objc private func toggleGallery(_ sender: Any?) {
        galleryExpanded.toggle()
        relayoutPreviewPanels()
    }

    private func makeMenuItem(
        _ title: String,
        action: Selector,
        context: PreviewActionContext,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = context
        item.isEnabled = enabled
        return item
    }

    private func makeContextMenu(
        for panel: NSPanel,
        fileURL: URL?,
        canonicalFileURL: URL?,
        imageData: Data?
    ) -> NSMenu {
        let context = PreviewActionContext(
            panel: panel,
            fileURL: fileURL,
            canonicalFileURL: canonicalFileURL,
            imageData: imageData
        )
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Preview’da aç", action: #selector(openPreviewFromMenu(_:)), context: context, enabled: fileURL != nil))
        menu.addItem(makeMenuItem("Finder’da göster", action: #selector(revealInFinder(_:)), context: context, enabled: fileURL != nil))
        menu.addItem(makeMenuItem("Dosya yolunu kopyala", action: #selector(copyFilePath(_:)), context: context, enabled: fileURL != nil))
        menu.addItem(makeMenuItem("Metni kopyala (OCR)", action: #selector(copyOCRText(_:)), context: context))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("ChatGPT’de çevir", action: #selector(translateWithChatGPT(_:)), context: context))
        menu.addItem(makeMenuItem("Gemini’de çevir", action: #selector(translateWithGemini(_:)), context: context))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Görüntüyü Çöpe Taşı", action: #selector(moveImageToTrash(_:)), context: context, enabled: fileURL != nil))
        return menu
    }

    private func context(from sender: Any?) -> PreviewActionContext? {
        (sender as? NSMenuItem)?.representedObject as? PreviewActionContext
    }

    @objc private func openPreviewFromMenu(_ sender: Any?) {
        guard let context = context(from: sender), let fileURL = context.fileURL else { return }
        context.panel?.orderOut(nil)
        NSWorkspace.shared.open(fileURL)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let fileURL = context(from: sender)?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func copyFilePath(_ sender: Any?) {
        guard let fileURL = context(from: sender)?.fileURL else { return }
        pasteboard.clearContents()
        pasteboard.setString(fileURL.path, forType: .string)
    }

    @objc private func moveImageToTrash(_ sender: Any?) {
        guard let context = context(from: sender), let fileURL = context.fileURL else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Bu görüntü çöpe taşınsın mı?"
        alert.informativeText = "Ana klasördeki ve uygulama klasöründeki bağlantılar kaldırılacak.\n\n\(fileURL.lastPathComponent)"
        alert.addButton(withTitle: "Çöpe Taşı")
        alert.addButton(withTitle: "İptal")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let urls = [context.fileURL, context.canonicalFileURL]
                .compactMap { $0 }
                .reduce(into: [URL]()) { result, url in
                    if !result.contains(url) {
                        result.append(url)
                    }
                }
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            if let panel = context.panel {
                dismissPreview(panel)
            }
        } catch {
            let errorAlert = NSAlert(error: error)
            errorAlert.runModal()
        }
    }

    @objc private func copyOCRText(_ sender: Any?) {
        guard let context = context(from: sender) else { return }

        let imageData: Data
        if let cachedImageData = context.imageData {
            imageData = cachedImageData
        } else if let fileURL = context.fileURL,
                  let fileImageData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            imageData = fileImageData
        } else {
            return
        }

        guard let image = NSImage(data: imageData) else { return }

        var imageRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    DispatchQueue.main.async {
                        self?.showOCRResult(title: "OCR başarısız", detail: error.localizedDescription)
                    }
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let orderedLines = observations
                    .sorted {
                        let verticalDifference = abs($0.boundingBox.midY - $1.boundingBox.midY)
                        if verticalDifference > 0.03 {
                            return $0.boundingBox.midY > $1.boundingBox.midY
                        }
                        return $0.boundingBox.minX < $1.boundingBox.minX
                    }
                    .compactMap { $0.topCandidates(1).first?.string }
                let recognizedText = orderedLines.joined(separator: "\n")

                DispatchQueue.main.async {
                    guard !recognizedText.isEmpty else {
                        self?.showOCRResult(title: "Metin bulunamadı", detail: "Bu görüntüde okunabilir metin tespit edilemedi.")
                        return
                    }
                    self?.pasteboard.clearContents()
                    self?.pasteboard.setString(recognizedText, forType: .string)
                    self?.showOCRResult(title: "Metin panoya kopyalandı", detail: "\(orderedLines.count) satır kopyalandı.")
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["tr-TR", "en-US"]

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                DispatchQueue.main.async {
                    self?.showOCRResult(title: "OCR başarısız", detail: error.localizedDescription)
                }
            }
        }
    }

    @objc private func translateWithChatGPT(_ sender: Any?) {
        startExternalTranslation(target: .chatGPT, sender: sender)
    }

    @objc private func translateWithGemini(_ sender: Any?) {
        startExternalTranslation(target: .gemini, sender: sender)
    }

    private func startExternalTranslation(target: TranslationTarget, sender: Any?) {
        guard let context = context(from: sender) else { return }

        let imageData: Data?
        if let cachedImageData = context.imageData {
            imageData = cachedImageData
        } else if let fileURL = context.fileURL {
            imageData = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        } else {
            imageData = nil
        }

        guard let imageData, !imageData.isEmpty else {
            showTranslationError(ExternalAppTranslationError.imageUnavailable)
            return
        }

        if let panel = context.panel {
            dismissPreview(panel)
        }

        externalAppTranslator.send(imageData: imageData, to: target) { [weak self] result in
            switch result {
            case .success:
                break
            case let .failure(error):
                self?.showTranslationError(error)
            }
        }
    }

    private func showTranslationError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Çeviri gönderilemedi"
        alert.informativeText = error.localizedDescription

        if let translationError = error as? ExternalAppTranslationError,
           case .accessibilityRequired = translationError {
            alert.addButton(withTitle: "Accessibility Ayarlarını Aç")
            alert.addButton(withTitle: "İptal")
            if alert.runModal() == .alertFirstButtonReturn {
                externalAppTranslator.openAccessibilitySettings()
            }
            return
        }

        alert.addButton(withTitle: "Tamam")
        alert.runModal()
    }

    private func showOCRResult(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Tamam")
        alert.runModal()
    }

    private func makePreviewImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
    }

    private func showPreview(_ data: Data, fileURL: URL?, canonicalFileURL: URL?) {
        guard let image = makePreviewImage(from: data) else { return }
        let fallbackImageData = fileURL == nil ? data : nil

        let maxWidth: CGFloat = 250
        let maxHeight: CGFloat = 160
        let padding: CGFloat = 8
        let controlsHeight: CGFloat = 32
        let minimumPanelWidth: CGFloat = 180
        let imageSize = image.size
        let scale = min(maxWidth / max(imageSize.width, 1), maxHeight / max(imageSize.height, 1), 1)
        let imageViewSize = NSSize(width: max(imageSize.width * scale, 1), height: max(imageSize.height * scale, 1))
        let panelSize = NSSize(
            width: max(imageViewSize.width + padding * 2, minimumPanelWidth),
            height: imageViewSize.height + padding * 2 + controlsHeight
        )

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.maxX - panelSize.width - 24,
            y: visibleFrame.minY + 24
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false

        let imageView = DraggableImageView(frame: NSRect(
            x: (panelSize.width - imageViewSize.width) / 2,
            y: padding + controlsHeight,
            width: imageViewSize.width,
            height: imageViewSize.height
        ), imageData: fallbackImageData, fileURL: fileURL, image: image)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.onDragBegan = { [weak self, weak panel] in
            if let panel {
                self?.dismissPreview(panel)
            }
        }
        imageView.onClicked = { [weak panel] in
            panel?.orderOut(nil)
            if let fileURL {
                NSWorkspace.shared.open(fileURL)
            }
        }
        imageView.onSwipeRight = { [weak self, weak panel] in
            if let panel {
                self?.dismissPreview(panel)
            }
        }
        imageView.contextMenuProvider = { [weak self, weak panel] in
            guard let self, let panel else { return nil }
            return self.makeContextMenu(
                for: panel,
                fileURL: fileURL,
                canonicalFileURL: canonicalFileURL,
                imageData: fallbackImageData
            )
        }

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        container.layer?.masksToBounds = true
        container.addSubview(imageView)

        let controlButtonWidth: CGFloat = 30
        let controlGap: CGFloat = 6
        let currentCloseButton = NSButton(frame: NSRect(
            x: panelSize.width - padding - controlButtonWidth,
            y: padding + 5,
            width: controlButtonWidth,
            height: 22
        ))
        currentCloseButton.tag = currentCloseButtonTag
        currentCloseButton.bezelStyle = .rounded
        configureSymbolButton(
            currentCloseButton,
            systemName: "xmark",
            accessibilityLabel: "Bu görüntüyü kapat",
            toolTip: "Bu görüntüyü kapat"
        )
        currentCloseButton.target = self
        currentCloseButton.action = #selector(dismissCurrentPreview(_:))

        let allCloseButton = NSButton(frame: NSRect(
            x: panelSize.width - padding - controlButtonWidth - controlGap - controlButtonWidth,
            y: padding + 5,
            width: controlButtonWidth,
            height: 22
        ))
        allCloseButton.tag = allCloseButtonTag
        allCloseButton.bezelStyle = .rounded
        configureSymbolButton(
            allCloseButton,
            systemName: "xmark.circle",
            accessibilityLabel: "Tüm görüntüleri kapat",
            toolTip: "Tüm görüntüleri kapat"
        )
        allCloseButton.target = self
        allCloseButton.action = #selector(dismissAllPreviews(_:))
        let galleryToggleButton = NSButton(frame: NSRect(
            x: panelSize.width - padding - controlButtonWidth - controlGap - controlButtonWidth - controlGap - controlButtonWidth,
            y: padding + 5,
            width: controlButtonWidth,
            height: 22
        ))
        galleryToggleButton.tag = galleryToggleButtonTag
        galleryToggleButton.bezelStyle = .rounded
        configureSymbolButton(
            galleryToggleButton,
            systemName: galleryExpanded ? "rectangle.stack" : "square.grid.2x2",
            accessibilityLabel: galleryExpanded ? "Kart görünümünü kapat" : "Görüntüleri kart olarak aç",
            toolTip: galleryExpanded ? "Kart görünümünü kapat" : "Görüntüleri kart olarak aç"
        )
        galleryToggleButton.target = self
        galleryToggleButton.action = #selector(toggleGallery(_:))
        container.addSubview(currentCloseButton)
        container.addSubview(allCloseButton)
        container.addSubview(galleryToggleButton)

        panel.contentView = container
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        previewPanels.removeAll { !$0.isVisible }
        if previewPanels.count >= 3 {
            let oldestPanel = previewPanels.removeFirst()
            oldestPanel.orderOut(nil)
        }
        previewPanels.append(panel)
        relayoutPreviewPanels()

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if let panel {
                self?.previewPanels.removeAll { $0 === panel }
                self?.relayoutPreviewPanels()
            }
        }
    }

}

let application = NSApplication.shared
let delegate = ScreenshotClipboardDelegate()
application.delegate = delegate
application.run()
