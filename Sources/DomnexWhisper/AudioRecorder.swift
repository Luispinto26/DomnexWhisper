import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "Nenhum microfone disponível."
        }
    }
}

/// Captures microphone audio as 16 kHz mono Float32 samples, the format Whisper expects.
/// Audio only ever lives in memory.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Called on the main queue with the RMS level of each captured chunk.
    var onLevel: ((Float) -> Void)?
    /// When set, audio is handed over as it arrives (on the audio thread) instead of being
    /// accumulated until `stop()`. Used for long recordings such as meetings.
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        converter = AVAudioConverter(from: inputFormat, to: Self.whisperFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns everything recorded since `start()` (empty when streaming).
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        return lock.withLock { samples }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let chunk = Self.convert(buffer, with: converter) else { return }
        if let onSamples {
            onSamples(chunk)
        } else {
            lock.withLock { samples.append(contentsOf: chunk) }
        }
        let level = Self.rms(chunk)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// Resamples one buffer to 16 kHz mono. The converter keeps its state between calls,
    /// so consecutive buffers join without clicks.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = whisperFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}
