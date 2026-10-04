import Foundation
@preconcurrency import AVFoundation

enum AcousticAudioSession {
    static func configureAndActivate() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
        )
        // haptics and the microphone are allowed together (by default iOS fights over it)
        try? audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audio.setActive(true)
    }

    /// Audio setups to try when the microphone delivers pure silence; the first one that
    /// hears anything is remembered and tried first next time.
    enum MicSetup: String, CaseIterable {
        case standard, voiceProcessing, measurement, recordOnly

        static var preferred: MicSetup {
            get { MicSetup(rawValue: UserDefaults.standard.string(forKey: "AcousticMaps.micSetup") ?? "") ?? .standard }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "AcousticMaps.micSetup") }
        }

        /// Try order: the remembered one first, then the rest.
        static var order: [MicSetup] { [preferred] + allCases.filter { $0 != preferred } }
    }

    static func configureForMicrophone(_ setup: MicSetup) throws {
        let audio = AVAudioSession.sharedInstance()
        switch setup {
        case .standard, .voiceProcessing:
            try configureAndActivate()
        case .measurement:  // what the app used when recording first worked (19:37)
            try audio.setCategory(.playAndRecord, mode: .measurement,
                                  options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try? audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try audio.setActive(true)
        case .recordOnly:   // no playback at all while listening
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setActive(true)
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

@MainActor
final class MicrophoneCapture {
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var continuation:
        AsyncThrowingStream<Data, Error>.Continuation?

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(
        onLevel: @escaping @MainActor @Sendable (Double, Double) -> Void
    ) throws -> AsyncThrowingStream<Data, Error> {
        stop()
        // Bound the queue so a slow connection cannot fill memory (100 = 10 s of audio).
        let (stream, output) =
            AsyncThrowingStream<Data, Error>.makeStream(
                bufferingPolicy: .bufferingOldest(100)
            )
        continuation = output
        self.onLevel = onLevel
        setups = AcousticAudioSession.MicSetup.order
        try startEngine(feeding: output, setup: setups.removeFirst())
        return stream
    }

    private var setups: [AcousticAudioSession.MicSetup] = []
    private(set) var setup = AcousticAudioSession.MicSetup.standard

    /// The current setup heard sound: use it first from now on.
    func rememberWorkingSetup() {
        AcousticAudioSession.MicSetup.preferred = setup
    }

    /// The microphone delivered pure silence: rebuild the engine with the next audio
    /// setup, still feeding the same stream. Returns false when every setup was tried.
    func tryNextSetup() throws -> Bool {
        guard let output = continuation, !setups.isEmpty else { return false }
        stopEngine()
        try startEngine(feeding: output, setup: setups.removeFirst())
        return true
    }

    /// Audio session state, for the diagnostics screen.
    var sessionInfo: String {
        let audio = AVAudioSession.sharedInstance()
        return "setup \(setup.rawValue): \(audio.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")) / "
            + "\(audio.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")), "
            + "input \(audio.isInputAvailable ? "available" : "UNAVAILABLE"), "
            + String(format: "gain %.2f, %.0f Hz", audio.inputGain, audio.sampleRate)
            + (voiceProcessingOn ? ", voice processing" : "")
    }
    private var voiceProcessingOn = false

    private var onLevel: (@MainActor @Sendable (Double, Double) -> Void)?

    private func startEngine(
        feeding output: AsyncThrowingStream<Data, Error>.Continuation,
        setup: AcousticAudioSession.MicSetup
    ) throws {
        self.setup = setup
        try AcousticAudioSession.configureForMicrophone(setup)
        engine = AVAudioEngine()

        let input = engine.inputNode
        if setup == .voiceProcessing {
            try? input.setVoiceProcessingEnabled(true)
        }
        voiceProcessingOn = input.isVoiceProcessingEnabled
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(
                  from: inputFormat,
                  to: outputFormat
              ) else {
            throw Self.failure("Microphone format is unavailable.")
        }

        let onLevel = self.onLevel
        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10),
            format: inputFormat
        ) { @Sendable buffer, _ in
            do {
                if let bytes = try Self.convert(
                    buffer, using: converter, to: outputFormat
                ) {
                    let inputPeak = Self.peak(buffer)
                    let pcmPeak = bytes.withUnsafeBytes { raw in
                        raw.bindMemory(to: Int16.self).reduce(0.0) {
                            max($0, abs(Double($1)) / 32_768)
                        }
                    }
                    if let onLevel {
                        Task { @MainActor in
                            onLevel(inputPeak, pcmPeak)
                        }
                    }
                    if case .dropped = output.yield(bytes) {
                        output.finish(
                            throwing: Self.failure("Audio upload is too slow.")
                        )
                    }
                }
            } catch {
                output.finish(throwing: error)
            }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    var inputRoute: String {
        AVAudioSession.sharedInstance().currentRoute.inputs
            .map(\.portName).joined(separator: ", ")
    }

    private nonisolated static func peak(_ buffer: AVAudioPCMBuffer) -> Double {
        var peak = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            let dataChannel = buffer.format.isInterleaved ? 0 : channel
            for frame in 0..<Int(buffer.frameLength) {
                let index = frame * Int(buffer.stride)
                    + (buffer.format.isInterleaved ? channel : 0)
                let value: Double
                if let samples = buffer.floatChannelData {
                    value = Double(samples[dataChannel][index])
                } else if let samples = buffer.int16ChannelData {
                    value = Double(samples[dataChannel][index]) / 32_768
                } else if let samples = buffer.int32ChannelData {
                    value = Double(samples[dataChannel][index]) / 2_147_483_648
                } else {
                    continue
                }
                peak = max(peak, abs(value))
            }
        }
        return peak
    }

    func stop() {
        stopEngine()
        continuation?.finish()
        continuation = nil
        onLevel = nil
        // The session stays active: switching it off and on between speech and
        // the microphone is what left the input stale (silent) before.
    }

    private func stopEngine() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // audio conversion runs on the microphone callback's thread
    private nonisolated static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) throws -> Data? {
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength)
                 * format.sampleRate / input.format.sampleRate) + 32
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: capacity
        ) else {
            throw failure("Could not allocate an audio buffer.")
        }

        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) {
            _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }

        if let error { throw error }
        guard result != .error else {
            throw failure("Audio conversion failed.")
        }
        guard output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else {
            return nil
        }

        // iPhones use little-endian samples. No WAV header is added.
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(
            domain: "AcousticMaps.Microphone",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
