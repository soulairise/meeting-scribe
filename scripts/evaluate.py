#!/usr/bin/env python3
"""전사 결과를 기준 원고와 비교해 문자 오류율(CER)과 용어별 적중을 보고한다."""
import json, re, sys, unicodedata

NUM = {'32':'삼십이','5':'오','800':'팔백','95':'구십오','%':'퍼센트'}

def norm(s, expand_numbers=True):
    s = unicodedata.normalize('NFC', s)
    if expand_numbers:
        for k in sorted(NUM, key=len, reverse=True):
            s = s.replace(k, NUM[k])
    s = re.sub(r'[.,!?·…"\'()\[\]]', '', s)
    return re.sub(r'\s+', '', s).lower()

def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (ca != cb)))
        prev = cur
    return prev[-1]

ref_path, res_path = sys.argv[1], sys.argv[2]
reference = open(ref_path, encoding='utf-8').read().strip()
results = json.load(open(res_path, encoding='utf-8'))
hypothesis = ' '.join(seg['text'] for segs in results.values() for seg in segs)

r, h = norm(reference), norm(hypothesis)
dist = edit_distance(r, h)
cer = dist / len(r) if r else 0

print(f"기준 원고 {len(r)}자 / 인식 결과 {len(h)}자")
print(f"편집거리 {dist}  →  CER {cer:.1%}\n")

# 회의에서 중요한 용어가 살아남았는지
terms = {
    'retention': ['리텐션', 'retention'],
    'cohort': ['코호트', 'cohort'],
    'dashboard': ['대시보드', 'dashboard'],
    'onboarding': ['온보딩', 'onboarding'],
    'funnel': ['퍼널', 'funnel'],
    'sprint': ['스프린트', 'sprint'],
    'A/B 테스트': ['ab테스트', 'a/b테스트', '에이비테스트'],
    'API': ['api', '에이피아이'],
    'p95': ['p95', 'p구십오', '피구십오'],
    '레이턴시': ['레이턴시', 'latency'],
    '밀리초': ['밀리초', 'ms'],
    '김대리': ['김대리'],
    '박과장': ['박과장'],
    '이대리': ['이대리'],
}
print("용어 적중")
hit = miss = 0
for label, variants in terms.items():
    ok = any(norm(v) in h for v in variants)
    print(f"  {'✅' if ok else '❌'} {label}")
    hit += ok; miss += (not ok)
print(f"\n  {hit}/{hit+miss} 적중 ({hit/(hit+miss):.0%})")
