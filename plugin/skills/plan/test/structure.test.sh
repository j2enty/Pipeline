#!/usr/bin/env bash
# structure.test.sh — /pipeline:plan skill 구조 정적 분석 테스트 (P2).
#
# plan.md.tmpl → SKILL.md 변환의 불변식을 단언한다:
#   (A) skill 변환 불변식: placeholder 0, oh-my-claudecode ref(codex 폴백 외) 0,
#       pipeline:planner·critic(완결성·정합성 모드) 호출, 토글 config 읽기,
#       disable-model-invocation, config 리더(--dump) 주입.
#   (B) 이동한 내용 보존: critic 체크리스트→pipeline:critic 에이전트,
#       인터뷰 7구간·템플릿→reference/.
#   (C) dry-run 안전 가드: 기존 dry-run-guard.test.sh 를 SKILL.md 에 겨냥해 재사용.
#
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$TEST_DIR/../SKILL.md"
REF="$TEST_DIR/../reference"
CRITIC_AGENT="$TEST_DIR/../../../agents/critic.md"
PLANNER_AGENT="$TEST_DIR/../../../agents/planner.md"
DRY_RUN_GUARD="$TEST_DIR/../../../../templates/claude-commands/test/dry-run-guard.test.sh"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${C_RED}✗${C_NC} %s\n" "$1" >&2; }

# grep 존재/부재 단언
has()  { if grep -q "$1" "$2"; then pass "$3"; else fail "$3"; fi; }
hasE() { if grep -Eq "$1" "$2"; then pass "$3"; else fail "$3"; fi; }
absent() { if grep -q "$1" "$2"; then fail "$3"; else pass "$3"; fi; }

echo ""
echo -e "${C_CYAN}══ /pipeline:plan skill 구조 테스트 (P2) ══${C_NC}"

[ -f "$SKILL" ] || { fail "SKILL.md 존재"; echo "통과 0 실패 1"; exit 1; }

echo -e "\n${C_CYAN}── (A) skill 변환 불변식 ──${C_NC}"
# A-1 placeholder 0
if grep -qoE '__[A-Z_]+__' "$SKILL"; then fail "(A-1) SKILL.md placeholder 0"; else pass "(A-1) SKILL.md placeholder 0"; fi
if grep -rqoE '__[A-Z_]+__' "$REF"; then fail "(A-1) reference/ placeholder 0"; else pass "(A-1) reference/ placeholder 0"; fi

# A-2 oh-my-claudecode ref: codex ask(폴백) 외 0
omc_non_codex="$(grep -nE 'oh-my-claudecode' "$SKILL" | grep -vE 'ask.*codex|오케스트레이터가 없는' || true)"
if [ -z "$omc_non_codex" ]; then pass "(A-2) oh-my-claudecode ref 는 codex 폴백뿐(planner/critic 스왑 완료)"; else fail "(A-2) oh-my-claudecode 잔존: $omc_non_codex"; fi

# A-3 pipeline 에이전트 호출
has 'subagent_type="pipeline:planner"' "$SKILL" "(A-3) pipeline:planner 호출"
has 'subagent_type="pipeline:critic"' "$SKILL" "(A-3) pipeline:critic 호출"
has '완결성 모드' "$SKILL" "(A-4) critic 완결성 모드 키워드"
has '정합성 모드' "$SKILL" "(A-4) critic 정합성 모드 키워드"

# A-5 토글 config 읽기 (4종)
for tg in plan.completeness-critic-enabled plan.consistency-critic-enabled \
          plan.consistency-critic-dual-model plan.contract-doc-enabled; do
  has "\"\$CFG\" $tg" "$SKILL" "(A-5) 토글 런타임 읽기: $tg"
done

# A-6 frontmatter disable-model-invocation
has 'disable-model-invocation: true' "$SKILL" "(A-6) disable-model-invocation: true (사람 전용)"

# A-7 config 리더 주입 (--dump) + CFG 정의
has 'pipeline-config.sh" --dump' "$SKILL" "(A-7) --dump 주입(프로젝트 설정 인지)"
has 'CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"' "$SKILL" "(A-7) CFG 리더 경로 정의"

# A-8 reference 4종 링크 + 파일 존재
for rf in interview-guide contract-template requirements-template design-placeholder-template; do
  has "reference/$rf.md" "$SKILL" "(A-8) reference 링크: $rf"
  if [ -f "$REF/$rf.md" ]; then pass "(A-8) reference 파일 존재: $rf.md"; else fail "(A-8) reference 파일 없음: $rf.md"; fi
done

echo -e "\n${C_CYAN}── (B) 이동한 내용 보존 ──${C_NC}"
# B-1 critic 체크리스트 → pipeline:critic 에이전트 (skill 에서 빠진 게 사라진 게 아님)
has '메우지 말고 분류' "$CRITIC_AGENT" "(B-1) '메우지 말고 분류' → critic 에이전트"
has 'rate limit' "$CRITIC_AGENT" "(B-1) 'rate limit' 보안룰 → critic 에이전트"
# 원본 체크리스트 라벨 '인터뷰 제약 반영'은 에이전트에서 '제약 반영: …인터뷰…'로 승격됨(의미 동일).
has '제약 반영' "$CRITIC_AGENT" "(B-1) '제약 반영'(인터뷰 제약) → critic 에이전트"
# B-2 인터뷰 7구간 → reference/interview-guide.md
IG="$REF/interview-guide.md"
hasE '3\.5' "$IG" "(B-2) 인터뷰 3.5번(접근법) → interview-guide"
has 'Heilmeier' "$IG" "(B-2) Heilmeier → interview-guide"
# B-3 사람용 템플릿 섹션 → reference/requirements-template.md
RT="$REF/requirements-template.md"
has '★ 접근법' "$RT" "(B-3) '★ 접근법' → requirements-template"
has '키 피처' "$RT" "(B-3) '키 피처' → requirements-template"
has '이번에 안 하는 것' "$RT" "(B-3) '이번에 안 하는 것' → requirements-template"
# B-4 contract 템플릿 → reference/contract-template.md
CT="$REF/contract-template.md"
has '# \[contract\]' "$CT" "(B-4) contract 헤더 → contract-template"
has '## API 스키마' "$CT" "(B-4) '## API 스키마' → contract-template"
has '## 공통 규약' "$CT" "(B-4) '## 공통 규약' → contract-template"

echo -e "\n${C_CYAN}── (C) dry-run 안전 가드 (기존 테스트 재사용) ──${C_NC}"
if [ -f "$DRY_RUN_GUARD" ]; then
  if TEMPLATE="$SKILL" bash "$DRY_RUN_GUARD" >/dev/null 2>&1; then
    pass "(C-1) dry-run-guard.test.sh (TEMPLATE=SKILL.md) 통과"
  else
    fail "(C-1) dry-run-guard.test.sh (TEMPLATE=SKILL.md) 실패 — 안전 가드 훼손"
  fi
else
  fail "(C-1) dry-run-guard.test.sh 없음: $DRY_RUN_GUARD"
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
