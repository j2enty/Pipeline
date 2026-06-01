#!/usr/bin/env bash
# interview-structure.test.sh — plan.md.tmpl 인터뷰 구조 정적 분석 테스트.
#
# 검사 항목:
#   (I-1) 7구간 + 3.5번 전부 존재
#   (I-2) 4번·5번 반드시 물어본다 명시 (스킵 금지)
#   (I-3) deep-interview 스킬 호출 없음 (D6 비종속)
#   (I-4) --deep 모드 스킵 금지 언급 존재
#   (I-5) --bot 모드 자동 추론 처리 언급 존재
#   (I-6) §3.6 사람용 문서 템플릿 핵심 섹션 존재
#   (I-7) 접근법 슬롯 (3.5번 → 결정할 것) 존재

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${TEMPLATE:-$TEST_DIR/../plan.md.tmpl}"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

FAILED=0
pass() { printf "${C_GREEN}✓ PASS${C_NC} %s\n" "$1"; }
fail() { printf "${C_RED}✗ FAIL${C_NC} %s\n" "$1"; FAILED=1; }

if [ ! -f "$TEMPLATE" ]; then
  printf "${C_RED}✗ 템플릿 파일 없음: %s${C_NC}\n" "$TEMPLATE"
  exit 1
fi

printf "${C_CYAN}══ 인터뷰 구조 정적 분석 (%s) ══${C_NC}\n\n" "$(basename "$TEMPLATE")"

# ── (I-1) 7구간 + 3.5번 전부 존재 ─────────────────────────────────────────────
segments_ok=true

check_segment() {
  local label="$1" pattern="$2"
  if ! grep -q "$pattern" "$TEMPLATE"; then
    fail "(I-1) 인터뷰 구간 누락: $label"
    segments_ok=false
  fi
}

check_segment "1번(만들려는)" "뭘 만들려는"
check_segment "2번(불편해요)" "뭐가 불편해요"
check_segment "3번(누가 써요)" "누가 써요"
check_segment "3.5번(접근법 — '생각해둔 방식')" "생각해둔 방식"
check_segment "4번(안 해요)" "뭘 '안' 해요"
check_segment "5번(표준 제약)" "표준 제약"
check_segment "6번(위험한)" "제일 위험한"
check_segment "7번(출시했다)" "출시했다 치고"

[ "$segments_ok" = true ] && pass "(I-1) 인터뷰 7구간 + 3.5번 전부 존재"

# ── (I-2) 4번·5번 반드시 물어본다 (스킵 금지) 명시 ────────────────────────────
if grep -q "4번.*5번.*반드시\|반드시.*4번.*5번" "$TEMPLATE"; then
  pass "(I-2) 4번·5번 스킵 금지 (반드시 물어본다) 명시"
else
  fail "(I-2) 4번·5번 스킵 금지 명시 없음 — '4번·5번은 반드시 물어본다' 필요"
fi

# 4번과 5번 각각 '스킵 금지' 표시 확인
if grep -q "4\..*스킵 금지\|스킵 금지.*4\." "$TEMPLATE"; then
  pass "(I-2) 4번 항목 옆 스킵 금지 표시"
else
  fail "(I-2) 4번 항목 옆 스킵 금지 표시 없음"
fi

if grep -q "5\..*스킵 금지\|스킵 금지.*5\." "$TEMPLATE"; then
  pass "(I-2) 5번 항목 옆 스킵 금지 표시"
else
  fail "(I-2) 5번 항목 옆 스킵 금지 표시 없음"
fi

# ── (I-3) deep-interview 스킬 호출 없음 (D6 비종속) ───────────────────────────
if grep -q "deep-interview" "$TEMPLATE"; then
  fail "(I-3) D6 위반: deep-interview 스킬 호출 잔존"
else
  pass "(I-3) deep-interview 스킬 호출 없음 (D6 비종속 확인)"
fi

# ── (I-4) --deep 모드 스킵 금지 언급 ──────────────────────────────────────────
if grep -q "\-\-deep.*스킵 금지\|스킵 금지.*\-\-deep" "$TEMPLATE"; then
  pass "(I-4) --deep 모드 스킵 금지 언급 존재"
else
  fail "(I-4) --deep 모드 스킵 금지 언급 없음"
fi

# ── (I-5) --bot 모드 자동 추론 처리 언급 ──────────────────────────────────────
if grep -q "\-\-bot.*자동\|자동.*\-\-bot" "$TEMPLATE"; then
  pass "(I-5) --bot 모드 자동 추론 처리 언급 존재"
else
  fail "(I-5) --bot 모드 자동 추론 처리 언급 없음"
fi

# ── (I-6) §3.6 사람용 문서 템플릿 코드블록 내 핵심 섹션 존재 ──────────────────
# 코드블록(```markdown ... ```) 안에 실제 섹션 헤더가 있는지 확인
# '## 당신이 결정할 것' 패턴은 인터뷰 설명에도 없고 코드블록에서만 나옴
for section in "## 당신이 결정할 것" "## 이번에 안 하는 것" "## 키 피처" "## 리스크"; do
  if grep -q "$section" "$TEMPLATE"; then
    pass "(I-6) 사람용 템플릿 섹션 존재: '$section'"
  else
    fail "(I-6) 사람용 템플릿 섹션 누락: '$section'"
  fi
done

# ── (I-7) 접근법 슬롯이 결정할 것 섹션 안에 실제로 있는지 ────────────────────
# '★ 접근법:' 은 인터뷰 설명(→ 사람용 "★ 결정할 것")과 구분되는 템플릿 전용 패턴
if grep -q "★ 접근법:" "$TEMPLATE"; then
  pass "(I-7) 접근법 결정 슬롯 (★ 접근법:) 존재"
else
  fail "(I-7) 접근법 결정 슬롯 없음 — requirements 템플릿의 '★ 접근법:' 항목 필요"
fi

# ── 집계 ─────────────────────────────────────────────────────────────────────
printf "\n${C_CYAN}══════════════════════════════${C_NC}\n"
if [ "$FAILED" -eq 0 ]; then
  printf "${C_GREEN}전체 PASS — 인터뷰 구조 완결성 확인${C_NC}\n"
  exit 0
else
  printf "${C_RED}FAIL — 위 항목을 수정할 것${C_NC}\n"
  exit 1
fi
