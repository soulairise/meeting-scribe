import SwiftUI

@main
struct MeetingScribeApp: App {

    init() {
        // 개발용 점검 훅. GUI 없이 파이프라인 단계를 직접 돌려본다.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            if args.contains("--live") {
                let lines = (try? Pipeline.liveTail(directory: dir, seconds: 25)) ?? []
                lines.forEach { print($0) }
            } else {
                let s = Pipeline.compress(directory: dir)
                let mb = { (b: Int64) in String(format: "%.2fMB", Double(b) / 1_048_576) }
                print("압축: \(mb(s.before)) → \(mb(s.after))  (\(s.before > 0 ? Int(100 - 100 * s.after / s.before) : 0)% 절감)")
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("MeetingScribe") {
            ContentView()
                .frame(minWidth: 470, idealWidth: 470, minHeight: 560, idealHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @StateObject private var recorder = Recorder()

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("MeetingScribe").font(.title2).bold()
                Text("회의·강의를 녹음해 회의록으로 만듭니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Picker("", selection: $recorder.mode) {
                ForEach(Pipeline.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(recorder.isBusy)
            .frame(width: 200)

            statusBlock

            liveCaptions
                .frame(maxHeight: .infinity)

            controls

            Button("저장 폴더 열기") { recorder.openLibrary() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var statusBlock: some View {
        VStack(spacing: 8) {
            switch recorder.phase {
            case .recording:
                Circle().fill(.red).frame(width: 10, height: 10)
                    .opacity(0.9)
                Text(recorder.statusText).font(.system(.body, design: .monospaced))
            case .transcribing, .summarizing:
                ProgressView().controlSize(.small)
                Text(recorder.statusText).font(.callout)
            case .failed(let message):
                Text(message)
                    .font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            case .done:
                Text("완료됐습니다").font(.callout).foregroundStyle(.green)
                if let saved = recorder.savedSummary {
                    Text(saved).font(.caption).foregroundStyle(.secondary)
                }
            case .idle:
                Text("모드를 고르고 녹음을 시작하세요").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(height: 62)
    }

    /// 녹음 중 받아적히는 내용을 3~4줄씩 흘려보낸다. 항상 마지막 줄이 보이도록 따라간다.
    @ViewBuilder private var liveCaptions: some View {
        if recorder.isBusy || !recorder.liveLines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(recorder.liveLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(index == recorder.liveLines.count - 1 ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                        if recorder.liveLines.isEmpty {
                            Text("받아적는 중…")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 120, maxHeight: .infinity)   // 3~4줄 이상, 창을 키우면 함께 늘어난다
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .onChange(of: recorder.liveLines.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch recorder.phase {
        case .idle, .failed:
            Button("녹음 시작") { recorder.start() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        case .recording:
            Button("중지하고 문서 만들기") { recorder.stop() }
                .controlSize(.large)
        case .transcribing, .summarizing:
            Button("처리 중…") {}.disabled(true).controlSize(.large)
        case .done:
            VStack(spacing: 8) {
                Button("결과 열기") { recorder.openResult() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                HStack {
                    Button("Finder에서 보기") { recorder.revealResult() }
                    Button("새 녹음") { recorder.reset() }
                }
            }
        }
    }
}
