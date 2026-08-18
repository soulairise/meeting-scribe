import Foundation
import SwiftUI

@MainActor
final class Recorder: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case summarizing
        case done(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// 녹음 중 화면에 흘려보내는 자막. 최근 것부터 몇 줄만 유지한다.
    @Published private(set) var liveLines: [String] = []
    @Published private(set) var savedSummary: String? = nil
    @Published var mode: Pipeline.Mode = .meeting
    @Published var model: String = "claude-sonnet-5"

    private var process: Process?
    private var sessionDirectory: URL?
    private var timer: Timer?
    private var liveTimer: Timer?
    private var liveRunning = false
    private var recordingDirectory: URL?

    var isBusy: Bool {
        switch phase {
        case .recording, .transcribing, .summarizing: return true
        default: return false
        }
    }

    var statusText: String {
        switch phase {
        case .idle:         return "준비됨"
        case .recording:    return "녹음 중 — \(formatted(elapsed))"
        case .transcribing: return "전사 중…"
        case .summarizing:  return "\(mode.label) 문서 작성 중…"
        case .done:         return "완료"
        case .failed(let m): return m
        }
    }

    /// 결과물이 쌓이는 곳. Finder에서 바로 찾을 수 있도록 문서 폴더에 둔다.
    static var libraryRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe")
    }

    init() {
        // 앱이 닫힐 때 녹음 프로세스를 반드시 정리한다.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let p = self.process, p.isRunning else { return }
            p.interrupt()
            p.waitUntilExit()
        }
    }

    /// 앱이 시작할 때 화자분리 모델을 미리 받아둔다 (최초 1회 약 260MB).
    /// 받지 못해도 녹음과 전사는 그대로 되고, 화자 구분만 생략된다.
    func warmUpModels() {
        Task.detached {
            guard let tool = try? Pipeline.resource("bin/Diarize") else { return }
            _ = try? Pipeline.run(tool, ["--warmup", "--quiet"], timeout: 900)
        }
    }

    func start() {
        guard !isBusy else { return }
        do {
            // AudioCapture 가 이 아래에 자기 타임스탬프 폴더를 만든다.
            let root = Self.libraryRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            sessionDirectory = root

            let capture = try Pipeline.resource("bin/AudioCapture")
            let p = Process()
            p.executableURL = capture
            p.arguments = ["--out", root.path]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            process = p

            elapsed = 0
            liveLines = []
            savedSummary = nil
            recordingDirectory = nil
            phase = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsed += 1 }
            }
            // 첫 자막은 6초쯤 뒤부터, 이후 5초 간격으로 갱신한다.
            liveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshLive() }
            }
        } catch {
            phase = .failed("녹음을 시작하지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 녹음 중인 폴더를 찾아 최근 구간만 전사해 자막을 갱신한다.
    private func refreshLive() {
        guard case .recording = phase, !liveRunning else { return }
        if recordingDirectory == nil { recordingDirectory = Self.newestDirectory(in: Self.libraryRoot) }
        guard let dir = recordingDirectory else { return }
        liveRunning = true
        Task { [weak self] in
            let lines = (try? await Task.detached { try Pipeline.liveTail(directory: dir, seconds: 25) }.value) ?? []
            await MainActor.run {
                guard let self else { return }
                if !lines.isEmpty { self.liveLines = Array(lines.suffix(12)) }
                self.liveRunning = false
            }
        }
    }

    static func newestDirectory(in root: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.hasDirectoryPath }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    func stop() {
        guard case .recording = phase, let p = process else { return }
        timer?.invalidate(); timer = nil
        liveTimer?.invalidate(); liveTimer = nil
        p.interrupt()                 // SIGINT — WAV 헤더를 확정하고 정상 종료한다
        p.waitUntilExit()
        process = nil
        phase = .transcribing
        Task { await process_() }
    }

    private func process_() async {
        // AudioCapture 는 --out 아래에 자신의 타임스탬프 폴더를 만든다. 가장 최근 것을 찾는다.
        guard let parent = sessionDirectory,
              let latest = recordingDirectory ?? Self.newestDirectory(in: parent)
        else {
            phase = .failed("녹음 폴더를 찾을 수 없습니다")
            return
        }

        let selectedMode = mode
        let selectedModel = model
        do {
            let transcript = try await Task.detached { try Pipeline.transcribe(directory: latest) }.value
            try transcript.write(to: latest.appendingPathComponent("전사문.md"), atomically: true, encoding: .utf8)

            phase = .summarizing
            let document = try await Task.detached {
                try Pipeline.summarize(transcript: transcript, mode: selectedMode, model: selectedModel)
            }.value

            let out = latest.appendingPathComponent(selectedMode.outputName)
            try document.write(to: out, atomically: true, encoding: .utf8)

            // 전사가 끝난 뒤에 오디오를 줄인다 (WAV → 32kbps AAC, 약 1/8)
            let sizes = await Task.detached { Pipeline.compress(directory: latest) }.value
            if sizes.before > 0 {
                let mb = { (b: Int64) in String(format: "%.1fMB", Double(b) / 1_048_576) }
                savedSummary = "녹음 파일 \(mb(sizes.before)) → \(mb(sizes.after))"
            }
            phase = .done(out)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() { phase = .idle; elapsed = 0 }

    func revealResult() {
        if case .done(let url) = phase {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openResult() {
        if case .done(let url) = phase { NSWorkspace.shared.open(url) }
    }

    func openLibrary() {
        try? FileManager.default.createDirectory(at: Self.libraryRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.libraryRoot)
    }

    private func formatted(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
