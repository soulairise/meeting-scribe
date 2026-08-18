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

    // MARK: 화자분리

    struct SpeakerSegment: Codable {
        let speaker: Int
        let start: Double
        let end: Double
    }

    /// NVIDIA Sortformer 로 화자를 나눈다. 음향만 보므로 언어와 무관하다.
    /// 실패하면 빈 배열을 돌려주고, 호출자는 트랙 이름(나/상대)으로 물러선다.
    static func diarize(wav: URL, timeout: TimeInterval = 60) -> [SpeakerSegment] {
        guard let tool = try? resource("bin/Diarize") else { return [] }
        let json = wav.deletingPathExtension().appendingPathExtension("diar.json")
        guard (try? run(tool, [wav.path, "--quiet", "--json", json.path], timeout: timeout)) != nil,
              let data = try? Data(contentsOf: json),
              let segments = try? JSONDecoder().decode([SpeakerSegment].self, from: data)
        else { return [] }
        return segments
    }

    /// 라이브용: 파일 끝 구간만 잘라 화자분리한다. 시간축은 원본 기준으로 되돌린다.
    static func diarizeTail(wav: URL, seconds: Double, workDirectory: URL) -> [SpeakerSegment] {
        guard let converter = try? resource("bin/Transcribe") else { return [] }
        _ = converter                                   // 존재 확인용
        let clip = workDirectory.appendingPathComponent("live-clip-\(wav.deletingPathExtension().lastPathComponent).wav")
        guard let offset = writeTail(of: wav, seconds: seconds, to: clip) else { return [] }
        let segments = diarize(wav: clip, timeout: 30)
        try? FileManager.default.removeItem(at: clip)
        return segments.map { SpeakerSegment(speaker: $0.speaker,
                                             start: $0.start + offset,
                                             end: $0.end + offset) }
    }

    /// WAV 끝에서 `seconds` 만큼을 새 파일로 쓰고, 잘라낸 시작 지점(초)을 돌려준다.
    private static func writeTail(of source: URL, seconds: Double, to destination: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: source), file.length > 0 else { return nil }
        let rate = file.processingFormat.sampleRate
        let wanted = AVAudioFramePosition(seconds * rate)
        let start = max(0, file.length - wanted)
        let count = AVAudioFrameCount(file.length - start)
        guard count > 0 else { return nil }

        file.framePosition = start
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              (try? file.read(into: buffer, frameCount: count)) != nil,
              buffer.frameLength > 0,
              let out = try? AVAudioFile(forWriting: destination,
                                         settings: file.fileFormat.settings),
              (try? out.write(from: buffer)) != nil
        else { return nil }
        return Double(start) / rate
    }

    /// 전사 구간에 가장 많이 겹치는 화자를 붙인다. 겹치는 화자가 없으면 nil.
    static func speaker(for start: Double, _ end: Double, in diar: [SpeakerSegment]) -> Int? {
        var best: (speaker: Int, overlap: Double)? = nil
        for d in diar {
            let overlap = min(end, d.end) - max(start, d.start)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (d.speaker, overlap) }
        }
        return best?.speaker
    }

    /// 화자 번호를 화자 A, B, C … 로 바꾼다. 처음 등장한 순서대로 붙인다.
    ///
    /// "누가 나인지"는 판단하지 않는다. 온라인 강의처럼 상대 목소리가 스피커로 나오면
    /// 마이크 트랙에서 상대가 더 많이 말하게 되어, 발화량으로 본인을 특정하면 틀린다.
    /// 이름은 LLM 이 대화 속 호칭을 보고 붙인다.
    struct SpeakerNamer {
        private var names: [String: String] = [:]      // "track#index" -> 표시 이름
        private var next = 0

        mutating func name(track: String, speaker: Int?, fallback: String) -> String {
            guard let speaker else { return fallback }
            let key = "\(track)#\(speaker)"
            if let existing = names[key] { return existing }
            let label = "화자 " + String(UnicodeScalar(65 + min(next, 25))!)
            next += 1
            names[key] = label
            return label
        }
    }

    // MARK: 문단 묶기

    struct Paragraph {
        let start: Double
        let speaker: String
        var text: String
    }

    /// 같은 사람이 이어서 말한 조각들을 한 문단으로 합친다.
    ///
    /// 음성인식은 짧게 끊어진 조각을 쏟아내는데, 그대로 한 줄씩 보여주면 읽기 어렵다.
    /// 화자가 바뀌거나, 말이 한동안 끊기거나, 문단이 너무 길어지면 새 문단을 시작한다.
    static func paragraphs(_ rows: [(start: Double, end: Double, speaker: String, text: String)],
                           gapSeconds: Double = 3.0,
                           maxCharacters: Int = 220) -> [Paragraph] {
        var result: [Paragraph] = []
        var lastEnd = -Double.infinity

        for row in rows {
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let sameSpeaker = result.last?.speaker == row.speaker
            let continuous = row.start - lastEnd <= gapSeconds
            let hasRoom = (result.last?.text.count ?? .max) < maxCharacters

            if sameSpeaker, continuous, hasRoom, !result.isEmpty {
                result[result.count - 1].text += glue(result[result.count - 1].text, text)
            } else {
                result.append(Paragraph(start: row.start, speaker: row.speaker, text: text))
            }
            lastEnd = row.end
        }
        return result
    }

    /// 조각을 이을 때 어색한 띄어쓰기를 피한다.
    private static func glue(_ previous: String, _ next: String) -> String {
        if previous.hasSuffix(" ") || next.hasPrefix(" ") { return next }
        if let last = previous.last, ".!?…".contains(last) { return " " + next }
        return " " + next
    }

    static func timestamp(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
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

        // 마이크 트랙을 먼저 처리해야 "나" 를 정할 수 있다.
        let ordered = wavs.sorted { a, _ in a.deletingPathExtension().lastPathComponent == "mic" }
        var diarizations: [String: [SpeakerSegment]] = [:]
        for wav in ordered {
            diarizations[wav.deletingPathExtension().lastPathComponent] = diarize(wav: wav)
        }
        var namer = SpeakerNamer()

        var rows: [(start: Double, end: Double, speaker: String, text: String)] = []
        for wav in ordered {
            let track = wav.deletingPathExtension().lastPathComponent
            let json = wav.deletingPathExtension().appendingPathExtension("json")
            try run(tool, [wav.path, "--json", json.path])
            let decoded = try JSONDecoder().decode([String: [Segment]].self, from: Data(contentsOf: json))
            let diar = diarizations[track] ?? []
            let fallback = track == "mic" ? "나" : "상대"
            for segs in decoded.values {
                for s in segs where !s.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    let who = namer.name(track: track,
                                         speaker: speaker(for: s.start, s.end, in: diar),
                                         fallback: fallback)
                    rows.append((s.start, s.end, who, s.text.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        rows.sort { $0.start < $1.start }
        return paragraphs(rows)
            .map { "**\($0.speaker)** [\(timestamp($0.start))]\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// 라이브 자막: 파일 끝에서 `tail`초만 전사한다.
    /// 짧게 끊어 넣으면 인식 정확도가 오히려 높고, 녹음이 길어져도 갱신 속도가 일정하다.
    static func liveTail(directory: URL, seconds: Double) throws -> [String] {
        let tool = try resource("bin/Transcribe")
        let mic = directory.appendingPathComponent("mic.wav")
        let sys = directory.appendingPathComponent("system.wav")

        // 최근 구간만 화자분리한다. 66초 오디오에 1.2초쯤 걸려 실시간에 무리가 없다.
        var diarizations: [String: [SpeakerSegment]] = [:]
        for (wav, track) in [(mic, "mic"), (sys, "system")] where FileManager.default.fileExists(atPath: wav.path) {
            diarizations[track] = diarizeTail(wav: wav, seconds: seconds, workDirectory: directory)
        }
        var namer = SpeakerNamer()

        var rows: [(start: Double, end: Double, speaker: String, text: String)] = []
        for (wav, track, fallback) in [(mic, "mic", "나"), (sys, "system", "상대")] {
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            let json = directory.appendingPathComponent("live-\(track).json")
            guard (try? run(tool, [wav.path, "--tail", String(Int(seconds)), "--json", json.path],
                            timeout: 45)) != nil,
                  let data = try? Data(contentsOf: json),
                  let decoded = try? JSONDecoder().decode([String: [Segment]].self, from: data)
            else { continue }
            let diar = diarizations[track] ?? []
            for segs in decoded.values {
                for s in segs {
                    let text = s.text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    let who = namer.name(track: track,
                                         speaker: speaker(for: s.start, s.end, in: diar),
                                         fallback: fallback)
                    rows.append((s.start, s.end, who, text))
                }
            }
        }
        rows.sort { $0.start < $1.start }
        return paragraphs(rows).map { "\(timestamp($0.start))  \($0.speaker)   \($0.text)" }
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
