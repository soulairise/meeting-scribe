// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meeting-scribe",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "AudioCapture",
            path: "Sources/AudioCapture",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // TCC 권한 요청 문구를 CLI 바이너리에 직접 심는다.
                // 번들이 없는 실행파일은 이렇게 해야 마이크 권한 프롬프트가 뜬다.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "MeetingScribeApp",
            path: "Sources/MeetingScribeApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Transcribe",
            path: "Sources/Transcribe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        )
    ]
)
