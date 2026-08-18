import Foundation

/// 16-bit PCM WAV 파일 기록기.
///
/// 헤더의 길이 필드는 기록이 끝나야 알 수 있으므로 0으로 먼저 쓰고 `finalize()`에서 덮어쓴다.
/// 그래서 프로세스가 비정상 종료해도 데이터 자체는 파일에 남는다 — 헤더만 고치면 재생 가능하다.
final class WavWriter {
    private let handle: FileHandle
    private let lock = NSLock()
    private var dataBytes: UInt32 = 0
    private var finalized = false
    private var lastHeaderFlush: UInt32 = 0

    /// 이만큼 쌓일 때마다 헤더의 길이 필드를 갱신한다(약 2초).
    /// 덕분에 녹음 중에도 다른 프로세스가 이 파일을 읽을 수 있고,
    /// 비정상 종료해도 직전까지의 내용이 재생 가능한 상태로 남는다.
    private let headerFlushInterval: UInt32 = 16_000 * 2 * 2

    let url: URL
    let sampleRate: Int
    let channels: Int

    init(url: URL, sampleRate: Int = 16_000, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0))
    }

    /// 오디오 스레드에서 호출된다. 짧게 유지할 것.
    func write(_ samples: UnsafeBufferPointer<Int16>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        let data = Data(bytes: base, count: byteCount)
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        do {
            try handle.write(contentsOf: data)
            dataBytes &+= UInt32(byteCount)
            if dataBytes &- lastHeaderFlush >= headerFlushInterval {
                lastHeaderFlush = dataBytes
                let end = try handle.offset()
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: dataBytes))
                try handle.seek(toOffset: end)
            }
        } catch {
            FileHandle.standardError.write(Data("WAV 쓰기 실패: \(error)\n".utf8))
        }
    }

    /// 헤더의 길이 필드를 확정하고 파일을 닫는다. 여러 번 불러도 안전하다.
    func finalize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: dataBytes))
        try handle.close()
    }

    var durationSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        let frames = Int(dataBytes) / (MemoryLayout<Int16>.size * channels)
        return Double(frames) / Double(sampleRate)
    }

    private static func header(sampleRate: Int, channels: Int, dataBytes: UInt32) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * channels * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(channels * Int(bitsPerSample) / 8)

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(36 &+ dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(dataBytes)
        return d
    }
}
