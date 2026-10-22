import Combine
import CoreGraphics
import Foundation

/// The modifier key held down to dictate. Detected through flagsChanged events.
enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case fn

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .fn: return .maskSecondaryFn
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "⌥ Option direito"
        case .rightCommand: return "⌘ Command direito"
        case .fn: return "fn / 🌐"
        }
    }
}

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    static let all = [
        LanguageOption(code: "pt", label: "Português"),
        LanguageOption(code: "en", label: "English"),
        LanguageOption(code: "auto", label: "Detetar automaticamente"),
    ]
}

struct WhisperModelOption: Identifiable, Hashable {
    let name: String
    let label: String
    var id: String { name }

    static let all = [
        WhisperModelOption(name: "openai_whisper-large-v3-v20240930_turbo_632MB", label: "Large v3 Turbo (632 MB, mais preciso)"),
        WhisperModelOption(name: "openai_whisper-small_216MB", label: "Small (216 MB, mais leve)"),
    ]
}

/// User preferences, persisted in UserDefaults. The Claude API key lives in the Keychain instead.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey {
        didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") }
    }
    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    @Published var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: "whisperModel") }
    }
    @Published var formattingEnabled: Bool {
        didSet { defaults.set(formattingEnabled, forKey: "formattingEnabled") }
    }
    @Published var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: "claudeModel") }
    }
    @Published var meetingModel: String {
        didSet { defaults.set(meetingModel, forKey: "meetingModel") }
    }
    @Published var edgeGlowEnabled: Bool {
        didSet { defaults.set(edgeGlowEnabled, forKey: "edgeGlowEnabled") }
    }
    /// Top corner radius of the built-in display in points; a negative value means automatic.
    @Published var cornerRadius: Double {
        didSet { defaults.set(cornerRadius, forKey: "cornerRadius") }
    }

    private init() {
        hotkey = Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        language = defaults.string(forKey: "language") ?? "pt"
        whisperModel = defaults.string(forKey: "whisperModel") ?? WhisperModelOption.all[0].name
        formattingEnabled = defaults.object(forKey: "formattingEnabled") as? Bool ?? true
        claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-opus-5-5"
        meetingModel = defaults.string(forKey: "meetingModel") ?? "claude-opus-5-5"
        edgeGlowEnabled = defaults.object(forKey: "edgeGlowEnabled") as? Bool ?? true
        cornerRadius = defaults.object(forKey: "cornerRadius") as? Double ?? -1
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DomnexWhisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var models: URL {
        let dir = support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var history: URL { support.appendingPathComponent("history.jsonl") }
}
