import AVFoundation

/// 마이크 입력을 16kHz 모노 WAV로 기록한다.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let writer: WavWriter
    private var resampler: Resampler?

    init(writer: WavWriter) {
        self.writer = writer
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CaptureError.noMicrophone("마이크 입력 포맷을 읽을 수 없습니다 (권한 거부 또는 입력 장치 없음)")
        }
        guard let rs = Resampler(inputFormat: format) else {
            throw CaptureError.formatUnsupported("마이크 포맷 변환기를 만들 수 없습니다: \(format)")
        }
        resampler = rs

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let converted = self.resampler?.convert(buffer) else { return }
            converted.withInt16Samples { self.writer.write($0) }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}

enum CaptureError: LocalizedError {
    case noMicrophone(String)
    case formatUnsupported(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone(let m), .formatUnsupported(let m): return m
        case .coreAudio(let m, let status):
            return "\(m) (OSStatus \(status): \(Self.fourCC(status)))"
        }
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let v = UInt32(bitPattern: status)
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(bytes: bytes, encoding: .ascii) ?? "?" : "\(status)"
    }
}
