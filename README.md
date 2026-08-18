# meeting-scribe

회의·강의를 녹음해 **회의록·요약·담당자별 할 일**을, 강의는 **개념 정리·이해도 문항·과제**까지 만들어 주는 도구.
한국어 회의에 섞이는 영어 용어를 LLM이 교정한다.

## 📥 내려받기

| 플랫폼 | 파일 | 크기 |
|---|---|---|
| **macOS** 26 이상 | [MeetingScribe-0.1.1.dmg](https://github.com/soulairise/meeting-scribe/releases/download/v0.1.1/MeetingScribe-0.1.1.dmg) | 486KB |
| **Windows** 10 20H1 이상 (x64) | [MeetingScribe-0.1.1-win-x64.zip](https://github.com/soulairise/meeting-scribe/releases/download/v0.1.1/MeetingScribe-0.1.1-win-x64.zip) | 64MB |

전체 목록은 [릴리스 페이지](https://github.com/soulairise/meeting-scribe/releases/latest)에 있다.

> **macOS 첫 실행** — 서명이 없어 차단된다. 더블클릭 → [완료] → **시스템 설정 > 개인정보 보호 및 보안** →
> 아래로 스크롤 → *"'MeetingScribe'이(가) 차단되었습니다"* → **[그래도 열기]**.
> macOS 15부터 "오른쪽 클릭 → 열기"는 동작하지 않는다.
>
> **Windows 첫 실행** — SmartScreen 경고에서 "추가 정보" → "실행". 첫 실행 시 음성인식 모델 550MB를 내려받는다.

**공통 필요 조건**: [Claude Code](https://claude.com/claude-code) CLI 설치 및 로그인 (요약·용어교정에 사용)

## 지금 되는 것

마이크와 시스템 오디오를 **각각 별도 트랙**으로 동시에 녹음해서 16kHz 모노 WAV로 저장한다.

```
recordings/20260818-122459/
├── mic.wav       내 목소리 (AVAudioEngine)
└── system.wav    상대방 목소리 (Core Audio Process Tap)
```

두 트랙을 나누는 게 이 설계의 핵심이다. 나중에 화자분리를 할 때 "나 vs 상대"가
이미 갈라져 있으므로 난이도가 크게 떨어진다.

## 빌드와 실행

```bash
./scripts/build-app.sh        # .app 번들 생성 + ad-hoc 서명
./scripts/record.sh 30        # 30초 녹음
./scripts/record.sh           # Ctrl+C 까지 녹음
```

## ⚠️ 반드시 `.app`으로 실행할 것

`swift build`로 만든 CLI 바이너리를 셸에서 직접 실행하면 **시스템 오디오가 무음으로만 녹음된다.**

```bash
.build/release/AudioCapture --only system   # ❌ 무음. 오류도 안 남
open build/MeetingScribe.app --args ...     # ✅ 정상
```

macOS는 프로세스 탭의 권한 주체를 실행 주체(responsible process)로 판단한다.
셸에서 직접 띄우면 주체가 터미널이 되어 탭이 무음을 반환하고, **오류나 권한 프롬프트가 전혀 뜨지 않는다.**
`open`으로 띄우면 앱 자신이 주체가 되어 정상 작동한다.

디버깅에 시간을 많이 잡아먹는 함정이라 `scripts/record.sh`가 항상 `open`을 쓰도록 해뒀다.

## 구조

| 파일 | 역할 |
|---|---|
| `SystemAudioTap.swift` | Core Audio Process Tap + 비공개 집합 장치로 시스템 출력 캡처 |
| `MicCapture.swift` | AVAudioEngine으로 마이크 캡처 |
| `Resampler.swift` | 임의 포맷 → 16kHz 모노 Int16 (AVAudioConverter) |
| `WavWriter.swift` | 16-bit PCM WAV. 헤더 길이는 종료 시 확정 |
| `CoreAudioHelpers.swift` | Core Audio 속성 조회 헬퍼 |
| `main.swift` | CLI 진입점, 시그널 처리 |

### 동작 원리 (시스템 오디오)

1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` 로 전역 탭 생성
   - `muteBehavior = .unmuted` — 사용자에게는 소리가 계속 들린다
2. 그 탭만 담은 **비공개 집합 장치** 생성 (`kAudioAggregateDeviceSubDeviceListKey`는 비워둔다)
3. 집합 장치에 IOProc 등록 → 입력 스트림에서 48kHz Float32 스테레오로 수신
4. 16kHz 모노 Int16으로 변환 후 WAV에 기록

## 검증 결과 (2026-08-18, macOS 26.5.2)

| 항목 | 결과 |
|---|---|
| 마이크 트랙 | 12.6초, rms 876 (-31.5 dBFS) ✅ |
| 시스템 트랙 | 12.6초, rms 2861 (-21.2 dBFS) ✅ |
| 두 트랙 독립성 | 파형이 서로 다름 — 시스템은 깨끗, 마이크는 스피커 누설 포함 ✅ |
| 클리핑 | 0.012% (합성음성 최대볼륨 기준). 실사용에선 문제 없을 것 |

### 집합 장치에는 반드시 서브디바이스를 넣을 것

`kAudioAggregateDeviceSubDeviceListKey`를 비워두면 **처음 3초만 녹음되고 이후 무음**이 된다.
클럭 소스가 없어서다. 오류도 경고도 없이 조용히 무음이 되므로 알아채기 어렵다.
출력 장치를 서브디바이스로 넣으면 해결된다. (2026-08-18 실제 강의 녹음에서 발견)

## 알려진 한계 / 다음 할 일

- **리미터 없음** — 입력이 과하면 클리핑된다. ASR 정확도에 영향을 줄 수 있어 추후 소프트 리미터 필요
- **출력 장치 변경 미대응** — 녹음 중 이어폰을 뽑으면 탭이 끊긴다. 장치 변경 감지 후 재생성 필요
- **디스크 여유 확인 없음** — 장시간 녹음 시 공간 부족 처리 필요
- 서명이 ad-hoc이라 배포 불가. 배포하려면 Developer ID 서명 + 공증 필요

---

# 전사 (Transcribe)

녹음된 WAV를 **macOS 26 온디바이스 음성인식**으로 전사한다. API 키·네트워크가 필요 없다.

```bash
./scripts/build-app.sh
.build/release/Transcribe testdata/meeting.wav --json out.json
python3 scripts/evaluate.py testdata/reference-spoken.txt out.json
```

## ⚠️ SpeechAnalyzer 호출 순서 함정

세 가지를 어기면 전부 **`nilError` 하나로만** 실패한다. 원인을 알려주는 메시지가 없다.

| 규칙 | 어기면 |
|---|---|
| `bestAvailableAudioFormat`은 **`start()` 이후**에 호출 | `start()`가 nilError |
| `transcriber.results` 구독은 **`start()` 이후**에 시작 | `start()`가 nilError |
| 이미 설치된 로케일에 `assetInstallationRequest`를 만들지 말 것 | 요청 시점에 nilError |

추가로 `AVAudioFile.read(into:frameCount:)`는 파일 끝에서 0프레임을 돌려주지 않고 **예외를 던진다.**
`framePosition < length`로 직접 루프를 돌아야 한다.

## POC 결과 (2026-08-18)

합성 음성으로 만든 38.7초 한국어 회의(영어 용어 포함)를 전사한 결과.

| 항목 | 값 |
|---|---|
| 속도 | **40배속** (38.7초 오디오 → 1.0초) |
| CER | **12.4%** (발음 기준 원고 대비, 숫자 표기 정규화 후) |
| 비용 | 0원, 오프라인 |

**용어 적중 8/14 (57%)**

| 잘 인식됨 ✅ | 통째로 소실됨 ❌ |
|---|---|
| 리텐션, 코호트, 대시보드 | **A/B 테스트** → "테스" |
| 온보딩, 퍼널, 스프린트 | **API** → 사라짐 |
| 박과장, 이대리 | **p95 레이턴시** → "시가" |
| | **밀리초** → "800m" |
| | 김대리 → "김태리" |

### 핵심 발견

1. **한글로 음차되는 외래어는 잘 잡는다.** 리텐션·코호트·대시보드·온보딩·퍼널·스프린트 전부 정확.
2. **영문 약어와 기술 단위는 통째로 사라진다.** A/B, API, p95, 밀리초 — 회의록에서 가장 중요한 정보가 날아간다.
3. **`AnalysisContext.contextualStrings`(용어 사전)는 효과가 없다.** 15개 용어를 `setContext`로도, 생성자로도 주입해봤으나 출력이 **한 글자도 바뀌지 않았다.**

### 이 결과가 바꾸는 설계 결정

> **용어 교정은 ASR 단계가 아니라 LLM 후처리 단계에서 한다.**

어차피 요약·할일 추출을 위해 LLM이 파이프라인에 들어온다. 전사문과 용어 사전을 함께 넘겨
"A/B, API, p95 같은 용어가 잘못 인식된 곳을 고쳐라"고 시키는 편이, ASR 단계에서 씨름하는 것보다 확실하다.

### 유의

이건 **깨끗한 합성 음성** 기준이라 실제 회의의 상한선이다. 실제 회의는 잡음·겹침·억양 때문에 더 나쁘다.
클라우드 API(Scribe / 리턴제로 / CLOVA)와의 비교는 실제 회의 녹음이 생긴 뒤에 한다.

---

# 설치본 (macOS 앱)

```bash
./scripts/build-app.sh      # MeetingScribe.app 생성
./scripts/make-dmg.sh       # 배포용 DMG 생성
```

`build/MeetingScribe-0.1.1.dmg` — 드래그해서 응용 프로그램에 넣는다.
설치·사용 안내는 `docs/설치안내.txt` 에 있고 DMG 안에도 들어간다.

### ⚠️ 첫 실행 — macOS 15 부터 절차가 바뀌었다

자체 서명 앱이라 Gatekeeper 가 차단한다. **"오른쪽 클릭 → 열기" 는 macOS 15 부터 통하지 않는다.**
차단 대화상자에 "열기" 버튼 자체가 없다.

1. 더블클릭 → 차단 창 → [완료]
2. **시스템 설정 > 개인정보 보호 및 보안** → 아래로 스크롤 → "'MeetingScribe'이(가) 차단되었습니다" → **[그래도 열기]**
3. 암호/Touch ID 확인 → 다시 뜨는 창에서 [열기]

또는 격리 속성을 직접 지운다:

```bash
xattr -d com.apple.quarantine /Applications/MeetingScribe.app
```

앱은 GUI 안에 CLI 도구(`AudioCapture`, `Transcribe`)와 템플릿을 함께 담는다.
GUI가 자식 프로세스를 띄우면 **TCC 권한 주체가 앱이 되므로** 마이크·시스템 오디오 권한을
앱 이름으로 한 번만 승인하면 된다. 터미널에서 겪던 무음 문제가 구조적으로 해결된다.

## 앱이 하는 일

1. 회의/강의 모드 선택 → [녹음 시작]
2. **녹음 중 받아적히는 내용이 3~4줄씩 흘러간다** (5초마다 갱신)
3. [중지하고 문서 만들기] → 전사 → 용어교정·요약·할일 생성
4. 오디오를 AAC로 압축하고 원본 WAV 삭제
5. 결과는 `서류 > MeetingScribe > 날짜-시각` 에 저장

## 라이브 자막 구현

녹음 중에 파일을 읽어야 하므로 `WavWriter`가 **약 2초마다 헤더의 길이 필드를 갱신**한다.
덕분에 다른 프로세스가 진행 중인 WAV를 읽을 수 있고, 비정상 종료해도 직전까지가 재생 가능하다.

자막은 `Transcribe --tail 25` 로 **파일 끝 25초만** 전사한다. 녹음이 길어져도 갱신 속도가 일정하다.

## 녹음 용량

16kHz 모노 PCM은 **시간당 115MB**(두 트랙이면 230MB)다. 그래서 전사가 끝난 뒤
32kbps AAC(.m4a)로 변환하고 WAV를 지운다.

| | 20초 녹음 2트랙 |
|---|---|
| 변환 전 (WAV) | 1.28MB |
| 변환 후 (m4a) | 0.13MB |
| 절감 | **91%** |

시간당으로는 약 230MB → 28MB. 변환에 실패하면 WAV를 그대로 남긴다.

> 녹음 **중**에는 WAV를 유지해야 라이브 자막이 파일을 읽을 수 있어서, 변환은 끝난 뒤에 한다.

---

# 전체 파이프라인

녹음 → 전사 → 회의록/강의기록 생성까지 한 번에.

```bash
./scripts/meeting.sh 600            # 10분 회의 → 회의록
./scripts/meeting.sh 600 lecture    # 10분 강의 → 강의기록·설문·과제
```

이미 녹음된 폴더를 처리하려면:

```bash
python3 scripts/pipeline.py recordings/20260818-141455/ --mode lecture
```

## LLM 백엔드

별도 API 키가 필요 없다. 이미 인증된 **`claude` CLI**를 그대로 쓴다.
`--model`로 바꿀 수 있고 기본값은 `claude-sonnet-5`다.

## 템플릿

| 파일 | 용도 |
|---|---|
| `templates/meeting.md` | 요약·핵심논의·결정사항·담당자별 할일 |
| `templates/lecture.md` | 개념표·강의흐름·이해도 확인 문항·과제 제안 |
| `templates/terms.txt` | 용어 사전. **여기에 용어를 추가하는 것이 품질 개선의 핵심** |

새 산출물이 필요하면 템플릿 파일 하나만 추가하면 된다. 코드는 손대지 않는다.

## 용어 교정 — 이 도구의 핵심 설계

ASR은 영문 약어와 기술 용어를 반드시 틀린다. `AnalysisContext.contextualStrings`로
ASR 단계에서 고치려 시도했으나 **효과가 전혀 없었다.** 그래서 LLM 단계에서 고친다.

실제 강의 녹음 검증 결과 (2026-08-18):

| ASR 출력 | LLM 교정 |
|---|---|
| 비스캔 | **DBSCAN** ✅ |
| 케이민즈 | **K-means** ✅ |
| 클로스팅 / 클러스 / 클러스팅 | **클러스터링** ✅ (3가지 표기를 하나로) |
| 프로포즈 모드 | `프로포즈 모드[?]` — 추측하지 않고 표시 ✅ |

프롬프트에 "확신이 없으면 원문을 두고 `[?]`를 붙여라"를 넣은 것이 중요하다.
없는 내용을 지어내지 않게 만드는 장치다.

## ⚠️ 발견: 짧게 끊어 전사하면 정확도가 크게 오른다

같은 38.7초 파일을 통째로 전사할 때와 `--tail 10`으로 마지막 10초만 전사할 때의 차이다.

| 실제 발화 | 전체 전사 | 마지막 10초만 |
|---|---|---|
| API 응답 속도 | (사라짐) ❌ | **API 응답 속도** ✅ |
| p95 레이턴시 | "시가" ❌ | **P95 레이턴시** ✅ |
| 로그를 보니 | "그를 보니" ❌ | **로그를 보니** ✅ |
| 팔백 밀리초 | "800m" ❌ | **800m 초까지** ⚠️ |

긴 오디오를 한 번에 넣으면 인식기가 뒤쪽에서 무너진다.
**최종 전사도 30초 안팎으로 잘라 처리하도록 바꾸면 품질이 눈에 띄게 오를 것으로 보인다.**
경계에서 문장이 잘리거나 겹치는 문제를 다뤄야 해서 아직 적용하지 않았다. 다음 작업 1순위.

## 알려진 한계

- **최종 전사는 아직 통짜 처리** — 위 발견을 적용하지 않았다
- **긴 회의 미검증** — 66초 전사에 LLM 42초가 걸렸다. 90분 회의는 전사문이 커서 분할 처리가 필요할 수 있다
- **화자분리 없음** — 지금은 트랙(마이크/시스템)으로만 "나/상대"를 나눈다. 상대가 여러 명이면 구분되지 않는다
- **클라우드 API 미비교** — 온디바이스만 검증했다

## 로드맵

```
S1 오디오 캡처         ✅ 완료
S2 전사 (온디바이스)   ✅ 완료
S4 템플릿 엔진         ✅ 완료 — 용어교정·요약·할일·설문·과제
S5 GUI 앱 + 설치본     ✅ 완료 — 라이브 자막, AAC 압축
분할 전사로 정확도 개선  ← 다음 1순위 (근거 확보됨)
S3 화자분리 + 이름 매핑    상대가 여러 명일 때 필요
S2b 클라우드 API 비교
윈도우 버전              docs/윈도우-버전-검토.md 참고
```
