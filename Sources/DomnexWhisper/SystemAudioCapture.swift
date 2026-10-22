import AVFoundation
import CoreAudio
import Foundation

enum SystemAudioError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status): return "Não foi possível \(step) (erro \(status))."
        case .unsupportedFormat: return "Formato de áudio do sistema não suportado."
        }
    }
}

/// Captures what the Mac is playing (the other people in a call) with a Core Audio process tap
/// (macOS 14.2+). Needs only the "system audio recording" permission, not screen recording.
/// Audio is delivered as 16 kHz mono and never stored.
final class SystemAudioCapture {
    /// Called on a background queue with each converted chunk.
    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "com.luispinto.domnexwhisper.system-audio")

    func start() throws {
        // A global stereo tap of every process; this app plays no audio of its own.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "DomnexWhisper"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "criar a captura do som do sistema")

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription), "ler o formato do som do sistema")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw SystemAudioError.unsupportedFormat
        }
        inputFormat = format
        converter = AVAudioConverter(from: format, to: AudioRecorder.whisperFormat)

        // The tap is read through a private aggregate device built around the current output device.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DomnexWhisper",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "preparar o dispositivo de captura")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.process(inputData)
        }, "ligar a captura")
        // The first start shows the macOS permission prompt for recording system audio.
        try check(AudioDeviceStart(aggregateID, procID), "começar a captura")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        converter = nil
    }

    private func process(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: bufferList, deallocator: nil),
              let chunk = AudioRecorder.convert(buffer, with: converter) else { return }
        onSamples?(chunk)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            stop()
            throw SystemAudioError.coreAudio(step, status)
        }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw SystemAudioError.coreAudio("encontrar a saída de som", status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw SystemAudioError.coreAudio("identificar a saída de som", status) }
        return uid.takeRetainedValue() as String
    }
}
