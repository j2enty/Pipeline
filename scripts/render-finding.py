#!/usr/bin/env python3
# render-finding.py — 리뷰 finding 1건을 GitHub 이슈로 만들 재료로 렌더한다.
#
# 무엇을: finding JSON(argv[1]) + 환경변수(출처·영역·라벨)를 받아
#         'fp \t 제목 \t 라벨 \t 본문(base64)' 한 줄(TSV)을 stdout 에 출력한다.
#         track-findings.sh 가 이 출력을 파싱해 intra/cross-run dedup 후 이슈를 만든다.
#
# 왜 별도 파일인가: 과거 이 로직은 track-findings/action.yml 의 python heredoc 에
#   통째로 박혀 있어 단위테스트가 불가능했다(#104 M9). fingerprint 정규화·dedup 기준·
#   이모지 title sha 폴백 같은 미묘한 로직은 회귀 그물 없이 한 줄만 바꿔도 finding 소실/
#   이슈 폭주로 이어진다 → 순수 함수로 추출해 test-render-finding.sh 로 고정한다.
#   (로직은 action.yml 원본과 동일 — 행위 보존. 위치만 파일로 옮겼다.)
#
# 입력 환경변수:
#   FINDING_SOURCE  'code-review' | 'critic' (필수)
#   AREA            영역명 (옵션, critic 모드에서 env AREA 가 비어있을 수 있음)
#   MAJOR_LABEL     major finding 라벨 (필수)
#   MINOR_LABEL     minor finding 라벨 (필수)

import sys, os, json, hashlib, base64, re

finding = json.loads(sys.argv[1])
source = os.environ["FINDING_SOURCE"]
area = os.environ.get("AREA", "")
major_label = os.environ["MAJOR_LABEL"]
minor_label = os.environ["MINOR_LABEL"]

def normalize(title):
    # lowercase → 유니코드 문자/숫자/공백 보존(한글 포함), 구두점만 공백화
    #            → 공백 1칸 정규화 → 앞 60자
    # 주의: [^a-z0-9\s] 로 하면 한글 등 비-ASCII 가 전부 제거되어
    #       한국어 title 이 빈 문자열로 뭉개지고 fingerprint 가 충돌한다.
    #       \w + re.UNICODE 로 한글/숫자/문자를 보존한다.
    t = (title or "").lower()
    t = re.sub(r"[^\w\s]", " ", t, flags=re.UNICODE)
    t = re.sub(r"\s+", " ", t).strip()
    return t[:60]

severity = (finding.get("severity") or "").strip()
title = (finding.get("title") or "").strip()
description = (finding.get("description") or "").strip()
suggestion = (finding.get("suggestion") or "").strip()
norm_title = normalize(title)
# 안전장치: 정규화 결과가 비면(순수 구두점/이모지 title 등) 서로 다른 title 이
#          같은 빈 문자열로 뭉개져 fingerprint 가 충돌한다.
#          원본 title 의 sha256 일부를 basis 에 섞어 충돌을 회피한다.
if not norm_title and title:
    norm_title = "h:" + hashlib.sha256(title.encode("utf-8")).hexdigest()[:12]

# ── fingerprint basis 구성 ──
# description 시그니처: 같은 파일·제목(혹은 같은 영역·제목)이라도 내용이 다른
#   별개 finding 이 intra-run dedup 으로 소실되는 것을 막는다(버그 #4).
#   line 은 머지 후 이동하므로 키에 쓰지 않고, 안정적인 description 해시 일부를 쓴다.
# 트레이드오프: 재리뷰마다 description 이 미세하게 바뀌면 같은 버그가 다른 fp 가 되어
#   중복 이슈가 생길 수 있다(과소 dedup). 하지만 finding 소실(과대 dedup)이 더 위험하므로
#   소실을 막는 이 방향을 택한다.
desc_sig = hashlib.sha256((description or "").encode("utf-8")).hexdigest()[:8]
if source == "code-review":
    file_path = (finding.get("file") or "").strip()
    line = finding.get("line")
    fp_basis = f"{file_path}|{severity}|{norm_title}|{desc_sig}"
else:  # critic — file 없음, area 기반
    file_path = ""
    line = None
    # 버그 #1: finding 자체의 area 를 우선 사용한다.
    #   critic-dispatch.yml 호출부는 area input 을 안 넘겨 env AREA 가 빈 문자열이라,
    #   env AREA 만 쓰면 서로 다른 영역의 같은 제목 finding 이 같은 fingerprint 가 되어
    #   intra-run dedup 으로 두 번째가 소실된다. finding.area 를 우선해 영역별로 구분한다.
    finding_area = (finding.get("area") or area).strip()
    fp_basis = f"{finding_area}|{severity}|{norm_title}|{desc_sig}"

fp = hashlib.sha256(fp_basis.encode("utf-8")).hexdigest()[:12]

label = major_label if severity == "major" else minor_label

# ── 이슈 본문 렌더 ──
lines = []
lines.append(f"**severity**: {severity}")
if source == "code-review":
    loc = file_path if file_path else "(파일 정보 없음)"
    if line is not None and line != "":
        loc = f"{loc}:{line}"
    lines.append(f"**위치**: {loc}")
else:
    affected = finding.get("affected_prs") or []
    # 버그 #1: 본문도 finding.area(없으면 env area) 를 써서 영역이 누락되지 않게 한다.
    if finding_area:
        lines.append(f"**영역**: {finding_area}")
    if affected:
        lines.append("**영향 PR**: " + ", ".join(str(p) for p in affected))
if description:
    lines.append("")
    lines.append("## 설명")
    lines.append(description)
if suggestion:
    lines.append("")
    lines.append("## 제안")
    lines.append(suggestion)
if source == "code-review" and line is not None and line != "":
    lines.append("")
    lines.append("> ⚠️ line 은 리뷰 당시 기준 — 머지 후 무효일 수 있음")
lines.append("")
lines.append(f"<!-- finding-fp: {fp} -->")
body = "\n".join(lines)

# 제목 끝에 fingerprint 토큰을 결정적으로 박는다.
# 이유(버그 #7): gh search 는 인덱싱 지연이 있어 본문 마커만으론
#   cross-run 중복 검색이 부정확할 수 있다. 제목에 ` [fp:<fp>]` 를 고정 포함하면
#   `gh issue list --search "<fp> in:title"` 로 더 정확하게 기존 이슈를 찾을 수 있다.
base_title = f"[{severity}] {title}" if title else f"[{severity}] finding {fp}"
# base_title 이 매우 길면(300자+) GitHub 가 제목을 자르면서 끝의 [fp:...] 가
# 먼저 잘려 cross-run dedup 이 깨진다. fp suffix 가 항상 보존되도록 base 를 200자로 제한.
# (fp suffix 포함해도 GitHub 제목 한계 1024 대비 충분히 여유)
base_title = base_title[:200]
issue_title = f"{base_title} [fp:{fp}]"
body_b64 = base64.b64encode(body.encode("utf-8")).decode("ascii")

# fp \t 제목 \t 라벨 \t 본문(base64) — 제목에 탭/개행 정규화
issue_title = issue_title.replace("\t", " ").replace("\n", " ")
sys.stdout.write(f"{fp}\t{issue_title}\t{label}\t{body_b64}\n")
