import AVFoundation
import Foundation

/// 번들 안의 CLI 도구와 LLM을 순서대로 호출해 회의록을 만든다.
///
/// GUI가 자식 프로세스를 띄우면 TCC 권한 주체가 이 앱이 되므로,
/// 마이크·시스템 오디오 권한이 앱 이름으로 한 번만 승인되면 된다.
enum Pipeline {

    enum Mode: String, CaseIterable, Identifiable {
        case meeting, lecture
        var id: String { rawValue }
        var label: String { self == .meeting ? "회의" : "강의" }
        var outputName: String { self == .meeting ? "회의록.md" : "강의기록.md" }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message
        }
    }

    // MARK: 번들 리소스

    static func resource(_ path: String) throws -> URL {
        guard let base = Bundle.main.resourceURL else { throw Failure(message: "앱 번들이 손상되었습니다") }
        let url = base.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "앱 구성 파일을 찾을 수 없습니다: \(path)")
        }
        return url
    }

    /// `claude` CLI를 찾는다. GUI 앱은 셸 PATH를 물려받지 못해서 직접 뒤져야 한다.
    static func findClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: 프로세스 실행

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], stdin: String? = nil,
                    timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if stdin != nil {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin!.utf8))
            inPipe.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }

        // 제한 시간을 넘기면 강제 종료한다. 자식이 멈춰도 앱은 계속 돈다.
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
            watchdog = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }

        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()

        guard process.terminationStatus == 0 else {
            let detail = String(data: err, encoding: .utf8) ?? ""
            throw Failure(message: "\(executable.lastPathComponent) 실패: \(detail.prefix(300))")
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    // MARK: 전사

    struct Segment: Codable {
        let start: Double
        let end: Double
        let text: String
    }

    static func transcribe(directory: URL) throws -> String {
        let tool = try resource("bin/Transcribe")
        let wavs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["wav", "m4a"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !wavs.isEmpty else { throw Failure(message: "녹음 파일이 없습니다") }

        var rows: [(Double, String, String)] = []
        for wav in wavs {
            let json = wav.deletingPathExtension().appendingPathExtension("json")
            try run(tool, [wav.path, "--json", json.path])
            let decoded = try JSONDecoder().decode([String: [Segment]].self, from: Data(contentsOf: json))
            let speaker = wav.deletingPathExtension().lastPathComponent == "mic" ? "나" : "상대"
            for segs in decoded.values {
                for s in segs where !s.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append((s.start, speaker, s.text.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        rows.sort { $0.0 < $1.0 }

        var lines: [String] = []
        var lastSpeaker: String? = nil
        for (start, speaker, text) in rows {
            let stamp = String(format: "[%02d:%02d]", Int(start) / 60, Int(start) % 60)
            if speaker != lastSpeaker {
                lines.append("\n**\(speaker)** \(stamp) \(text)")
                lastSpeaker = speaker
            } else {
                lines.append("\(stamp) \(text)")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 라이브 자막: 파일 끝에서 `tail`초만 전사한다.
    /// 짧게 끊어 넣으면 인식 정확도가 오히려 높고, 녹음이 길어져도 갱신 속도가 일정하다.
    static func liveTail(directory: URL, seconds: Double) throws -> [String] {
        let tool = try resource("bin/Transcribe")
        let mic = directory.appendingPathComponent("mic.wav")
        let sys = directory.appendingPathComponent("system.wav")

        var rows: [(Double, String, String)] = []
        for (wav, speaker) in [(mic, "나"), (sys, "상대")] {
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            let json = directory.appendingPathComponent("live-\(speaker).json")
            guard (try? run(tool, [wav.path, "--tail", String(Int(seconds)), "--json", json.path],
                            timeout: 45)) != nil,
                  let data = try? Data(contentsOf: json),
                  let decoded = try? JSONDecoder().decode([String: [Segment]].self, from: data)
            else { continue }
            for segs in decoded.values {
                for s in segs {
                    let text = s.text.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { rows.append((s.start, speaker, text)) }
                }
            }
        }
        rows.sort { $0.0 < $1.0 }
        return rows.map { start, speaker, text in
            String(format: "%02d:%02d  %@  %@", Int(start) / 60, Int(start) % 60, speaker, text)
        }
    }

    /// 녹음이 끝나면 WAV 를 AAC(.m4a)로 줄이고 원본을 지운다.
    ///
    /// 16kHz 모노 PCM 은 시간당 115MB 다. 32kbps AAC 로 바꾸면 약 14MB — 8분의 1이다.
    /// 녹음 중에는 WAV 를 유지해야 라이브 자막이 파일을 읽을 수 있으므로, 끝난 뒤에 변환한다.
    @discardableResult
    static func compress(directory: URL) -> (before: Int64, after: Int64) {
        var before: Int64 = 0, after: Int64 = 0
        let wavs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []

        for wav in wavs {
            let size = ((try? FileManager.default.attributesOfItem(atPath: wav.path))?[.size] as? Int64) ?? 0
            before += size
            let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
            do {
                let input = try AVAudioFile(forReading: wav)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000,
                ]
                let output = try AVAudioFile(forWriting: m4a, settings: settings)
                let chunk: AVAudioFrameCount = 8192
                while input.framePosition < input.length {
                    let remaining = AVAudioFrameCount(min(Int64(chunk), input.length - input.framePosition))
                    guard remaining > 0,
                          let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: remaining)
                    else { break }
                    try input.read(into: buffer, frameCount: remaining)
                    if buffer.frameLength == 0 { break }
                    try output.write(from: buffer)
                }
                let newSize = ((try? FileManager.default.attributesOfItem(atPath: m4a.path))?[.size] as? Int64) ?? 0
                after += newSize
                try FileManager.default.removeItem(at: wav)          // 변환 성공 후에만 지운다
            } catch {
                after += size                                        // 실패하면 WAV 를 그대로 남긴다
            }
        }
        // 라이브 자막용 임시 JSON 정리
        for f in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if f.lastPathComponent.hasPrefix("live-") { try? FileManager.default.removeItem(at: f) }
        }
        return (before, after)
    }

    // MARK: 문서 생성

    static func summarize(transcript: String, mode: Mode, model: String) throws -> String {
        guard let claude = findClaude() else {
            throw Failure(message: "Claude Code CLI를 찾을 수 없습니다.\n터미널에서 `claude` 명령이 동작하는지 확인해 주세요.")
        }
        let template = try String(contentsOf: resource("templates/\(mode.rawValue).md"), encoding: .utf8)
        let terms = (try? String(contentsOf: resource("templates/terms.txt"), encoding: .utf8)) ?? ""
        let prompt = template
            .replacingOccurrences(of: "{{TERMS}}", with: terms.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "{{TRANSCRIPT}}", with: transcript)
        return try run(claude, ["--print", "--model", model], stdin: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
