import AVFoundation

/// 임의 포맷의 오디오를 ASR이 요구하는 16kHz·모노·Int16으로 변환한다.
///
/// 시스템 오디오는 보통 48kHz 스테레오 Float32로 들어오고 마이크는 기기마다 다르다.
/// 두 트랙 모두 이 클래스를 거쳐 같은 포맷이 된다.
final class Resampler {
    static let targetSampleRate = 16_000.0

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: Self.targetSampleRate,
                                      channels: 1,
                                      interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        // 다운믹스·다운샘플이므로 품질보다 지연이 중요하다.
        conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.converter = conv
        self.outputFormat = out
        self.ratio = Self.targetSampleRate / inputFormat.sampleRate
    }

    /// 변환 실패 시 nil을 반환한다. 호출자는 이 경우에도 녹음을 중단하지 않는다.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 64)
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        default:
            if let error { FileHandle.standardError.write(Data("리샘플 실패: \(error)\n".utf8)) }
            return nil
        }
    }
}

extension AVAudioPCMBuffer {
    /// Int16 인터리브 버퍼의 샘플을 클로저에 넘긴다.
    func withInt16Samples<R>(_ body: (UnsafeBufferPointer<Int16>) -> R) -> R? {
        guard let ptr = int16ChannelData?[0] else { return nil }
        let count = Int(frameLength) * Int(format.channelCount)
        return body(UnsafeBufferPointer(start: ptr, count: count))
    }
}
