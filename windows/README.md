# MeetingScribe — 윈도우 버전

macOS 판과 같은 일을 하지만 **내부 구현은 전혀 다르다.** 이식이 아니라 재작성이다.

| 기능 | macOS | Windows |
|---|---|---|
| 시스템 오디오 | Core Audio Process Tap | **WASAPI 루프백** (NAudio) |
| 마이크 | AVAudioEngine | **WASAPI 캡처** (NAudio) |
| 음성인식 | OS 내장 SpeechAnalyzer (무료) | **whisper.cpp** (Whisper.net, 모델 별도 다운로드) |
| UI | SwiftUI | **WinForms** (.NET 8) |
| 요약·용어교정 | Claude Code CLI | 동일 |
| 오디오 압축 | AVAudioFile → AAC | MediaFoundationEncoder → AAC |

## ⚠️ 검증 범위

- **컴파일 검증 완료** — 오류 0, 경고 0
- **게시(publish) 검증 완료** — win-x64 자체 포함 실행 파일 생성 확인
- **실제 윈도우에서의 동작은 검증하지 못했다.** 개발이 macOS에서 이루어졌다.
  오디오 장치 접근, 루프백 캡처, 모델 다운로드는 실제 윈도우 PC에서 확인이 필요하다.

문제가 있으면 이슈로 남겨주면 좋겠다.

## 설치

1. 릴리스에서 `MeetingScribe-win-x64.zip` 을 내려받아 압축을 푼다.
2. `MeetingScribe.exe` 를 실행한다. (.NET 설치 불필요 — 런타임이 포함되어 있다)
3. 처음 실행하면 **음성인식 모델을 약 550MB 내려받는다.** 최초 1회만이다.

Windows SmartScreen 경고가 뜨면 "추가 정보" → "실행"을 누른다. 서명이 없어서 그렇다.

## 필요 조건

- Windows 10 20H1 이상 (x64)
- Claude Code CLI 설치 및 로그인 — 요약·용어교정 단계에서 사용한다

## macOS 판과 다른 점

**음성인식 품질이 다르다.** macOS는 애플의 온디바이스 한국어 모델을, 윈도우는 whisper
large-v3-turbo(Q5_0 양자화)를 쓴다. 한국어 정확도는 대체로 비슷하거나 whisper 쪽이
조금 낫지만, **속도는 GPU 가속이 없으면 느리다.**

**모델 다운로드가 필요하다.** 최초 실행 시 550MB를 받는다. 저장 위치는
`%LOCALAPPDATA%\MeetingScribe\models` 다.

## 빌드

```bash
dotnet publish windows/MeetingScribe/MeetingScribe.csproj -c Release -r win-x64 --self-contained
```

macOS·Linux 에서도 빌드할 수 있다 (`EnableWindowsTargeting`). 실행은 윈도우에서만 된다.
`.github/workflows/windows.yml` 이 windows-latest 러너에서 같은 빌드를 돌린다.
