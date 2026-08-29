import AppKit
import ApplicationServices
import Foundation
import Translation

enum NativeTranslationDirection: String, CaseIterable {
    case turkishToEnglish = "tr-en"
    case englishToTurkish = "en-tr"

    var sourceIdentifier: String {
        switch self {
        case .turkishToEnglish:
            return "tr"
        case .englishToTurkish:
            return "en"
        }
    }

    var targetIdentifier: String {
        switch self {
        case .turkishToEnglish:
            return "en"
        case .englishToTurkish:
            return "tr"
        }
    }

    var displayName: String {
        switch self {
        case .turkishToEnglish:
            return "Türkçe → İngilizce"
        case .englishToTurkish:
            return "İngilizce → Türkçe"
        }
    }
}

enum NativeTranslationMode: String, CaseIterable {
    case quick
    case review

    var displayName: String {
        switch self {
        case .quick:
            return "Hızlı: çevir ve yerine yaz"
        case .review:
            return "İncele: onaydan sonra yerine yaz"
        }
    }
}

struct TranslationShortcutConfiguration: Equatable {
    let keyCode: CGKeyCode
    let keyLabel: String
    let modifierFlagsRawValue: UInt64

    init(keyCode: CGKeyCode, keyLabel: String, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        modifierFlagsRawValue = UInt64(modifiers.rawValue)
    }

    init(keyCode: CGKeyCode, keyLabel: String, modifierFlagsRawValue: UInt64) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifierFlagsRawValue = modifierFlagsRawValue
    }

    static let `default` = TranslationShortcutConfiguration(
        keyCode: 14,
        keyLabel: "E",
        modifiers: [.command, .option]
    )

    var nsModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.RawValue(modifierFlagsRawValue))
    }

    var cgModifiers: CGEventFlags {
        CGEventFlags(rawValue: modifierFlagsRawValue)
    }

    var displayName: String {
        var result = ""
        if nsModifiers.contains(.control) { result += "⌃" }
        if nsModifiers.contains(.option) { result += "⌥" }
        if nsModifiers.contains(.shift) { result += "⇧" }
        if nsModifiers.contains(.command) { result += "⌘" }
        return result + (keyLabel.isEmpty ? "Klavye tuşu" : keyLabel)
    }
}

enum NativeTextTranslationError: LocalizedError {
    case alreadyRunning
    case unsupportedOperatingSystem
    case unsupportedLanguagePair(NativeTranslationDirection)
    case languageModelsNotInstalled(NativeTranslationDirection)
    case emptyText
    case accessibilityRequired
    case noSelectedText
    case targetApplicationChanged
    case selectionChanged
    case translationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Başka bir metin çevirisi devam ediyor."
        case .unsupportedOperatingSystem:
            return "Cihaz üzeri çeviri için macOS 26 veya daha yeni bir sürüm gerekiyor."
        case let .unsupportedLanguagePair(direction):
            return "macOS \(direction.displayName) çeviri çiftini desteklemiyor."
        case let .languageModelsNotInstalled(direction):
            return "\(direction.displayName) için çeviri dilleri yüklü değil. Sistem Ayarları > Genel > Dil ve Bölge > Çeviri Dilleri bölümünden dilleri indir."
        case .emptyText:
            return "Çevrilecek metin bulunamadı."
        case .accessibilityRequired:
            return "Seçili metni değiştirmek için Screenshot Clipboard uygulamasına macOS Accessibility izni gerekiyor."
        case .noSelectedText:
            return "Önce metni seç, sonra çeviri kısayoluna bas."
        case .targetApplicationChanged:
            return "Çeviri sırasında hedef uygulama değişti. Yanlış yere yapıştırılmadı; çeviri panoya kopyalandı."
        case .selectionChanged:
            return "Çeviri sırasında metin seçimi değişti. Yanlış metin değiştirilmedi; çeviri panoya kopyalandı."
        case let .translationFailed(detail):
            return "macOS çevirisi başarısız oldu: \(detail)"
        }
    }
}

final class NativeTextTranslator {
    func translate(
        _ text: String,
        direction: NativeTranslationDirection,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(NativeTextTranslationError.emptyText))
            return
        }

        guard #available(macOS 26.0, *) else {
            completion(.failure(NativeTextTranslationError.unsupportedOperatingSystem))
            return
        }

        Task {
            let result: Result<String, Error>
            do {
                result = .success(try await Self.performTranslation(text, direction: direction))
            } catch let error as NativeTextTranslationError {
                result = .failure(error)
            } catch {
                result = .failure(NativeTextTranslationError.translationFailed(error.localizedDescription))
            }

            await MainActor.run {
                completion(result)
            }
        }
    }

    @available(macOS 26.0, *)
    private static func performTranslation(
        _ text: String,
        direction: NativeTranslationDirection
    ) async throws -> String {
        let sourceLanguage = Locale.Language(identifier: direction.sourceIdentifier)
        let targetLanguage = Locale.Language(identifier: direction.targetIdentifier)
        let availability = LanguageAvailability()

        switch await availability.status(from: sourceLanguage, to: targetLanguage) {
        case .unsupported:
            throw NativeTextTranslationError.unsupportedLanguagePair(direction)
        case .supported:
            throw NativeTextTranslationError.languageModelsNotInstalled(direction)
        case .installed:
            break
        @unknown default:
            throw NativeTextTranslationError.translationFailed("Dil durumu tanınamadı.")
        }

        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        guard await session.isReady else {
            throw NativeTextTranslationError.languageModelsNotInstalled(direction)
        }

        let response = try await session.translate(text)
        let translatedText = response.targetText
        guard !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeTextTranslationError.translationFailed("Boş sonuç döndü.")
        }
        return translatedText
    }
}

struct TextNormalizationResult {
    let text: String
    let corrections: [(original: String, corrected: String)]

    var changed: Bool { !corrections.isEmpty }
}

enum TurkishTextNormalizer {
    static func normalize(_ text: String) -> TextNormalizationResult {
        let checker = NSSpellChecker.shared
        let nsText = text as NSString
        let pattern = #"[\p{L}]+(?:['’][\p{L}]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return TextNormalizationResult(text: text, corrections: [])
        }

        var replacements: [(range: NSRange, original: String, corrected: String)] = []
        let fullRange = NSRange(location: 0, length: nsText.length)
        for match in regex.matches(in: text, range: fullRange) {
            let word = nsText.substring(with: match.range)
            guard isSafeCandidate(word, in: nsText, range: match.range) else { continue }

            let guesses = checker.guesses(
                forWordRange: NSRange(location: 0, length: (word as NSString).length),
                in: word,
                language: "tr-TR",
                inSpellDocumentWithTag: 0
            ) ?? []
            guard let firstGuess = guesses.first,
                  !firstGuess.isEmpty,
                  firstGuess.caseInsensitiveCompare(word) != .orderedSame,
                  editDistance(between: word.lowercased(), and: firstGuess.lowercased()) <= 3
            else { continue }

            let corrected = preserveCapitalization(of: firstGuess, from: word)
            guard corrected != word else { continue }
            replacements.append((match.range, word, corrected))
        }

        var normalized = text
        for replacement in replacements.reversed() {
            normalized = (normalized as NSString).replacingCharacters(
                in: replacement.range,
                with: replacement.corrected
            )
        }

        return TextNormalizationResult(
            text: normalized,
            corrections: replacements.map { (original: $0.original, corrected: $0.corrected) }
        )
    }

    private static func isSafeCandidate(_ word: String, in text: NSString, range: NSRange) -> Bool {
        guard (word as NSString).length >= 3,
              word.rangeOfCharacter(from: .decimalDigits) == nil,
              !word.contains("_")
        else { return false }

        let uppercaseLetters = word.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }
        if uppercaseLetters.count > 1 || (uppercaseLetters.count == 1 && word.first?.isUppercase != true) {
            return false
        }

        let start = range.location
        let end = NSMaxRange(range)
        if start > 0, text.character(at: start - 1) == 46 { return false }
        if end < text.length, text.character(at: end) == 46 { return false }
        return true
    }

    private static func preserveCapitalization(of candidate: String, from original: String) -> String {
        guard original.first?.isUppercase == true else { return candidate }
        return candidate.prefix(1).uppercased() + candidate.dropFirst()
    }

    private static func editDistance(between lhs: String, and rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous[right.count]
    }
}

final class GlobalTranslationShortcut {
    private let configuration: TranslationShortcutConfiguration
    private let allowedCGModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
    private let allowedNSModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private let action: () -> Void

    init(configuration: TranslationShortcutConfiguration, action: @escaping () -> Void) {
        self.configuration = configuration
        self.action = action

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let eventTap {
            eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let eventTapSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        } else {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event)
            }
        }
    }

    deinit {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let shortcut = Unmanaged<GlobalTranslationShortcut>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                if let eventTap = shortcut.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
        } else if type == .keyDown, let userInfo {
            let shortcut = Unmanaged<GlobalTranslationShortcut>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            if shortcut.handle(event) {
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(allowedNSModifiers)
        guard event.keyCode == configuration.keyCode,
              modifiers == configuration.nsModifiers,
              !event.isARepeat
        else { return false }

        DispatchQueue.main.async { [action] in
            action()
        }
        return true
    }

    @discardableResult
    private func handle(_ event: CGEvent) -> Bool {
        let modifiers = event.flags.intersection(allowedCGModifiers)
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(configuration.keyCode),
              modifiers == configuration.cgModifiers
        else { return false }

        DispatchQueue.main.async { [action] in
            action()
        }
        return true
    }
}

struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            representations.forEach { type, data in
                item.setData(data, forType: type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

enum KeyboardEventPoster {
    private static let keyEventSource = CGEventSource(stateID: .hidSystemState)

    static func postCommandKey(_ keyCode: CGKeyCode) {
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

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        keyUp.post(tap: .cghidEventTap)
    }
}

enum AccessibilityTextSelection {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func selectedText() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ) else {
            return nil
        }

        guard let value = copyAttribute(kAXSelectedTextAttribute, from: focusedElement) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }
}
