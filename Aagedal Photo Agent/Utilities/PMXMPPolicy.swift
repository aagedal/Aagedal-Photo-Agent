import AppKit
import Foundation

enum PMXMPCompatibilityMode: String, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case strictPhotoMechanic = "strictPhotoMechanic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .strictPhotoMechanic:
            return "Strict Photo Mechanic"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Use the app's normal XMP behavior."
        case .strictPhotoMechanic:
            return "Use Photo Mechanic-compatible XMP behavior (RAW-oriented basename .xmp sidecars)."
        }
    }
}

enum PMNonRAWXMPSidecarBehavior: String, CaseIterable, Identifiable, Sendable {
    case alwaysAsk = "alwaysAsk"
    case historyOnly = "historyOnly"
    case embeddedWrite = "embeddedWrite"
    case syncRawJpegPair = "syncRawJpegPair"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysAsk:
            return "Always Ask"
        case .historyOnly:
            return "History Only"
        case .embeddedWrite:
            return "Write Embedded"
        case .syncRawJpegPair:
            return "Sync RAW+JPEG Pair"
        }
    }

    var description: String {
        switch self {
        case .alwaysAsk:
            return "Prompt each time when non-RAW files are edited in XMP sidecar mode."
        case .historyOnly:
            return "Save changes to app sidecar history only for non-RAW files."
        case .embeddedWrite:
            return "Write metadata directly into non-RAW files."
        case .syncRawJpegPair:
            return "Write non-RAW metadata embedded and mirror metadata to RAW sidecar when a RAW sibling exists."
        }
    }
}

enum PMNonRAWXMPSidecarChoice: String, CaseIterable, Identifiable, Sendable {
    case historyOnly = "historyOnly"
    case embeddedWrite = "embeddedWrite"
    case syncRawJpegPair = "syncRawJpegPair"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .historyOnly:
            return "History Only"
        case .embeddedWrite:
            return "Write Embedded"
        case .syncRawJpegPair:
            return "Sync RAW+JPEG Pair"
        }
    }
}

struct PMXMPPolicy: Sendable {
    static var mode: PMXMPCompatibilityMode {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.pmXmpCompatibilityMode) ?? PMXMPCompatibilityMode.off.rawValue
        return PMXMPCompatibilityMode(rawValue: raw) ?? .off
    }

    static var nonRawBehavior: PMNonRAWXMPSidecarBehavior {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.pmNonRawXmpBehavior) ?? PMNonRAWXMPSidecarBehavior.alwaysAsk.rawValue
        return PMNonRAWXMPSidecarBehavior(rawValue: raw) ?? .alwaysAsk
    }

    static var rememberedChoice: PMNonRAWXMPSidecarChoice? {
        guard let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.pmNonRawXmpRememberedChoice) else {
            return nil
        }
        return PMNonRAWXMPSidecarChoice(rawValue: raw)
    }

    static func setRememberedChoice(_ choice: PMNonRAWXMPSidecarChoice?) {
        UserDefaults.standard.set(choice?.rawValue, forKey: UserDefaultsKeys.pmNonRawXmpRememberedChoice)
    }

    static func shouldUseXMPReference(for imageURL: URL) -> Bool {
        if mode == .strictPhotoMechanic && !SupportedImageFormats.isRaw(url: imageURL) {
            return false
        }
        return true
    }

    @MainActor
    static func resolveNonRawChoiceWithPromptIfNeeded() -> PMNonRAWXMPSidecarChoice? {
        switch nonRawBehavior {
        case .historyOnly:
            return .historyOnly
        case .embeddedWrite:
            return .embeddedWrite
        case .syncRawJpegPair:
            return .syncRawJpegPair
        case .alwaysAsk:
            return presentPrompt()
        }
    }

    @MainActor
    private static func presentPrompt() -> PMNonRAWXMPSidecarChoice? {
        let remembered = rememberedChoice
        var ordered = PMNonRAWXMPSidecarChoice.allCases
        if let remembered,
           let index = ordered.firstIndex(of: remembered) {
            ordered.remove(at: index)
            ordered.insert(remembered, at: 0)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Non-RAW File in Photo Mechanic-Compatible XMP Mode"
        alert.informativeText = "Choose how to handle this non-RAW file."
        ordered.forEach { choice in
            alert.addButton(withTitle: choice.displayName)
        }
        alert.addButton(withTitle: "Cancel")

        let rememberCheckbox = NSButton(checkboxWithTitle: "Remember this as the preferred choice", target: nil, action: nil)
        alert.accessoryView = rememberCheckbox

        let response = alert.runModal()
        let choiceIndex: Int
        switch response {
        case .alertFirstButtonReturn:
            choiceIndex = 0
        case .alertSecondButtonReturn:
            choiceIndex = 1
        case .alertThirdButtonReturn:
            choiceIndex = 2
        default:
            return nil
        }

        guard choiceIndex < ordered.count else { return nil }
        let selected = ordered[choiceIndex]
        if rememberCheckbox.state == .on {
            setRememberedChoice(selected)
        }
        return selected
    }
}
