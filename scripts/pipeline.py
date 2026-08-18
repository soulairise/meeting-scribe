#!/usr/bin/env python3
"""녹음 → 전사 → 요약·할일·과제 생성까지 한 번에 처리한다.

LLM 백엔드는 이미 인증된 `claude` CLI를 쓴다. 별도 API 키가 필요 없다.
"""
import argparse, json, os, shutil, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSCRIBE = ROOT / ".build" / "release" / "Transcribe"
TEMPLATES = ROOT / "templates"

TRACK_LABEL = {"mic": "나", "system": "상대"}


def die(msg):
    print(f"오류: {msg}", file=sys.stderr)
    sys.exit(1)


def transcribe(wav: Path, locale: str) -> list[dict]:
    if not TRANSCRIBE.exists():
        die(f"Transcribe 실행파일이 없습니다. `swift build -c release` 먼저 실행하세요.")
    out = wav.with_suffix(".json")
    r = subprocess.run([str(TRANSCRIBE), str(wav), "--locale", locale, "--json", str(out)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die(f"전사 실패 ({wav.name}): {r.stderr.strip() or r.stdout.strip()}")
    data = json.loads(out.read_text())
    return next(iter(data.values()), [])


def merge(tracks: dict[str, list[dict]]) -> str:
    """여러 트랙을 시각 순으로 합쳐 화자 표시가 붙은 전사문을 만든다."""
    rows = []
    for track, segs in tracks.items():
        for s in segs:
            text = s["text"].strip()
            if text:
                rows.append((s["start"], s["end"], TRACK_LABEL.get(track, track), text))
    rows.sort(key=lambda r: r[0])

    lines, last_speaker = [], None
    for start, _end, speaker, text in rows:
        stamp = f"[{int(start)//60:02d}:{int(start)%60:02d}]"
        if speaker != last_speaker:
            lines.append(f"\n**{speaker}** {stamp} {text}")
            last_speaker = speaker
        else:
            lines.append(f"{stamp} {text}")
    return "\n".join(lines).strip()


def run_llm(prompt: str, model: str) -> str:
    if not shutil.which("claude"):
        die("`claude` CLI를 찾을 수 없습니다. LLM 단계를 건너뛰려면 --no-llm 을 쓰세요.")
    r = subprocess.run(["claude", "--print", "--model", model],
                       input=prompt, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"LLM 호출 실패: {r.stderr.strip()[:400]}")
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description="회의·강의 녹음을 회의록으로 변환한다")
    ap.add_argument("source", help="녹음 폴더 또는 wav 파일")
    ap.add_argument("--mode", choices=["meeting", "lecture"], default="meeting")
    ap.add_argument("--locale", default="ko-KR")
    ap.add_argument("--model", default="claude-sonnet-5")
    ap.add_argument("--terms", default=str(TEMPLATES / "terms.txt"))
    ap.add_argument("--out", help="결과 마크다운 경로 (기본: 녹음 폴더 안)")
    ap.add_argument("--no-llm", action="store_true", help="전사까지만 하고 멈춘다")
    args = ap.parse_args()

    src = Path(args.source)
    if src.is_dir():
        wavs = {p.stem: p for p in sorted(src.glob("*.wav")) or sorted(src.glob("*.m4a"))}
        if not wavs:
            die(f"{src} 안에 오디오 파일(wav/m4a)이 없습니다")
    elif src.is_file():
        wavs = {src.stem: src}
        src = src.parent
    else:
        die(f"경로를 찾을 수 없습니다: {args.source}")

    print(f"전사 중… ({', '.join(wavs)})")
    t0 = time.time()
    tracks = {}
    for name, path in wavs.items():
        segs = transcribe(path, args.locale)
        dur = segs[-1]["end"] if segs else 0
        print(f"  {name:8} {dur:6.1f}초  {len(segs)}개 구간")
        tracks[name] = segs

    transcript = merge(tracks)
    if not transcript:
        die("인식된 내용이 없습니다. 녹음 레벨을 확인하세요.")

    out_path = Path(args.out) if args.out else src / f"{args.mode}.md"
    raw_path = src / "transcript.md"
    raw_path.write_text(transcript, encoding="utf-8")
    print(f"  전사문 저장: {raw_path}  ({time.time()-t0:.1f}초)")

    if args.no_llm:
        return

    terms = Path(args.terms).read_text(encoding="utf-8").strip() if Path(args.terms).exists() else ""
    template = (TEMPLATES / f"{args.mode}.md").read_text(encoding="utf-8")
    prompt = template.replace("{{TERMS}}", terms).replace("{{TRANSCRIPT}}", transcript)

    print(f"{args.mode} 문서 생성 중… ({args.model})")
    t1 = time.time()
    result = run_llm(prompt, args.model)
    out_path.write_text(result, encoding="utf-8")
    print(f"  완료: {out_path}  ({time.time()-t1:.1f}초)")


if __name__ == "__main__":
    main()
