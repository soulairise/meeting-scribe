import CoreML
import FluidAudio
import Foundation

// WAV 파일의 화자를 분리해 JSON 으로 내보낸다.
//
// NVIDIA Sortformer(CoreML)를 쓴다. 음향 특징만 보므로 언어와 무관하다 — 한국어에 그대로 적용된다.
// 최초 1회 모델을 내려받아 ~/.cache/fluidaudio 에 캐시한다.

struct SpeakerSegment: Codable {
    let speaker: Int
    let start: Double
    let end: Double
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("오류: \(message)\n".utf8))
    exit(1)
}

var inputPath: String? = nil
var jsonOut: String? = nil
var quiet = false
var warmup = false

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--json":
        guard let v = args.first else { fail("--json 뒤에 경로가 필요합니다") }
        jsonOut = v; args.removeFirst()
    case "--warmup":
        warmup = true
    case "--quiet", "-q":
        quiet = true
    case "--help", "-h":
        print("""
        사용법: Diarize <wav 파일> [--json <경로>] [--quiet]

        NVIDIA Sortformer 로 화자를 분리해 구간별 화자 번호를 출력합니다.
        최초 1회 CoreML 모델을 내려받습니다 (~/.cache/fluidaudio).
        """)
        exit(0)
    default:
        inputPath = arg
    }
}
let diarizer = OfflineSortformerDiarizer(config: .offlineV2_1)
try await diarizer.initializeFromHuggingFace()

// 모델만 내려받고 끝낸다. 앱이 시작할 때 미리 불러 첫 녹음이 매끄럽게 한다.
if warmup {
    if !quiet { print("화자분리 모델 준비 완료") }
    exit(0)
}

guard let inputPath, FileManager.default.fileExists(atPath: inputPath) else {
    fail("wav 파일을 찾을 수 없습니다")
}

let timeline = try diarizer.processComplete(audioFileURL: URL(fileURLWithPath: inputPath))
let frameSeconds = Double(timeline.config.frameDurationSeconds)

var segments: [SpeakerSegment] = []
for (index, speaker) in timeline.speakers.sorted(by: { $0.key < $1.key }) {
    for s in speaker.finalizedSegments {
        segments.append(SpeakerSegment(speaker: index,
                                       start: Double(s.startFrame) * frameSeconds,
                                       end: Double(s.endFrame) * frameSeconds))
    }
}
segments.sort { $0.start < $1.start }

if !quiet {
    let count = Set(segments.map(\.speaker)).count
    print("화자 \(count)명, 구간 \(segments.count)개")
    for s in segments {
        print(String(format: "  [%6.2f–%6.2f] 화자 %@", s.start, s.end,
                     String(UnicodeScalar(65 + s.speaker)!)))
    }
}

if let jsonOut {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(segments).write(to: URL(fileURLWithPath: jsonOut))
}
