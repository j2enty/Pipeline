#!/usr/bin/env bash
# resolve-review-statefile.sh — "이번 /review 실행이 쓴 상태파일"을 결정적으로 식별
#
# 배경:
#   critic 경로(critic-dispatch.yml → parse-critic-verdict.sh)와 review 계열 yml 은 self-hosted 공유 디렉토리
#   ($VERDICT_STATE_DIR = working-directory/.pipeline/state/reviews)에서
#   "이번 실행이 쓴 상태파일(.pipeline/state/reviews/<slug>.json)"을 직접 알 방법이 없어
#   .parent.url 매칭 + marker(-nt)로 "추측"해 왔다(이슈 #9의 구조적 약점).
#
#   이 스크립트는 그 식별 로직을 한 곳으로 추출해 결정적으로 만들고 단위테스트한다.
#   /review 가 종료 직전 자기가 쓴 상태파일의 절대경로를 sentinel 파일에 한 줄 기록하면
#   (REVIEW_STATE_SENTINEL 환경변수로 경로 주입), 여기서는 그 sentinel 을 "신뢰"한다.
#   sentinel 이 없거나 무효이면(로컬 실행·구버전 /review 등) 기존 추측매칭으로 폴백한다
#   → 하위호환 + fail-closed 보존.
#
# 사용법:
#   resolve-review-statefile.sh <mode>
#     <mode> = critic | single
#
# 환경변수(입력):
#   VERDICT_STATE_DIR     상태파일 디렉토리 (필수)
#   PARENT_URL            critic 모드: 기대하는 parent issue URL (critic 필수)
#   PR_REPO               single 모드: PR 레포 (owner/repo 또는 repo). single 필수
#   PR_NUMBER             single 모드: PR 번호. single 필수
#   REVIEW_STATE_SENTINEL sentinel 파일 절대경로 (옵션 — 있으면 신뢰 우선)
#
# 출력(stdout):
#   성공 — 식별된 상태파일의 절대경로 한 줄
#   실패(indeterminate) — 빈 출력 + 비0 종료코드
#
# 종료코드:
#   0  상태파일을 결정적으로 식별
#   1  식별 불능(indeterminate) — 호출자는 fail-closed 처리(머지 차단 등)
#   2  잘못된 인자/환경(모드 누락, 필수 env 누락)
#
# 우선순위(설계):
#   ① REVIEW_STATE_SENTINEL 존재 + 그 파일 존재 + 내용(절대경로)이 실존 .json
#      → 그 경로 채택. 단 critic 모드는 그 파일의 .parent.url 이 기대 PARENT_URL 과
#        일치하는지 교차검증(불일치 = 오염 → indeterminate, fail-closed).
#   ② sentinel 없음/무효 → 폴백:
#      - critic : .parent.url == PARENT_URL 정확매칭(jq, 부분매칭 금지)이 "정확히 1개"
#      - single : pr-<repo>-<number>.json 파일명 구성 + 존재 확인
#   ③ 둘 다 실패 → 빈 출력 + exit 1 (indeterminate)
#
# fail-closed 보존:
#   폴백 critic 경로는 기존 critic.yml 의 방어(정확매칭·단일강제)를 그대로 유지한다.
#   0개/복수 매칭은 indeterminate. sentinel 의 parent.url 교차검증으로 오염 sentinel 차단.
#   (marker -nt stale 검증은 호출자(parse-critic-verdict.sh)가 계속 담당 — 이 스크립트는 "어느 파일"만 결정.)

set -uo pipefail

MODE="${1:-}"

# 절대경로 정규화 — 디렉토리/파일을 안전하게 절대경로화.
# [수정 5-b] realpath -m が있으면 '..'·심볼릭 정규화까지 수행한다.
# 없는 환경(macOS 기본 BSD realpath 는 -m 미지원)에서는 기존 cd+pwd 방식으로 폴백.
# 한계: cd+pwd 는 '..' 를 완전 정규화하지 못하는 경우가 있다 — realpath 권장 환경은
# GNU coreutils(ubuntu-latest runner 포함)이므로 self-hosted macOS 에서만 기존 방식 사용.
to_abs_path() {
  local p="$1"
  if realpath -m "$p" 2>/dev/null; then
    return
  fi
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *)  printf '%s\n' "$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;;
  esac
}

# ── 인자/환경 검증 ───────────────────────────────────────────
case "$MODE" in
  critic|single) ;;
  *)
    echo "resolve-review-statefile.sh: 모드 인자 필요 (critic|single)" >&2
    exit 2
    ;;
esac

VERDICT_STATE_DIR="${VERDICT_STATE_DIR:-}"
if [ -z "$VERDICT_STATE_DIR" ]; then
  echo "resolve-review-statefile.sh: VERDICT_STATE_DIR 환경변수 필요" >&2
  exit 2
fi

if [ "$MODE" = "critic" ]; then
  PARENT_URL="${PARENT_URL:-}"
  if [ -z "$PARENT_URL" ]; then
    echo "resolve-review-statefile.sh: critic 모드는 PARENT_URL 필요" >&2
    exit 2
  fi
else
  PR_REPO="${PR_REPO:-}"
  PR_NUMBER="${PR_NUMBER:-}"
  if [ -z "$PR_REPO" ] || [ -z "$PR_NUMBER" ]; then
    echo "resolve-review-statefile.sh: single 모드는 PR_REPO·PR_NUMBER 필요" >&2
    exit 2
  fi
fi

SENTINEL="${REVIEW_STATE_SENTINEL:-}"

# ── ① sentinel 신뢰 경로 ─────────────────────────────────────
if [ -n "$SENTINEL" ] && [ -f "$SENTINEL" ]; then
  # sentinel 첫 줄 = /review 가 기록한 상태파일 절대경로.
  # [수정 5-a / xargs 제거] CRLF 환경(Windows runner 등)에서 기록된 sentinel 을
  # Linux runner 가 읽을 때 후행 '\r' 이 경로에 붙어 파일 탐색에 조용히 실패하는 사고 방지.
  # IFS= read -r 로 단어분할·glob 없이 한 줄을 읽고, tr -d '\r' 로 CR 만 제거한다.
  # 양끝 공백 제거에 xargs 를 쓰면 경로 중간 공백·quote·backslash 를 shell 토큰으로
  # 해석해 경로가 변형되거나 빈 값이 된다 — 경로 내부 공백 보존을 위해 xargs 사용 금지.
  # 양끝 공백은 셸 파라미터 확장으로 제거(경로 내부 공백 불변).
  IFS= read -r SENTINEL_TARGET < "$SENTINEL" 2>/dev/null || SENTINEL_TARGET=""
  SENTINEL_TARGET="$(printf '%s' "$SENTINEL_TARGET" | tr -d '\r')"
  # 앞쪽 공백 제거
  while [ "${SENTINEL_TARGET#[[:space:]]}" != "$SENTINEL_TARGET" ]; do
    SENTINEL_TARGET="${SENTINEL_TARGET#[[:space:]]}"
  done
  # 뒤쪽 공백 제거
  while [ "${SENTINEL_TARGET%[[:space:]]}" != "$SENTINEL_TARGET" ]; do
    SENTINEL_TARGET="${SENTINEL_TARGET%[[:space:]]}"
  done
  if [ -n "$SENTINEL_TARGET" ] && [ -f "$SENTINEL_TARGET" ]; then
    case "$SENTINEL_TARGET" in
      *.json)
        if [ "$MODE" = "critic" ]; then
          # critic 모드 교차검증: sentinel 이 가리킨 파일의 .parent.url 이
          # 기대 PARENT_URL 과 정확히 일치해야 한다(오염 sentinel 차단 — fail-closed).
          SENTINEL_PARENT="$(jq -r '.parent.url // empty' "$SENTINEL_TARGET" 2>/dev/null || true)"
          if [ "$SENTINEL_PARENT" = "$PARENT_URL" ]; then
            to_abs_path "$SENTINEL_TARGET"
            exit 0
          fi
          # 불일치 → 폴백으로 떨어지지 않고 indeterminate(fail-closed). 동작은 한 가지(머지 차단)지만
          # 원인을 구분해 로그를 다르게 낸다: (a) .parent 가 비어있음(미기록) vs (b) 값이 다름(진짜 오염).
          if [ -z "$SENTINEL_PARENT" ]; then
            # (a) 미기록 — review(생산자)가 5-a parent write 를 안 돌려 .parent 가 null 로 남은 경우(#94).
            echo "resolve-review-statefile.sh: sentinel 이 가리킨 상태파일의 .parent 가 비어있음(미기록) — review 가 parent 를 안 쓴 것으로 의심(#94), indeterminate" >&2
          else
            # (b) 진짜 오염 — .parent.url 에 값은 있으나 기대 PARENT_URL 과 다른 경우.
            echo "resolve-review-statefile.sh: sentinel 의 .parent.url($SENTINEL_PARENT) 가 기대 PARENT_URL($PARENT_URL) 과 불일치 — 오염 의심, indeterminate" >&2
          fi
          exit 1
        else
          # [수정 3] single 모드 sentinel 교차검증 — basename 이 기대 파일명과 일치해야 채택.
          # 기존: 경로 존재만으로 신뢰 → 오염 sentinel(다른 PR 의 파일을 가리킴)이 그대로 통과.
          # 수정: sentinel 이 가리킨 파일의 basename 이 "pr-${REPO_NAME}-${PR_NUMBER}.json" 과
          # 정확히 일치해야 채택한다. 불일치면 폴백하지 않고 indeterminate(fail-closed) — critic
          # 모드 오염 처리와 동일 원칙.
          expected_basename="pr-${PR_REPO##*/}-${PR_NUMBER}.json"
          actual_basename="$(basename "$SENTINEL_TARGET")"
          if [ "$actual_basename" = "$expected_basename" ]; then
            to_abs_path "$SENTINEL_TARGET"
            exit 0
          fi
          echo "resolve-review-statefile.sh: single sentinel basename(${actual_basename}) 이 기대값(${expected_basename}) 과 불일치 — 오염 의심, indeterminate" >&2
          exit 1
        fi
        ;;
      *)
        # .json 이 아니면 무효 → 폴백으로
        :
        ;;
    esac
  fi
  # sentinel 은 있으나 내용이 무효(빈줄·미존재·비json) → 폴백으로 진행(하위호환)
fi

# ── ② 폴백 ───────────────────────────────────────────────────
if [ "$MODE" = "critic" ]; then
  # critic 폴백: .parent.url == PARENT_URL 정확매칭이 "정확히 1개"일 때만 신뢰.
  # jq 정확 비교(grep 부분매칭 금지 — issues/3 이 issues/30 까지 잡는 문제 회피).
  # 0개/복수는 indeterminate(fail-closed).
  MATCH_COUNT=0
  STATE_FILE=""
  if [ -d "$VERDICT_STATE_DIR" ]; then
    for f in "$VERDICT_STATE_DIR"/*.json; do
      [ -f "$f" ] || continue
      if [ "$(jq -r '.parent.url // empty' "$f" 2>/dev/null)" = "$PARENT_URL" ]; then
        MATCH_COUNT=$((MATCH_COUNT + 1))
        STATE_FILE="$f"
      fi
    done
  fi
  if [ "$MATCH_COUNT" -eq 1 ]; then
    to_abs_path "$STATE_FILE"
    exit 0
  fi
  echo "resolve-review-statefile.sh: critic 폴백 — PARENT_URL($PARENT_URL) 매칭 상태파일 $MATCH_COUNT 개(0 또는 2개+), indeterminate" >&2
  exit 1
else
  # single 폴백: pr-<repo>-<number>.json 파일명 구성.
  # PR_REPO 가 owner/repo 형식이면 repo 부분만(슬래시 제거 — 파일명 규약과 일치).
  REPO_NAME="${PR_REPO##*/}"
  CANDIDATE="$VERDICT_STATE_DIR/pr-${REPO_NAME}-${PR_NUMBER}.json"
  if [ -f "$CANDIDATE" ]; then
    to_abs_path "$CANDIDATE"
    exit 0
  fi
  echo "resolve-review-statefile.sh: single 폴백 — 상태파일 없음($CANDIDATE), indeterminate" >&2
  exit 1
fi
