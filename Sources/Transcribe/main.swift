import AVFoundation
import Foundation
import Speech

// 녹음된 WAV 파일을 macOS 26 온디바이스 음성인식(SpeechAnalyzer)으로 전사한다.
// 클라우드 API 없이 무료로 돌아가며, 나중에 유료 API와 비교할 기준선이 된다.

struct Segment: Codable {
    let start: Double
    let end: Double
    let text: String
    let alternatives: [String]
}

let verbose = ProcessInfo.processInfo.environment["TRANSCRIBE_DEBUG"] != nil
func step(_ s: String) {
    if verbose { FileHandle.standardError.write(Data("  · \(s)\n".utf8)) }
}

func emit(_ line: String) {
    print(line)
    logBuffer += line + "\n"
    if let logPath { try? logBuffer.write(toFile: logPath, atomically: true, encoding: .utf8) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("오류: \(message)\n".utf8))
    logBuffer += "오류: " + message + "\n"
    if let logPath { try? logBuffer.write(toFile: logPath, atomically: true, encoding: .utf8) }
    exit(1)
}

// ── 인자 ────────────────────────────────────────────────────────────────────
var inputPaths: [String] = []
var localeID = "ko-KR"
var jsonOut: String? = nil
var showInfo = false
var doProbe = false
var logPath: String? = nil
var tailSeconds: Double? = nil
var vocabPath: String? = nil
var logBuffer = ""

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--locale", "-l":
        guard let v = args.first else { fail("--locale 뒤에 값이 필요합니다") }
        localeID = v; args.removeFirst()
    case "--json":
        guard let v = args.first else { fail("--json 뒤에 경로가 필요합니다") }
        jsonOut = v; args.removeFirst()
    case "--log":
        guard let v = args.first else { fail("--log 뒤에 경로가 필요합니다") }
        logPath = v; args.removeFirst()
    case "--tail":
        guard let v = args.first, let d = Double(v) else { fail("--tail 뒤에 초 단위 숫자가 필요합니다") }
        tailSeconds = d; args.removeFirst()
    case "--vocab":
        guard let v = args.first else { fail("--vocab 뒤에 경로가 필요합니다") }
        vocabPath = v; args.removeFirst()
    case "--info":
        showInfo = true
    case "--probe":
        doProbe = true
    case "--help", "-h":
        print("""
        사용법: Transcribe <wav 파일...> [옵션]

          -l, --locale <ID>   인식 언어 (기본: ko-KR)
              --json <경로>   결과를 JSON으로도 저장
              --tail <초>     파일 끝에서 이 시간만큼만 전사 (라이브 자막용)
              --vocab <경로>  용어 사전 (한 줄에 하나) — 현재 한국어에선 효과 없음
              --log <경로>    콘솔 출력을 파일로도 저장 (open 실행 시 필요)
              --info          지원/설치 언어와 자산 상태 확인
              --probe         프리셋별 동작 확인
          -h, --help

        macOS 26 온디바이스 음성인식을 사용합니다. 네트워크·API 키가 필요 없습니다.
        """)
        exit(0)
    default:
        inputPaths.append(arg)
    }
}
guard showInfo || doProbe || !inputPaths.isEmpty else { fail("전사할 WAV 파일을 지정하세요. --help 참고") }

// ── 전사 ────────────────────────────────────────────────────────────────────
@available(macOS 26.0, *)
func transcribe(url: URL, locale: Locale, tail: Double?) async throws -> [Segment] {
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
        let available = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        fail("\(locale.identifier)는 지원되지 않습니다. 지원 언어: \(available.prefix(20).joined(separator: ", "))…")
    }

    // ⚠️ 설치 여부와 무관하게 반드시 먼저 예약해야 한다.
    //    빠뜨리면 analyzer.start()가 nilError로 실패한다 — 어떤 메시지도 나오지 않는다.
    _ = try? await AssetInventory.reserve(locale: supported)

    // 시간 정보를 받아야 나중에 화자분리 결과와 맞출 수 있다.
    let transcriber = SpeechTranscriber(locale: supported,
                                        preset: .timeIndexedTranscriptionWithAlternatives)

    // 언어 모델이 없을 때만 내려받는다 (최초 1회, 수백 MB).
    // 이미 설치돼 있는데 설치 요청을 만들면 nilError로 죽으므로 상태를 먼저 본다.
    if await AssetInventory.status(forModules: [transcriber]) != .installed {
        FileHandle.standardError.write(Data("언어 모델 내려받는 중 (\(supported.identifier))…\n".utf8))
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // 용어 사전. 회의에서 반복되는 전문용어·약어·사람 이름을 미리 알려준다.
    let context = AnalysisContext()
    var vocabCount = 0
    if let vocabPath {
        let terms = (try? String(contentsOfFile: vocabPath, encoding: .utf8))?
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        if !terms.isEmpty {
            context.contextualStrings = [.general: terms]
            vocabCount = terms.count
        }
    }

    step("스트림 준비")
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

    // 컨텍스트는 생성자로 넘긴다. 이 초기화가 분석을 곧바로 시작한다.
    step("analyzer 생성 (용어 \(vocabCount)개)")
    let analyzer = SpeechAnalyzer(inputSequence: stream,
                                  modules: [transcriber],
                                  options: nil,
                                  analysisContext: context)

    // 결과 수집은 start() 이후에 시작한다.
    let collector = Task { () -> [Segment] in
        var segments: [Segment] = []
        for try await result in transcriber.results {
            segments.append(Segment(start: result.range.start.seconds,
                                    end: result.range.end.seconds,
                                    text: String(result.text.characters),
                                    alternatives: result.alternatives.map { String($0.characters) }))
        }
        return segments
    }

    // ⚠️ bestAvailableAudioFormat 은 반드시 start() 이후에 부른다.
    //    start() 전에 부르면 start() 가 nilError 로 실패한다.
    step("포맷 조회")
    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        fail("분석기가 요구하는 오디오 포맷을 알 수 없습니다")
    }
    step("분석기 포맷: \(analyzerFormat)")

    step("파일 열기: \(url.path)")
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url) }
    catch { fail("AVAudioFile 열기 실패: \(error)") }
    step("파일 포맷: \(file.processingFormat) / \(file.length) 프레임)")
    guard let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat) else {
        fail("오디오 포맷 변환기를 만들 수 없습니다: \(file.processingFormat) → \(analyzerFormat)")
    }

    let chunkFrames: AVAudioFrameCount = 8192
    let ratio = analyzerFormat.sampleRate / file.processingFormat.sampleRate

    // 라이브 자막용: 파일 끝에서 tail 초 만큼만 읽는다. 녹음이 길어져도 갱신 속도가 일정하다.
    var timeOffset = 0.0
    if let tail {
        let tailFrames = AVAudioFramePosition(tail * file.processingFormat.sampleRate)
        if file.length > tailFrames {
            file.framePosition = file.length - tailFrames
            timeOffset = Double(file.framePosition) / file.processingFormat.sampleRate
        }
    }

    // AVAudioFile.read 는 파일 끝에서 0프레임을 돌려주지 않고 예외를 던진다.
    // 남은 프레임을 직접 계산해서 그만큼만 읽는다.
    while file.framePosition < file.length {
        let remaining = AVAudioFrameCount(min(Int64(chunkFrames), file.length - file.framePosition))
        guard remaining > 0,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining)
        else { break }
        do { try file.read(into: input, frameCount: remaining) }
        catch { fail("파일 읽기 실패: \(error)") }
        if input.frameLength == 0 { break }

        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { break }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return input
        }
        guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else { continue }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    continuation.finish()
    step("finalize")
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    step("결과 수집")
    let collected = try await collector.value
    guard timeOffset > 0 else { return collected }
    return collected.map { Segment(start: $0.start + timeOffset, end: $0.end + timeOffset,
                                   text: $0.text, alternatives: $0.alternatives) }
}

// ── 실행 ────────────────────────────────────────────────────────────────────
@available(macOS 26.0, *)
func info() async {
    emit("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
    let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
    emit("지원 언어 (\(supported.count)): \(supported.joined(separator: ", "))")
    emit("설치된 언어 (\(installed.count)): \(installed.isEmpty ? "없음" : installed.joined(separator: ", "))")

    let target = Locale(identifier: localeID)
    let match = await SpeechTranscriber.supportedLocale(equivalentTo: target)
    print("\n\(localeID) 매칭: \(match?.identifier ?? "없음")")
    guard let match else { return }

    let module = SpeechTranscriber(locale: match, preset: .timeIndexedTranscriptionWithAlternatives)
    let status = await AssetInventory.status(forModules: [module])
    print("자산 상태: \(status)")
    do {
        let reserved = try await AssetInventory.reserve(locale: match)
        print("locale 예약: \(reserved)")
    } catch {
        print("locale 예약 실패: \(error)")
    }
    do {
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            print("설치 요청 생성됨 — 내려받는 중…")
            try await req.downloadAndInstall()
            print("설치 완료")
        } else {
            print("설치 요청 없음 (이미 설치됨)")
        }
    } catch {
        print("설치 실패: \(error)")
    }
}

@available(macOS 26.0, *)
func probe() async {
    let target = Locale(identifier: localeID)
    guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: target) else {
        emit("\(localeID) 미지원"); return
    }
    _ = try? await AssetInventory.reserve(locale: match)

    let presets: [(String, SpeechTranscriber.Preset)] = [
        ("transcription", .transcription),
        ("transcriptionWithAlternatives", .transcriptionWithAlternatives),
        ("timeIndexedTranscriptionWithAlternatives", .timeIndexedTranscriptionWithAlternatives),
        ("progressiveTranscription", .progressiveTranscription),
        ("timeIndexedProgressiveTranscription", .timeIndexedProgressiveTranscription),
    ]
    for (name, preset) in presets {
        let m = SpeechTranscriber(locale: match, preset: preset)
        let a = SpeechAnalyzer(modules: [m])
        let (s, c) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await a.start(inputSequence: s)
            c.finish()
            try await a.finalizeAndFinishThroughEndOfInput()
            emit("  ✅ \(name)")
        } catch {
            c.finish()
            await a.cancelAndFinishNow()
            emit("  ❌ \(name) — \(error)")
        }
    }
}

@available(macOS 26.0, *)
func run() async throws {
    let locale = Locale(identifier: localeID)
    var allResults: [String: [Segment]] = [:]

    for path in inputPaths {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { fail("파일이 없습니다: \(path)") }

        let started = Date()
        let segments = try await transcribe(url: url, locale: locale, tail: tailSeconds)
        let elapsed = Date().timeIntervalSince(started)
        let audioSeconds = segments.last?.end ?? 0

        emit("\n── \(url.lastPathComponent) ──")
        emit(String(format: "   %.1f초 오디오 / %.1f초 소요 (%.1f배속)\n", audioSeconds, elapsed,
                     elapsed > 0 ? audioSeconds / elapsed : 0))
        for s in segments {
            emit(String(format: "  [%6.2f–%6.2f] %@", s.start, s.end, s.text))
        }
        if segments.isEmpty { emit("  (인식된 내용 없음)") }
        allResults[url.lastPathComponent] = segments
    }

    if let jsonOut {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(allResults).write(to: URL(fileURLWithPath: jsonOut))
        emit("\nJSON 저장: \(jsonOut)")
    }
}

if #available(macOS 26.0, *) {
    do {
        if showInfo { await info() } else if doProbe { await probe() } else { try await run() }
    } catch {
        fail("전사 실패: \(error)")
    }
} else {
    fail("온디바이스 음성인식은 macOS 26 이상이 필요합니다")
}
