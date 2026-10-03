import Foundation
@preconcurrency import AVFoundation

@MainActor
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var continuation:
        AsyncThrowingStream<Data, Error>.Continuation?

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws -> AsyncThrowingStream<Data, Error> {
        stop()

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .duckOthers]
        )
        try audio.setActive(true)

        let input = engine.inputNode
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

        // Bound the queue so a slow connection cannot fill memory.
        let (stream, output) =
            AsyncThrowingStream<Data, Error>.makeStream(
                bufferingPolicy: .bufferingOldest(20)
            )
        continuation = output

        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10),
            format: inputFormat
        ) { @Sendable buffer, _ in
            do {
                if let bytes = try Self.convert(
                    buffer, using: converter, to: outputFormat
                ) {
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

        return stream
    }

    func stop() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        continuation?.finish()
        continuation = nil
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

