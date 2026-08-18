import AVFoundation
import CoreAudio

/// macOS 14.4+ Core Audio Process Tap으로 시스템 출력(Zoom 상대방 목소리 등)을 캡처한다.
///
/// 동작 원리: 전역 탭을 만들고, 그 탭만 담은 **비공개 집합 장치(aggregate device)**를 생성한 뒤
/// 그 장치의 입력 스트림에서 오디오를 읽는다. 사용자에게 들리는 소리는 그대로 유지된다(muteBehavior = unmuted).
final class SystemAudioTap {
    private let writer: WavWriter
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: Resampler?
    private var tapFormat: AVAudioFormat?
    private var running = false

    init(writer: WavWriter) {
        self.writer = writer
    }

    func start() throws {
        let outputDevice = try CA.defaultOutputDevice()
        guard outputDevice != 0 else {
            throw CaptureError.coreAudio("기본 출력 장치를 찾을 수 없습니다", -1)
        }
        let outputUID = try CA.string(outputDevice, kAudioDevicePropertyDeviceUID)

        // 1) 전역 탭 생성. 어떤 프로세스도 제외하지 않는다.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted   // 사용자에게는 소리가 계속 들려야 한다
        description.name = "MeetingScribe System Tap"
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw CaptureError.coreAudio("시스템 오디오 탭 생성 실패 — 시스템 설정 > 개인정보 보호 및 보안 > 마이크 에서 이 도구를 허용했는지 확인하세요", status)
        }

        // 2) 탭의 실제 스트림 포맷을 읽는다 (보통 48kHz Float32 스테레오)
        let asbd = try CA.variableValue(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
        var mutableASBD = asbd
        guard let format = AVAudioFormat(streamDescription: &mutableASBD) else {
            throw CaptureError.formatUnsupported("탭 스트림 포맷을 해석할 수 없습니다")
        }
        tapFormat = format
        resampler = Resampler(inputFormat: format)
        guard resampler != nil else {
            throw CaptureError.formatUnsupported("탭 포맷 변환기를 만들 수 없습니다: \(format)")
        }

        // 3) 탭만 담은 비공개 집합 장치 생성
        let aggregateUID = UUID().uuidString
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingScribe Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // 출력 장치를 서브디바이스로 포함해야 집합 장치에 클럭 소스가 생긴다.
            // 비워두면 초기 버퍼 몇 초 뒤에 IOProc이 무음만 전달한다.
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw CaptureError.coreAudio("집합 장치 생성 실패", status)
        }

        // 4) IOProc 등록. 이 블록은 실시간 오디오 스레드에서 호출된다.
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.tapFormat else { return }
            if Diagnostics.enabled { Diagnostics.dumpOnce(inInputData, format: format) }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             bufferListNoCopy: inInputData,
                                             deallocator: nil) else { return }
            guard let converted = self.resampler?.convert(pcm) else { return }
            converted.withInt16Samples { self.writer.write($0) }
        }
        guard status == noErr, let procID else {
            throw CaptureError.coreAudio("IOProc 등록 실패", status)
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw CaptureError.coreAudio("집합 장치 시작 실패", status)
        }
        running = true
    }

    /// 여러 번 불러도 안전하다. 부분적으로만 초기화된 상태에서도 안전하게 정리한다.
    func stop() {
        if running, let procID {
            AudioDeviceStop(aggregateID, procID)
            running = false
        }
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}


enum Diagnostics {
    static let enabled = ProcessInfo.processInfo.environment["CAPTURE_DEBUG"] != nil
    nonisolated(unsafe) private static var done = false

    static func dumpOnce(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard !done else { return }
        done = true
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var lines = ["--- IOProc 첫 콜백 ---",
                     "탭 포맷: \(format)",
                     "버퍼 개수: \(abl.count)"]
        for (i, buf) in abl.enumerated() {
            let bytes = Int(buf.mDataByteSize)
            var peak: Int32 = 0
            if let d = buf.mData {
                let floats = d.assumingMemoryBound(to: Float32.self)
                let n = bytes / MemoryLayout<Float32>.size
                var mx: Float = 0
                for k in 0..<n { mx = max(mx, abs(floats[k])) }
                peak = Int32(mx * 32767)
            }
            lines.append("  [\(i)] ch=\(buf.mNumberChannels) bytes=\(bytes) peakInt16≈\(peak)")
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
