#!/usr/bin/env bash
# check-golden.sh — 골든 정답지의 '떠야 하는 필수 키워드' presence 보조 대조기 (이슈 #33, 가벼운 버전).
#
# 무엇인가:
#   critic 산출물 파일에 대해, 골든 정답지(*.expected.md) 끝의 `<!-- golden-check ... -->`
#   마커에 적힌 '떠야 하는(must-appear) 필수 키워드'가 등장하는지 기계적으로 확인한다.
#   각 항목은 OR 키워드 묶음이며, 하나라도 산출물에 있으면 ✅.
#
# ⚠️ 이 도구는 사람 판정 '보조'지 '대체'가 아니다:
#   - '안 떠야(N급)'·프레이밍(회색지대)·H급(사람용 문서)·최종 합격 판정은 자동화 대상이 아니다 — 사람이 본다.
#   - 복합조건(예: 인증없음+노출)·표면 귀속(무인증/인증)은 단순 presence 로 근사할 뿐이라 사람 재확인이 필요하다.
#
# 호출:
#   check-golden.sh <critic-output-file> <expected.md>
#
# 동작:
#   1. expected.md 에서 `<!-- golden-check` ~ `-->` 블록을 추출.
#   2. 블록 안에서 `#` 주석·빈 줄 제외, `ID = kw1 | kw2 | ...` 줄만 파싱.
#   3. 각 항목의 OR 키워드를 critic 산출물에서 고정문자열·대소문자무시로 검색.
#   4. 항목별 ✅/❌ 출력 + 요약.
#
# 종료코드:
#   전부 발견 0, 하나라도 미발견 1.
#   마커가 없거나 항목이 0개면 안내 후 0 (스킵 — precision 표적 픽스처 등은 자동 항목이 없을 수 있음).
#   인자·파일 오류는 2.
#
# 의존: 순수 bash(3.2 호환 지향) + grep 만. yq/jq 미사용. 본체 종속(프로젝트 식별자) 0.

set -uo pipefail

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_DIM='\033[0;90m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_DIM=''; C_NC=''
fi

err() { printf "%berror:%b %s\n" "$C_RED" "$C_NC" "$1" >&2; }

CRITIC_FILE="${1:-}"
EXPECTED_FILE="${2:-}"

if [ -z "$CRITIC_FILE" ] || [ -z "$EXPECTED_FILE" ]; then
  err "사용법: check-golden.sh <critic-output-file> <expected.md>"
  exit 2
fi
if [ ! -f "$CRITIC_FILE" ]; then
  err "critic 산출물 파일 없음: $CRITIC_FILE"
  exit 2
fi
if [ ! -f "$EXPECTED_FILE" ]; then
  err "정답지 파일 없음: $EXPECTED_FILE"
  exit 2
fi

# 헤더 — 이 도구의 위치(보조)를 매 실행 명시.
printf "%b══ golden-check (보조) ══%b\n" "$C_CYAN" "$C_NC"
printf "%b이 도구는 '떠야 하는 키워드' presence 보조일 뿐이다.%b\n" "$C_DIM" "$C_NC"
printf "%bN급(안 떠야)·프레이밍·최종 합격 판정은 사람 몫이다.%b\n" "$C_DIM" "$C_NC"
printf "  critic 산출물: %s\n" "$CRITIC_FILE"
printf "  정답지:       %s\n\n" "$EXPECTED_FILE"

# 1. golden-check 블록 추출 — `<!-- golden-check` 줄 다음부터 `-->` 직전까지.
#    awk 로 상태머신: 시작 마커를 만나면 켜고, 닫는 마커를 만나면 끈다(마커 줄 자체는 출력 안 함).
BLOCK="$(awk '
  /<!-- golden-check/ { ingth=1; next }
  ingth && /-->/      { ingth=0; next }
  ingth               { print }
' "$EXPECTED_FILE")"

if [ -z "$BLOCK" ]; then
  printf "%bℹ 마커 없음 (golden-check 블록 부재) — 자동 보조 스킵.%b\n" "$C_DIM" "$C_NC"
  exit 0
fi

# 2. 항목 파싱 + 3. 검색 + 4. 출력.
#    줄 형식: `ID = kw1 | kw2 | ...`. `#` 시작(앞 공백 허용)·빈 줄은 건너뛴다.
TOTAL=0
FOUND=0
MISSING_IDS=""

# grep 고정문자열 검색 — 발견 시 첫 일치 키워드를 돌려주고 0, 없으면 1.
# (대소문자 무시 -i, 고정문자열 -F: 키워드에 [ ] / # 등 정규식 특수문자가 있어도 안전.)
search_keyword() {
  local kw="$1"
  grep -F -i -q -- "$kw" "$CRITIC_FILE"
}

# IFS 를 개행으로 고정해 한 줄씩 처리(키워드 내부 공백 보존).
OLD_IFS="$IFS"
IFS='
'
for raw_line in $BLOCK; do
  # 앞뒤 공백 트림.
  line="$raw_line"
  # 선행 공백 제거.
  while case "$line" in [[:space:]]*) true;; *) false;; esac; do line="${line# }"; line="${line#	}"; done
  # 주석·빈 줄 스킵.
  case "$line" in
    ''|'#'*) continue ;;
  esac
  # `=` 없으면 항목 줄 아님 → 스킵(방어).
  case "$line" in
    *=*) ;;
    *) continue ;;
  esac

  item_id="${line%%=*}"
  keywords_raw="${line#*=}"
  # ID 양끝 공백 트림.
  item_id="${item_id%"${item_id##*[![:space:]]}"}"
  item_id="${item_id#"${item_id%%[![:space:]]*}"}"

  TOTAL=$((TOTAL + 1))

  # OR 키워드 분해 — 구분자는 ' | '. 각 키워드 양끝 공백 트림 후 검색.
  hit_kw=""
  candidate_list=""
  kwfield="$keywords_raw"
  while [ -n "$kwfield" ]; do
    # 다음 ' | ' 구분자 위치로 한 토큰 잘라냄.
    case "$kwfield" in
      *" | "*)
        kw="${kwfield%% | *}"
        kwfield="${kwfield#* | }"
        ;;
      *)
        kw="$kwfield"
        kwfield=""
        ;;
    esac
    # 키워드 양끝 공백 트림.
    kw="${kw%"${kw##*[![:space:]]}"}"
    kw="${kw#"${kw%%[![:space:]]*}"}"
    [ -z "$kw" ] && continue
    if [ -z "$candidate_list" ]; then candidate_list="$kw"; else candidate_list="$candidate_list|$kw"; fi
    if [ -z "$hit_kw" ] && search_keyword "$kw"; then
      hit_kw="$kw"
      # 첫 일치를 찾았어도 후보 목록은 끝까지 만들기 위해 break 하지 않음.
    fi
  done

  if [ -n "$hit_kw" ]; then
    FOUND=$((FOUND + 1))
    printf "%b✅%b %s → \"%s\" 발견\n" "$C_GREEN" "$C_NC" "$item_id" "$hit_kw"
  else
    printf "%b❌%b %s → 미발견 (후보: %s)\n" "$C_RED" "$C_NC" "$item_id" "$candidate_list"
    if [ -z "$MISSING_IDS" ]; then MISSING_IDS="$item_id"; else MISSING_IDS="$MISSING_IDS $item_id"; fi
  fi
done
IFS="$OLD_IFS"

# 항목이 0개면 스킵(예: precision 표적 픽스처는 자동 보조 항목이 없을 수 있음).
if [ "$TOTAL" -eq 0 ]; then
  printf "%bℹ 마커는 있으나 자동 보조 항목이 0개 — 스킵 (N급·프레이밍 중심 픽스처일 수 있음, 사람 판정).%b\n" "$C_DIM" "$C_NC"
  exit 0
fi

printf "\n%b── 요약 ──%b\n" "$C_CYAN" "$C_NC"
printf "발견 %d/%d\n" "$FOUND" "$TOTAL"
if [ -n "$MISSING_IDS" ]; then
  printf "%b미발견: %s%b\n" "$C_RED" "$MISSING_IDS" "$C_NC"
  printf "%b(미발견이라도 최종 합격은 사람 판정 — 표면 귀속·복합조건은 presence 로 못 본다.)%b\n" "$C_DIM" "$C_NC"
  exit 1
fi
printf "%b전부 발견%b\n" "$C_GREEN" "$C_NC"
exit 0
