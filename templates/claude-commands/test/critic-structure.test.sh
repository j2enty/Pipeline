#!/usr/bin/env bash
# critic-structure.test.sh — plan.md.tmpl critic 단계(Step 5.5 / 6.5) 정적 분석 테스트.
#
# 목적:
#   Phase B 에서 추가한 ③ 완결성 critic(Step 5.5)·⑤ 정합성 critic(Step 6.5)이
#   구조적으로 올바르게 박혔는지, 설치 시 치환되는 placeholder 가 누락되지 않았는지
#   정적으로 단언한다. (install 불필요 — 원본 plan.md.tmpl 기준)
#
# 검사 항목:
#   (C-1) '### 5.5. ③ 완결성 critic' 헤더 존재
#   (C-2) '__PLAN_COMPLETENESS_CRITIC_ENABLED__' placeholder 존재
#   (C-3) 체크리스트 키워드 'rate limit' 존재
#   (C-4) 체크리스트 키워드 '인터뷰 제약 반영' 존재
#   (C-5) "메우지 말고 분류" 문구 존재
#   (C-6) '#### 6.5. ⑤ 정합성 critic' (또는 '### 6.5.') 헤더 존재
#   (C-7) '__PLAN_CONSISTENCY_CRITIC_ENABLED__' placeholder 존재
#   (C-8) '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' placeholder 존재
#   (C-9) Claude + Codex 이중 모델 분기 설명 존재 ('Codex' 키워드)
#   (C-10) 5.5 단계가 Step 5 이후 Step 6 이전에 위치 (줄번호 순서 검증)
#   (C-DRIFT) install.sh sed_args 에 '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' 존재
#   (C-CONTRACT-1) '__PLAN_CONTRACT_DOC_ENABLED__' 게이트 placeholder 존재
#   (C-CONTRACT-2) contract.md 템플릿 헤더 '# [contract]' + '## API 스키마' + '## 공통 규약' 존재
#   (C-CONTRACT-3) '2개 이상' 영역 조건 + 단일 영역 생략 지시 존재
#   (C-CONTRACT-4) Step 6a 산출 목록에 '<parent-N>-<slug>-contract.md' 존재
#   (C-CONTRACT-5) planner 프롬프트에 '계약 참조'(다시 정의 금지) 지시 존재

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${TEMPLATE:-$TEST_DIR/../plan.md.tmpl}"
# 본체 install.sh — placeholder 치환 누락(drift) 검사용
INSTALL_SH="${INSTALL_SH:-$TEST_DIR/../../../scripts/install.sh}"

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

printf "${C_CYAN}══ critic 단계 구조 정적 분석 (%s) ══${C_NC}\n\n" "$(basename "$TEMPLATE")"

# ── (C-1) ③ 완결성 critic 헤더 존재 ──────────────────────────────────────────
if grep -q "### 5.5. ③ 완결성 critic" "$TEMPLATE"; then
  pass "(C-1) '### 5.5. ③ 완결성 critic' 헤더 존재"
else
  fail "(C-1) '### 5.5. ③ 완결성 critic' 헤더 없음"
fi

# ── (C-2) 완결성 critic enable placeholder ────────────────────────────────────
if grep -q "__PLAN_COMPLETENESS_CRITIC_ENABLED__" "$TEMPLATE"; then
  pass "(C-2) '__PLAN_COMPLETENESS_CRITIC_ENABLED__' placeholder 존재"
else
  fail "(C-2) '__PLAN_COMPLETENESS_CRITIC_ENABLED__' placeholder 없음"
fi

# ── (C-3) 체크리스트 'rate limit' ────────────────────────────────────────────
if grep -q "rate limit" "$TEMPLATE"; then
  pass "(C-3) 체크리스트 키워드 'rate limit' 존재"
else
  fail "(C-3) 체크리스트 키워드 'rate limit' 없음"
fi

# ── (C-4) 체크리스트 '인터뷰 제약 반영' ──────────────────────────────────────
if grep -q "인터뷰 제약 반영" "$TEMPLATE"; then
  pass "(C-4) 체크리스트 키워드 '인터뷰 제약 반영' 존재"
else
  fail "(C-4) 체크리스트 키워드 '인터뷰 제약 반영' 없음"
fi

# ── (C-5) "메우지 말고 분류" 문구 ────────────────────────────────────────────
if grep -q "메우지 말고 분류" "$TEMPLATE"; then
  pass "(C-5) '메우지 말고 분류' 문구 존재"
else
  fail "(C-5) '메우지 말고 분류' 문구 없음"
fi

# ── (C-6) ⑤ 정합성 critic 헤더 존재 (### 또는 #### 허용) ─────────────────────
if grep -qE "^#{3,4} 6\.5\. ⑤ 정합성 critic" "$TEMPLATE"; then
  pass "(C-6) '6.5. ⑤ 정합성 critic' 헤더 존재"
else
  fail "(C-6) '6.5. ⑤ 정합성 critic' 헤더 없음"
fi

# ── (C-7) 정합성 critic enable placeholder ───────────────────────────────────
if grep -q "__PLAN_CONSISTENCY_CRITIC_ENABLED__" "$TEMPLATE"; then
  pass "(C-7) '__PLAN_CONSISTENCY_CRITIC_ENABLED__' placeholder 존재"
else
  fail "(C-7) '__PLAN_CONSISTENCY_CRITIC_ENABLED__' placeholder 없음"
fi

# ── (C-8) 정합성 critic dual-model placeholder ───────────────────────────────
if grep -q "__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__" "$TEMPLATE"; then
  pass "(C-8) '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' placeholder 존재"
else
  fail "(C-8) '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' placeholder 없음"
fi

# ── (C-9) Claude + Codex 이중 모델 분기 설명 ─────────────────────────────────
if grep -q "Codex" "$TEMPLATE"; then
  pass "(C-9) Claude + Codex 이중 모델 분기 설명 존재 ('Codex' 키워드)"
else
  fail "(C-9) 이중 모델 분기 설명 없음 — 'Codex' 키워드 필요"
fi

# ── (C-10) 5.5 단계가 Step 5 이후 Step 6 이전에 위치 (줄번호 순서) ────────────
# 'line5'  = Step 5 헤더 줄번호
# 'line55' = Step 5.5 critic 헤더 줄번호
# 'line6'  = Step 6 헤더 줄번호
# 기대 순서: line5 < line55 < line6
line5="$(grep -nE "^### 5\. " "$TEMPLATE" | head -1 | cut -d: -f1)"
line55="$(grep -n "### 5.5. ③ 완결성 critic" "$TEMPLATE" | head -1 | cut -d: -f1)"
line6="$(grep -nE "^### 6\. 문서 저장" "$TEMPLATE" | head -1 | cut -d: -f1)"
if [ -n "$line5" ] && [ -n "$line55" ] && [ -n "$line6" ] \
   && [ "$line5" -lt "$line55" ] && [ "$line55" -lt "$line6" ]; then
  pass "(C-10) 5.5 단계 위치 정상 (Step 5[$line5] < 5.5[$line55] < Step 6[$line6])"
else
  fail "(C-10) 5.5 단계 위치 비정상 (Step 5='$line5' / 5.5='$line55' / Step 6='$line6')"
fi

# ── (C-DRIFT) install.sh sed_args 에 dual-model placeholder 치환 줄 존재 ──────
# 템플릿에 placeholder 가 있는데 install.sh 가 치환하지 않으면 런타임에 그대로 노출됨.
if [ ! -f "$INSTALL_SH" ]; then
  fail "(C-DRIFT) install.sh 파일 없음: $INSTALL_SH"
elif grep -q "__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__" "$INSTALL_SH"; then
  pass "(C-DRIFT) install.sh 가 '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' 치환함"
else
  fail "(C-DRIFT) install.sh sed_args 에 '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' 치환 줄 없음"
fi

# ── (C-CONTRACT-1) contract 게이트 placeholder 존재 ──────────────────────────
if grep -q "__PLAN_CONTRACT_DOC_ENABLED__" "$TEMPLATE"; then
  pass "(C-CONTRACT-1) '__PLAN_CONTRACT_DOC_ENABLED__' placeholder 존재"
else
  fail "(C-CONTRACT-1) '__PLAN_CONTRACT_DOC_ENABLED__' placeholder 없음"
fi

# ── (C-CONTRACT-2) contract.md 템플릿 헤더·필수 섹션 존재 ────────────────────
if grep -q "# \[contract\]" "$TEMPLATE" \
   && grep -q "## API 스키마" "$TEMPLATE" \
   && grep -q "## 공통 규약" "$TEMPLATE"; then
  pass "(C-CONTRACT-2) contract.md 템플릿 헤더 '# [contract]' + '## API 스키마' + '## 공통 규약' 존재"
else
  fail "(C-CONTRACT-2) contract.md 템플릿 헤더 또는 필수 섹션 누락"
fi

# ── (C-CONTRACT-3) '2개 이상' 영역 조건 + 단일 영역 생략 지시 존재 ────────────
if grep -q "2개 이상" "$TEMPLATE" \
   && grep -q "1개뿐이면" "$TEMPLATE"; then
  pass "(C-CONTRACT-3) '2개 이상' 영역 조건 + 단일 영역 생략 지시 존재"
else
  fail "(C-CONTRACT-3) '2개 이상' 조건 또는 단일 영역 생략 지시 누락"
fi

# ── (C-CONTRACT-4) Step 6a 산출 목록에 contract.md 존재 ──────────────────────
if grep -q "<parent-N>-<slug>-contract.md" "$TEMPLATE"; then
  pass "(C-CONTRACT-4) Step 6a 산출 목록에 '<parent-N>-<slug>-contract.md' 존재"
else
  fail "(C-CONTRACT-4) Step 6a 산출 목록에 '<parent-N>-<slug>-contract.md' 없음"
fi

# ── (C-CONTRACT-5) planner 프롬프트에 '계약 참조' 지시 존재 ──────────────────
if grep -q "계약 참조" "$TEMPLATE" \
   && grep -q "다시 정의" "$TEMPLATE"; then
  pass "(C-CONTRACT-5) planner 프롬프트에 '계약 참조'(다시 정의 금지) 지시 존재"
else
  fail "(C-CONTRACT-5) planner 프롬프트에 '계약 참조' 또는 '다시 정의' 금지 지시 누락"
fi

# ── 집계 ─────────────────────────────────────────────────────────────────────
printf "\n${C_CYAN}══════════════════════════════${C_NC}\n"
if [ "$FAILED" -eq 0 ]; then
  printf "${C_GREEN}전체 PASS — critic 단계 구조 완결성 확인${C_NC}\n"
  exit 0
else
  printf "${C_RED}FAIL — 위 항목을 수정할 것${C_NC}\n"
  exit 1
fi
