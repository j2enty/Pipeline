#!/usr/bin/env bash
# track-findings.sh — 리뷰 상태파일의 finding 을 읽어 major/minor 를 GitHub 이슈로 추적(생성).
#
# 무엇을: 리뷰가 상태파일(.pipeline/state/reviews/<slug>.json)에 저장한 finding(지적사항)을
#         읽어, major/minor 만 골라 GitHub 이슈로 만든다. actions/track-findings/action.yml 이
#         이 스크립트를 호출한다(self-hosted 러너의 review.yml / critic-dispatch.yml 경유).
#
# 왜 스크립트로 추출했나(#104 M9):
#   과거 이 로직(fingerprint 렌더 + intra/cross-run dedup + 이슈 생성)은 action.yml 의
#   python heredoc + bash 에 통째로 박혀 단위테스트가 불가능했다. dedup 은 과소/과대의
#   미묘한 트레이드오프라 회귀 그물 없이 한 줄만 건드려도 finding 소실·이슈 폭주로 이어진다.
#   → 로직을 이 스크립트(+ render-finding.py)로 추출해 test-track-findings.sh 로 고정한다.
#   action.yml 은 이제 이 스크립트를 호출만 한다(행위 보존 — 로직 동일, 위치만 이동).
#
# 핵심 원칙:
#   - 추적 실패가 상위 리뷰/머지를 막지 않는다 — 모든 실패는 흡수(graceful, exit 0).
#   - 프로젝트 식별자 하드코딩 제로 — owner/area/repo/라벨 전부 env 로 주입.
#   - 중복 이슈 방지: 결정적 fingerprint(LLM 비결정 요소 배제) + intra/cross-run 이중 dedup.
#
# 입력 환경변수(action.yml env 블록이 주입):
#   STATE_FILE_PATH  읽을 상태파일 절대경로 (필수)
#   FINDING_SOURCE   'code-review' | 'critic' (필수)
#   AREA             영역명 (code-review 모드; 상태파일 prs.<area> 키)
#   AREA_REPO        이슈 생성 대상 <owner>/<repo> (code-review 모드)
#   PARENT_REPO      이슈 생성 대상 <owner>/<repo> (critic 모드)
#   MAJOR_LABEL      major finding 라벨 (기본 major-issue — action.yml 기본값)
#   MINOR_LABEL      minor finding 라벨 (기본 minor-issue)
#   GH_TOKEN         이슈 생성용 토큰 (gh 가 소비)
#
# 입력 데이터 스키마:
#   - code-review: .prs[<area>].findings.codeReview[] = {severity,file,line,title,description,suggestion}
#   - critic:      .aggregate.criticFindings[]        = {severity,area,title,description,affected_prs}
set -euo pipefail

# render-finding.py 는 이 스크립트와 같은 scripts/ 에 있다. 호출 방식(bash <path> / uses)과
# 무관하게 항상 sibling 을 찾도록 BASH_SOURCE 기준으로 해석한다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_PY="$SCRIPT_DIR/render-finding.py"

# graceful 불변식: 렌더 스크립트 부재(잘못된 배포·경로)면 finding 을 만들 수 없다.
# 매 finding 마다 warning 을 N번 내기보다, 한 번 loud 하게 알리고 graceful 종료(exit 0)한다.
# (추적 실패가 본 리뷰/머지를 막지 않는다는 설계 의도 보존.)
if [ ! -f "$RENDER_PY" ]; then
  echo "::error::track-findings: 렌더 스크립트 부재($RENDER_PY) — 추적 스킵(graceful)"
  exit 0
fi

# ── 1. 파일 부재 → graceful 종료 (추적 실패가 상위를 막지 않음) ──
if [ -z "${STATE_FILE_PATH:-}" ] || [ ! -f "$STATE_FILE_PATH" ]; then
  echo "::warning::track-findings: 상태파일 없음 (${STATE_FILE_PATH:-}) — 추적 스킵"
  exit 0
fi

# ── 2. 대상 레포 결정 ──
case "$FINDING_SOURCE" in
  code-review)
    TARGET_REPO="$AREA_REPO"
    if [ -z "${AREA:-}" ] || [ -z "${TARGET_REPO:-}" ]; then
      echo "::warning::track-findings: code-review 모드엔 area + area-repo 필요 — 스킵"
      exit 0
    fi
    ;;
  critic)
    TARGET_REPO="$PARENT_REPO"
    if [ -z "${TARGET_REPO:-}" ]; then
      echo "::warning::track-findings: critic 모드엔 parent-repo 필요 — 스킵"
      exit 0
    fi
    ;;
  *)
    echo "::warning::track-findings: 알 수 없는 finding-source ($FINDING_SOURCE) — 스킵"
    exit 0
    ;;
esac

# ── 3. jq 로 finding 추출 (major/minor 만). 키 부재(구버전 파일)는 ?/// empty 로 graceful ──
#    각 finding 을 한 줄 JSON(NDJSON)으로 출력 → 셸 루프에서 한 줄씩 처리.
if [ "$FINDING_SOURCE" = "code-review" ]; then
  # $a 는 jq 변수 — single quote 안 미확장 의도적
  # shellcheck disable=SC2016
  FINDINGS_NDJSON=$(jq -c --arg a "$AREA" \
    '(.prs[$a].findings.codeReview // [])[]?
     | select(.severity == "major" or .severity == "minor")' \
    "$STATE_FILE_PATH" 2>/dev/null || true)
else
  FINDINGS_NDJSON=$(jq -c \
    '(.aggregate.criticFindings // [])[]?
     | select(.severity == "major" or .severity == "minor")' \
    "$STATE_FILE_PATH" 2>/dev/null || true)
fi

if [ -z "${FINDINGS_NDJSON:-}" ]; then
  echo "track-findings: 추적할 finding 없음 (source=$FINDING_SOURCE, target=$TARGET_REPO)"
  exit 0
fi

# ── 4. finding 렌더 헬퍼 — render-finding.py 호출 ──
#    finding JSON 한 줄 → stdout: 'fp\t제목\t라벨\t본문(base64)'.
#    AREA 는 critic 모드에서 비어있을 수 있어 ${AREA:-} 로 방어(set -u 안전).
render_finding() {
  FINDING_SOURCE="$FINDING_SOURCE" AREA="${AREA:-}" \
  MAJOR_LABEL="$MAJOR_LABEL" MINOR_LABEL="$MINOR_LABEL" \
  python3 "$RENDER_PY" "$1"
}

# ── 4.5. 라벨 멱등 생성 (버그 #5: 라벨 미존재 시 gh issue create 가 실패 →
#         이슈 0건 침묵 실패) ──
#    대상 레포에 major/minor 라벨이 없으면 --label 붙은 생성이 통째로 실패한다.
#    루프 진입 전에 라벨을 멱등 생성 시도해서 "조용한 죽음"을 예방한다.
#    이미 있으면 에러나지만 무시(|| true) — 멱등.
for L in "$MAJOR_LABEL" "$MINOR_LABEL"; do
  [ -z "$L" ] && continue
  if gh label create "$L" --repo "$TARGET_REPO" >/dev/null 2>&1; then
    echo "track-findings: 라벨 생성 — $L"
  fi
done

# ── 5. 각 finding 처리: intra-run + cross-run dedup → 이슈 생성 ──
SEEN_FPS=""   # intra-run 누적 set (공백 구분 ' <fp> ' 패턴으로 검사)
CREATED=0
SKIPPED=0

while IFS= read -r FINDING_LINE; do
  [ -z "$FINDING_LINE" ] && continue

  # render: 'fp\t제목\t라벨\t본문(base64)'
  RENDERED=$(render_finding "$FINDING_LINE" || true)
  [ -z "$RENDERED" ] && { echo "::warning::track-findings: finding 렌더 실패 — 스킵"; continue; }

  FP=$(printf '%s' "$RENDERED" | cut -f1)
  ISSUE_TITLE=$(printf '%s' "$RENDERED" | cut -f2)
  ISSUE_LABEL=$(printf '%s' "$RENDERED" | cut -f3)
  BODY_B64=$(printf '%s' "$RENDERED" | cut -f4)
  [ -z "$FP" ] && continue

  # intra-run 중복 차단 (같은 run 내 재생성 스킵)
  case " $SEEN_FPS " in
    *" $FP "*)
      echo "track-findings: [$FP] intra-run 중복 — 스킵"
      SKIPPED=$((SKIPPED + 1))
      continue
      ;;
  esac
  SEEN_FPS="$SEEN_FPS $FP"

  # cross-run 중복 차단 — 제목에 박힌 [fp:<fp>] 토큰으로 정확 검색.
  # `gh issue list --search "<fp> in:title"` 는 같은 레포 한정이라
  # `gh search issues` 보다 인덱싱이 빠르고 정확하다.
  # 주의(버그 #7): 그래도 검색 인덱싱 지연·동시 실행 시 드물게 중복 이슈가
  #   생길 수 있다. 코드로 완전 해결 불가 — 드물게 발생하면 수동 정리한다.
  EXISTING=$(gh issue list --repo "$TARGET_REPO" --state open \
    --search "$FP in:title" --json number --jq 'length' 2>/dev/null || echo "0")
  if [ "${EXISTING:-0}" != "0" ]; then
    echo "track-findings: [$FP] 이미 오픈 이슈 존재 — 스킵"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # 이슈 생성 (개별 실패는 흡수 — 나머지를 막지 않음, graceful)
  # base64 decode 실패도 흡수: set -euo pipefail 아래서 그냥 두면 step 이 죽어
  # "모든 실패 흡수" 원칙과 어긋난다 → continue 로 이 finding 만 스킵.
  BODY=$(printf '%s' "$BODY_B64" | base64 --decode) \
    || { echo "::warning::track-findings: [$FP] 본문 디코드 실패 — 이 finding 스킵"; continue; }
  if gh issue create --repo "$TARGET_REPO" \
      --title "$ISSUE_TITLE" \
      --body "$BODY" \
      --label "$ISSUE_LABEL" >/dev/null 2>&1; then
    echo "track-findings: [$FP] 이슈 생성 ($ISSUE_LABEL): $ISSUE_TITLE"
    CREATED=$((CREATED + 1))
  else
    # 버그 #5 폴백: 라벨 미존재 등으로 --label 생성이 실패하면
    #   라벨 없이 1회 재시도해서 이슈는 만들고 라벨만 포기한다.
    #   "조용한 죽음"(이슈 0건)을 막고, 진단 가능한 명확한 경고를 1회 남긴다.
    if gh issue create --repo "$TARGET_REPO" \
        --title "$ISSUE_TITLE" \
        --body "$BODY" >/dev/null 2>&1; then
      echo "::warning::track-findings: [$FP] 라벨($ISSUE_LABEL) 없이 이슈 생성 — 라벨 미존재 추정, install.sh register_labels 확인"
      CREATED=$((CREATED + 1))
    else
      echo "::warning::track-findings: [$FP] 이슈 생성 실패(라벨 무관) — 흡수하고 계속"
    fi
  fi
done <<< "$FINDINGS_NDJSON"

echo "track-findings: 완료 — 생성 $CREATED, 스킵 $SKIPPED (target=$TARGET_REPO)"
exit 0
