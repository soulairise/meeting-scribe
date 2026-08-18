import AVFoundation
import Foundation

// ── 인자 파싱 ────────────────────────────────────────────────────────────────
var outputDir = FileManager.default.currentDirectoryPath + "/recordings"
var seconds: Double? = nil
var tracks: Set<String> = ["mic", "system"]

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--out", "-o":
        guard let v = args.first else { fail("--out 뒤에 경로가 필요합니다") }
        outputDir = v; args.removeFirst()
    case "--seconds", "-s":
        guard let v = args.first, let d = Double(v) else { fail("--seconds 뒤에 숫자가 필요합니다") }
        seconds = d; args.removeFirst()
    case "--only":
        guard let v = args.first, ["mic", "system"].contains(v) else { fail("--only 는 mic 또는 system") }
        tracks = [v]; args.removeFirst()
    case "--help", "-h":
        print("""
        사용법: audio-capture [옵션]

          -o, --out <경로>      녹음 저장 폴더 (기본: ./recordings)
          -s, --seconds <초>    지정 시간 후 자동 종료 (기본: Ctrl+C 까지)
              --only <트랙>     mic 또는 system 한쪽만 녹음
          -h, --help            이 도움말

        마이크와 시스템 오디오를 각각 16kHz 모노 WAV로 따로 저장합니다.
        """)
        exit(0)
    default:
        fail("알 수 없는 옵션: \(arg)")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("오류: \(message)\n".utf8))
    exit(1)
}

// ── 준비 ────────────────────────────────────────────────────────────────────
let stamp = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}()

let sessionDir = URL(fileURLWithPath: outputDir).appendingPathComponent(stamp)
var writers: [String: WavWriter] = [:]
var micCapture: MicCapture?
var systemTap: SystemAudioTap?

func shutdown(_ code: Int32) -> Never {
    micCapture?.stop()
    systemTap?.stop()
    print("")
    for (name, writer) in writers.sorted(by: { $0.key < $1.key }) {
        let duration = writer.durationSeconds
        try? writer.finalize()
        let size = ((try? FileManager.default.attributesOfItem(atPath: writer.url.path))?[.size] as? Int) ?? 0
        let mark = duration > 0.1 ? "✅" : "⚠️ (무음 — 권한을 확인하세요)"
        print(String(format: "  %-7s %6.1f초  %5.1f MB  %@  %@",
                     (name as NSString).utf8String!, duration,
                     Double(size) / 1_048_576, mark, writer.url.path))
    }
    exit(code)
}

signal(SIGINT) { _ in shutdown(0) }
signal(SIGTERM) { _ in shutdown(0) }

// ── 시작 ────────────────────────────────────────────────────────────────────
print("녹음 시작 — \(sessionDir.path)")

if tracks.contains("mic") {
    let w = try WavWriter(url: sessionDir.appendingPathComponent("mic.wav"))
    writers["mic"] = w
    let capture = MicCapture(writer: w)
    do {
        try capture.start()
        micCapture = capture
        print("  마이크      시작됨")
    } catch {
        print("  마이크      실패 — \(error.localizedDescription)")
    }
}

if tracks.contains("system") {
    let w = try WavWriter(url: sessionDir.appendingPathComponent("system.wav"))
    writers["system"] = w
    let tap = SystemAudioTap(writer: w)
    do {
        try tap.start()
        systemTap = tap
        print("  시스템오디오 시작됨")
    } catch {
        print("  시스템오디오 실패 — \(error.localizedDescription)")
    }
}

guard micCapture != nil || systemTap != nil else {
    fail("두 트랙 모두 시작하지 못했습니다")
}

// 부모 프로세스가 사라지면 스스로 멈춘다.
// 앱이 강제 종료돼도 녹음만 남아 계속 도는 사고를 막는다.
let parentPID = getppid()
if parentPID > 1 {
    let watcher = Thread {
        while true {
            Thread.sleep(forTimeInterval: 2)
            if getppid() != parentPID { shutdown(0) }
        }
    }
    watcher.start()
}

// 안전장치: 지정이 없어도 4시간이면 자동 종료한다.
let hardLimit: Double = 4 * 60 * 60
DispatchQueue.main.asyncAfter(deadline: .now() + hardLimit) {
    FileHandle.standardError.write(Data("최대 녹음 시간(4시간)에 도달해 종료합니다.\n".utf8))
    shutdown(0)
}

if let seconds {
    print("\(Int(seconds))초 후 자동 종료합니다. (Ctrl+C 로 즉시 중단)")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { shutdown(0) }
} else {
    print("Ctrl+C 로 종료합니다.")
}

RunLoop.main.run()
