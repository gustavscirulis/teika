import AVFoundation

/// Turns a recording that arrived from the watch into the sample format FluidAudio wants.
///
/// The watch records AAC at 16 kHz mono — about 6 KB of audio per second, against
/// 32 KB/s for the equivalent 16-bit PCM. That difference is the whole reason the
/// round trip feels immediate rather than like a file sync, and decoding it back is
/// this file's only job.
enum ClipDecoder {
    enum DecodeError: Error {
        case unreadable
        case unsupportedFormat
    }

    /// The format `SpeechTranscriber` feeds `AsrManager`, matching the target its own
    /// microphone tap converts to.
    private static var target: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    static func decodeMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames)
        else { throw DecodeError.unreadable }
        try file.read(into: input)

        guard let target else { throw DecodeError.unsupportedFormat }

        // The common case: the watch recorded at exactly this rate, so decoding an AAC
        // file already lands on the target format and there is nothing to resample.
        if source.sampleRate == target.sampleRate,
           source.channelCount == 1,
           source.commonFormat == .pcmFormatFloat32 {
            return samples(from: input)
        }

        guard let converter = AVAudioConverter(from: source, to: target)
        else { throw DecodeError.unsupportedFormat }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { throw DecodeError.unsupportedFormat }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }

        return samples(from: output)
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
