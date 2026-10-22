import Combine
import Foundation

/// Collects 16 kHz audio from one source and cuts it into ~30 s chunks at the quietest moment,
/// so words are not split between chunks. Thread-safe: audio arrives on capture threads.
final class ChunkBuffer {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var handedOut = 0
    private var heard = false

    private static let rate = Int(AudioRecorder.sampleRate)
    private static let minimumLength = 25 * rate
    private static let maximumLength = 35 * rate

    /// Whether anything louder than silence has arrived yet.
    var heardSound: Bool { lock.withLock { heard } }

    func append(_ chunk: [Float]) {
        let loud = AudioRecorder.rms(chunk) > 0.003
        lock.withLock {
            samples.append(contentsOf: chunk)
            if loud { heard = true }
        }
    }

    /// The next chunk and its start time in seconds since recording began, or nil when there isn't
    /// enough audio yet. `final` hands out whatever is left.
    func next(final: Bool) -> (start: TimeInterval, samples: [Float])? {
        lock.withLock {
            let cut: Int
            if final {
                guard samples.count > Self.rate / 2 else { return nil }
                cut = samples.count
            } else {
                guard samples.count >= Self.maximumLength else { return nil }
                cut = quietestPoint()
            }
            let chunk = Array(samples[..<cut])
            samples.removeFirst(cut)
            let start = Double(handedOut) / Double(Self.rate)
            handedOut += cut
            return (start, chunk)
        }
    }

    /// Middle of the quietest 100 ms window between 25 and 35 seconds.
    private func quietestPoint() -> Int {
        let window = Self.rate / 10
        var best = Self.maximumLength
        var lowest = Float.greatestFiniteMagnitude
        var start = Self.minimumLength
        while start + window <= Self.maximumLength {
            var energy: Float = 0
            for index in start..<(start + window) { energy += samples[index] * samples[index] }
            if energy < lowest {
                lowest = energy
                best = start + window / 2
            }
            start += window
        }
        return best
    }
}

/// One recorded meeting: the microphone ("Eu") and the Mac's audio ("Outros") are transcribed
/// locally in chunks while the meeting runs. Audio is dropped as soon as each chunk is transcribed.
@MainActor
final class MeetingSession: ObservableObject {
    enum Speaker: String {
        case me = "Eu"
        case others = "Outros"
    }

    struct Line: Identifiable {
        let id = UUID()
        let start: TimeInterval
        let speaker: Speaker
        let text: String
    }

    enum Phase: Equatable {
        case recording
        case transcribing
        case writingNotes
        case saved(URL)
        case failed(String)
        case cancelled
    }

    @Published var title: String
    @Published private(set) var lines: [Line] = []
    @Published private(set) var phase: Phase = .recording
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var heardSystemAudio = false
    @Published private(set) var notesWarning: String?

    let startedAt = Date()
    private let transcriber: Transcriber
    private let language: String
    private let microphone = AudioRecorder()
    private let systemAudio = SystemAudioCapture()
    private let micChunks = ChunkBuffer()
    private let systemChunks = ChunkBuffer()
    private var queue: Task<Void, Never>?
    private var ticker: Timer?

    var isActive: Bool {
        switch phase {
        case .recording, .transcribing, .writingNotes: return true
        default: return false
        }
    }

    init(transcriber: Transcriber, language: String) {
        self.transcriber = transcriber
        self.language = language
        let when = startedAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "pt_PT")))
        title = "Reunião de \(when)"
    }

    func start() throws {
        let micChunks = micChunks
        let systemChunks = systemChunks
        microphone.onSamples = { micChunks.append($0) }
        systemAudio.onSamples = { systemChunks.append($0) }
        try microphone.start()
        do {
            try systemAudio.start()
        } catch {
            _ = microphone.stop()
            throw error
        }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes keep it ticking while a menu is open.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Stops recording, transcribes what is left, asks Claude for notes and saves the Markdown file.
    func finish(apiKey: String?, model: String) async {
        guard phase == .recording else { return }
        stopCapture()
        phase = .transcribing
        drainChunks(final: true)
        await queue?.value

        guard !lines.isEmpty else {
            phase = .failed("Não foi transcrito nada. Confirma as permissões do microfone e do áudio do sistema.")
            return
        }
        phase = .writingNotes
        var notes: String?
        if let apiKey {
            do {
                notes = try await MeetingNotes.summarize(lines: lines, title: title, apiKey: apiKey, model: model)
            } catch {
                notesWarning = "O Claude não conseguiu escrever as notas (\(error.localizedDescription)). A nota tem só a transcrição."
            }
        } else {
            notesWarning = "Sem chave da API do Claude: a nota tem só a transcrição."
        }
        do {
            let url = try MeetingNotes.save(
                title: title,
                startedAt: startedAt,
                duration: elapsed,
                notes: notes,
                warning: notesWarning,
                lines: lines
            )
            phase = .saved(url)
        } catch {
            phase = .failed("Não foi possível guardar a nota: \(error.localizedDescription)")
        }
    }

    /// Stops and throws everything away; nothing is saved.
    func cancel() {
        stopCapture()
        queue?.cancel()
        phase = .cancelled
    }

    private func stopCapture() {
        ticker?.invalidate()
        ticker = nil
        _ = microphone.stop()
        systemAudio.stop()
    }

    private func tick() {
        guard phase == .recording else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if !heardSystemAudio && systemChunks.heardSound { heardSystemAudio = true }
        drainChunks(final: false)
    }

    private func drainChunks(final: Bool) {
        for (buffer, speaker) in [(micChunks, Speaker.me), (systemChunks, Speaker.others)] {
            while let chunk = buffer.next(final: false) { enqueue(chunk, speaker: speaker) }
            if final, let rest = buffer.next(final: true) { enqueue(rest, speaker: speaker) }
        }
    }

    /// Chunks are transcribed one at a time, in order, so the Mac is never asked to do two at once.
    private func enqueue(_ chunk: (start: TimeInterval, samples: [Float]), speaker: Speaker) {
        // Silent chunks are skipped: it saves work, and Whisper invents text for silence.
        guard AudioRecorder.rms(chunk.samples) > 0.004 else { return }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.transcribe(chunk, speaker: speaker)
        }
    }

    private func transcribe(_ chunk: (start: TimeInterval, samples: [Float]), speaker: Speaker) async {
        guard let text = try? await transcriber.transcribe(chunk.samples, language: language),
              !text.isEmpty else { return }
        let line = Line(start: chunk.start, speaker: speaker, text: text)
        let index = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
        lines.insert(line, at: index)
    }
}
