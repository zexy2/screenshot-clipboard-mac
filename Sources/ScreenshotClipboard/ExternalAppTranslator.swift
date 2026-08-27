import AppKit
import ApplicationServices
import Foundation

enum TranslationTarget: CaseIterable {
    case chatGPT
    case gemini

    var displayName: String {
        switch self {
        case .chatGPT:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .chatGPT:
            // com.openai.chat is the installed ChatGPT Classic app. The
            // fallback handles the newer app bundle installed as ChatGPT.app.
            return ["com.openai.chat", "com.openai.codex"]
        case .gemini:
            return ["com.google.GeminiMacOS"]
        }
    }
}

enum ExternalAppTranslationError: LocalizedError {
    case alreadyRunning
    case applicationNotInstalled(String)
    case applicationLaunchFailed(String)
    case accessibilityRequired
    case messageFieldNotFound(String)
    case imageUnavailable
    case automationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Başka bir çeviri işlemi devam ediyor."
        case let .applicationNotInstalled(name):
            return "\(name) uygulaması bulunamadı."
        case let .applicationLaunchFailed(detail):
            return "Uygulama açılamadı: \(detail)"
        case .accessibilityRequired:
            return "Otomatik gönderim için Screenshot Clipboard uygulamasına macOS Accessibility izni gerekiyor."
        case let .messageFieldNotFound(name):
            return "\(name) içinde yeni sohbetin mesaj alanı bulunamadı. Giriş yapılmamış veya uygulama arayüzü değişmiş olabilir."
        case .imageUnavailable:
            return "Seçilen ekran görüntüsü okunamadı."
        case let .automationFailed(detail):
            return detail
        }
    }
}

final class ExternalAppTranslator {
    private let pasteboard = NSPasteboard.general
    private let automationQueue = DispatchQueue(
        label: "com.zekiakgul.screenshot-clipboard.external-app-automation",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var isBusy = false

    private let translationPrompt = "Bu ekran görüntüsündeki metni anlamı bozulmadan Türkçeye çevir. Düzeni mümkün olduğunca koru. Yalnızca çeviriyi ver."
    private let keyEventSource = CGEventSource(stateID: .hidSystemState)

    func send(
        imageData: Data,
        to target: TranslationTarget,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard beginOperation() else {
            DispatchQueue.main.async {
                completion(.failure(ExternalAppTranslationError.alreadyRunning))
            }
            return
        }

        guard !imageData.isEmpty else {
            finishOperation()
            DispatchQueue.main.async {
                completion(.failure(ExternalAppTranslationError.imageUnavailable))
            }
            return
        }

        guard isAccessibilityTrusted() else {
            finishOperation()
            DispatchQueue.main.async {
                completion(.failure(ExternalAppTranslationError.accessibilityRequired))
            }
            return
        }

        automationQueue.async { [weak self] in
            guard let self else { return }
            let result = self.perform(imageData: imageData, target: target)
            self.finishOperation()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func beginOperation() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    private func finishOperation() {
        stateLock.lock()
        isBusy = false
        stateLock.unlock()
    }

    private func isAccessibilityTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func perform(imageData: Data, target: TranslationTarget) -> Result<Void, Error> {
        guard let applicationURL = applicationURL(for: target) else {
            return .failure(ExternalAppTranslationError.applicationNotInstalled(target.displayName))
        }

        guard let application = activateApplication(at: applicationURL) else {
            return .failure(ExternalAppTranslationError.applicationLaunchFailed(target.displayName))
        }

        guard let newConversationButton = waitForNewConversationButton(in: application, timeout: 8.0),
              press(newConversationButton)
        else {
            return .failure(ExternalAppTranslationError.automationFailed("\(target.displayName) Yeni sohbet düğmesi bulunamadı; mevcut sohbete yazılmadı."))
        }

        Thread.sleep(forTimeInterval: 0.5)
        guard let messageField = waitForMessageField(in: application, timeout: 8.0) else {
            return .failure(ExternalAppTranslationError.messageFieldNotFound(target.displayName))
        }

        guard focus(messageField) else {
            return .failure(ExternalAppTranslationError.automationFailed("\(target.displayName) mesaj alanı odaklanamadı."))
        }

        setPasteboardImage(imageData)
        postKey(keyCode: 9, flags: .maskCommand) // V

        // Pasting an image can cause the web-based composer to be recreated.
        // Resolve the current field again instead of using a stale AX element.
        Thread.sleep(forTimeInterval: 1.0)
        guard let promptField = waitForMessageField(in: application, timeout: 6.0),
              focus(promptField)
        else {
            setPasteboardImage(imageData)
            return .failure(ExternalAppTranslationError.automationFailed("\(target.displayName) mesaj alanı görselden sonra odağını kaybetti."))
        }

        Thread.sleep(forTimeInterval: 0.5)
        guard setValue(translationPrompt, on: promptField),
              waitForPrompt(in: application, timeout: 2.0)
        else {
            setPasteboardImage(imageData)
            return .failure(ExternalAppTranslationError.automationFailed("\(target.displayName) çeviri istemi mesaj alanına yazılamadı; görsel gönderilmeden durduruldu."))
        }

        guard let sendButton = waitForSendButton(in: application, timeout: 6.0),
              press(sendButton)
        else {
            setPasteboardImage(imageData)
            return .failure(ExternalAppTranslationError.automationFailed("\(target.displayName) Gönder düğmesi bulunamadı veya etkin değil; işlem gönderilmeden durduruldu."))
        }

        Thread.sleep(forTimeInterval: 0.25)
        setPasteboardImage(imageData)

        return .success(())
    }

    private func applicationURL(for target: TranslationTarget) -> URL? {
        for bundleIdentifier in target.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }

        // If an app is running from a non-standard location and Launch
        // Services cannot resolve it, use the running bundle as a fallback.
        for bundleIdentifier in target.bundleIdentifiers {
            if let runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                return runningApplication.bundleURL
            }
        }
        return nil
    }

    private func activateApplication(at url: URL) -> NSRunningApplication? {
        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        if let bundleIdentifier,
           let runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            guard runningApplication.activate(options: [.activateAllWindows]) else {
                return nil
            }
            Thread.sleep(forTimeInterval: 0.6)
            return runningApplication
        }

        let semaphore = DispatchSemaphore(value: 0)
        var launchedApplication: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { application, _ in
            launchedApplication = application
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 8) == .success,
              let launchedApplication,
              launchedApplication.activate(options: [.activateAllWindows])
        else {
            return nil
        }

        // Native app startup can finish after openApplication's completion.
        Thread.sleep(forTimeInterval: 1.2)
        return launchedApplication
    }

    private func waitForMessageField(in application: NSRunningApplication, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let applicationElement = interactionRoot(for: application)

        repeat {
            if let messageElement = findMessageField(in: applicationElement) {
                return messageElement
            }
            if let focusedElement = focusedEditableElement(in: applicationElement) {
                return focusedElement
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        return nil
    }

    private func waitForNewConversationButton(in application: NSRunningApplication, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let applicationElement = interactionRoot(for: application)

        repeat {
            if let newConversationButton = findNewConversationButton(in: applicationElement) {
                return newConversationButton
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        return nil
    }

    private func findNewConversationButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= 12 else { return nil }

        if isNewConversationButton(element) {
            return element
        }

        guard let children = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let result = findNewConversationButton(in: child, depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    private func isNewConversationButton(_ element: AXUIElement) -> Bool {
        guard (copyAttribute(kAXRoleAttribute, from: element) as? String) == kAXButtonRole else {
            return false
        }

        guard hasUsableSize(element) else { return false }

        if let enabled = copyAttribute(kAXEnabledAttribute, from: element) as? Bool, !enabled {
            return false
        }

        let searchableText = [
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXRoleDescriptionAttribute
        ]
        .compactMap { copyAttribute($0, from: element) as? String }
        .joined(separator: " ")
        .lowercased()

        let newConversationTerms = ["new chat", "new conversation", "yeni sohbet", "yeni konuşma"]
        return newConversationTerms.contains { searchableText.contains($0) }
    }

    private func focusedEditableElement(in applicationElement: AXUIElement) -> AXUIElement? {
        guard let focused = copyElementAttribute(kAXFocusedUIElementAttribute, from: applicationElement) else {
            return nil
        }
        return isEditable(focused) && looksLikeMessageField(focused) ? focused : nil
    }

    private func findMessageField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= 12 else { return nil }

        if isEditable(element), looksLikeMessageField(element) {
            return element
        }

        guard let children = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let result = findMessageField(in: child, depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    private func waitForSendButton(in application: NSRunningApplication, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let applicationElement = interactionRoot(for: application)

        repeat {
            if let sendButton = findSendButton(in: applicationElement) {
                return sendButton
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        return nil
    }

    private func waitForPrompt(in application: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let root = interactionRoot(for: application)
            if let messageField = findMessageField(in: root),
               let value = copyAttribute(kAXValueAttribute, from: messageField) as? String,
               value.contains(translationPrompt) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        return false
    }

    private func findSendButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= 12 else { return nil }

        if isSendButton(element) {
            return element
        }

        guard let children = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let result = findSendButton(in: child, depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    private func isSendButton(_ element: AXUIElement) -> Bool {
        guard (copyAttribute(kAXRoleAttribute, from: element) as? String) == kAXButtonRole else {
            return false
        }

        guard hasUsableSize(element) else { return false }

        if let enabled = copyAttribute(kAXEnabledAttribute, from: element) as? Bool, !enabled {
            return false
        }

        let searchableText = [
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXRoleDescriptionAttribute
        ]
        .compactMap { copyAttribute($0, from: element) as? String }
        .joined(separator: " ")
        .lowercased()

        let sendTerms = ["send", "submit", "gönder", "yolla"]
        return sendTerms.contains { searchableText.contains($0) }
    }

    private func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func interactionRoot(for application: NSRunningApplication) -> AXUIElement {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        return copyElementAttribute(kAXFocusedWindowAttribute, from: applicationElement)
            ?? copyElementAttribute(kAXMainWindowAttribute, from: applicationElement)
            ?? applicationElement
    }

    private func hasUsableSize(_ element: AXUIElement) -> Bool {
        guard let rawSize = copyAttribute(kAXSizeAttribute, from: element),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else {
            return true
        }

        let sizeValue = rawSize as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue, .cgSize, &size) else { return false }
        return size.width > 1 && size.height > 1
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        guard let role = copyAttribute(kAXRoleAttribute, from: element) as? String else {
            return false
        }
        return role == kAXTextAreaRole || role == kAXTextFieldRole
    }

    private func looksLikeMessageField(_ element: AXUIElement) -> Bool {
        let role = copyAttribute(kAXRoleAttribute, from: element) as? String
        if role == kAXTextAreaRole {
            // ChatGPT Classic and Gemini expose their compose box as an
            // unlabeled AXTextArea. Login/search controls are text fields.
            return true
        }

        let searchableText = [
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXPlaceholderValueAttribute,
            kAXRoleDescriptionAttribute
        ]
        .compactMap { copyAttribute($0, from: element) as? String }
        .joined(separator: " ")
        .lowercased()

        if searchableText.isEmpty {
            return false
        }

        let messageTerms = ["message", "ask", "prompt", "chat", "mesaj", "sor", "yaz"]
        return messageTerms.contains { searchableText.contains($0) }
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private func setPasteboardImage(_ data: Data) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    private func setValue(_ value: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(
            keyboardEventSource: keyEventSource,
            virtualKey: keyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: keyEventSource,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        keyUp.post(tap: .cghidEventTap)
    }
}
