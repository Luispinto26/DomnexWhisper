import Foundation
import WhisperKit

enum TranscriberError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "O modelo de transcrição ainda não está carregado."
        }
    }
}

/// Local speech-to-text with WhisperKit (Core ML). Audio never leaves the Mac.
final class Transcriber {
    private var whisper: WhisperKit?
    private(set) var loadedModel: String?

    var isReady: Bool { whisper != nil }

    /// Downloads the model on first use (to Application Support/DomnexWhisper/Models), then loads it.
    /// The first load also lets Core ML specialise the model for this chip, which can take a few minutes.
    func load(model: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        whisper = nil
        loadedModel = nil
        if let local = completedModelFolder(model) {
            do {
                try await loadWhisper(model: model, folder: local)
                return
            } catch {
                // A damaged local copy: forget it and download again below.
                try? FileManager.default.removeItem(at: local.appendingPathComponent(Self.completeMarker))
            }
        }
        // Resumes a partial download; files that are already complete are skipped.
        let folder = try await WhisperKit.download(
            variant: model,
            downloadBase: AppPaths.models,
            progressCallback: { progress in onProgress(progress.fractionCompleted) }
        )
        FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.completeMarker).path, contents: nil)
        try await loadWhisper(model: model, folder: folder)
    }

    private func loadWhisper(model: String, folder: URL) async throws {
        let config = WhisperKitConfig(
            model: model,
            downloadBase: AppPaths.models,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        whisper = try await WhisperKit(config)
        loadedModel = model
    }

    /// `language` is an ISO code such as "pt", or "auto" to let Whisper detect it.
    func transcribe(_ samples: [Float], language: String) async throws -> String {
        guard let whisper else { throw TranscriberError.notLoaded }
        let detect = language == "auto"
        let options = DecodingOptions(
            language: detect ? nil : language,
            detectLanguage: detect,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isKnownHallucination(text) ? "" : text
    }

    /// Transcribes an audio file; used by the `--test-transcribe` command-line check.
    func transcribe(fileAt path: String, language: String) async throws -> String {
        guard let whisper else { throw TranscriberError.notLoaded }
        let options = DecodingOptions(language: language == "auto" ? nil : language, skipSpecialTokens: true, withoutTimestamps: true)
        let results = await whisper.transcribe(audioPaths: [path], decodeOptions: options)
        return (results.first ?? nil)?.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Written only after `WhisperKit.download` returns, so an interrupted download is never mistaken for a complete one.
    private static let completeMarker = ".download-complete"

    private func completedModelFolder(_ model: String) -> URL? {
        let folder = AppPaths.models
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
        let marker = folder.appendingPathComponent(Self.completeMarker)
        return FileManager.default.fileExists(atPath: marker.path) ? folder : nil
    }

    /// Whisper invents subtitle credits when it hears silence.
    private static func isKnownHallucination(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("amara.org") || lowered.contains("legendas pela comunidade")
    }
}
