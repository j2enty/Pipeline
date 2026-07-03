#!/usr/bin/env bash
# structure.test.sh — /pipeline:plan skill 구조 정적 분석 테스트 (P2).
#
# SKILL.md 가 가져야 할 구조 불변식을 단언한다(P3.1: 배포 SSOT 가 SKILL.md 로 일원화돼
# templates/claude-commands/ 의존을 제거함. dry-run 가드 분석기도 plugin 내부 사본 사용):
#   (A) skill 변환 불변식: placeholder 0, oh-my-claudecode ref 0(P3.5: codex 폴백도
#       범용 pipeline:ask 에이전트로 대체 — 완전 탈종속),
#       pipeline:planner·critic(완결성·정합성 모드)·ask(교차검증 best-effort) 호출, 토글 config 읽기,
#       disable-model-invocation, config 리더(--dump) 주입,
#       모듈 동작은 리더 인터페이스(--modules-table/--modules-where planner, default-status·
#       cross-area-group·area-id 플래그)로 읽음 — 모듈명·Status 하드코딩 제거(#42).
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
# (P3.1) dry-run 가드 분석기는 plugin 내부 사본 사용 — templates/claude-commands/ 제거(P3.4)에 비의존.
DRY_RUN_GUARD="$TEST_DIR/dry-run-guard.lib.sh"

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
# absentE — 확장정규식(grep -E) 부재 단언. (P3.5 전까지 정의 누락으로 A-2/A-9b/A-9c 가
#  command-not-found 로 조용히 no-op 되던 것을 정의 추가로 실제 실행되게 함.)
absentE() { if grep -Eq "$1" "$2"; then fail "$3"; else pass "$3"; fi; }

echo ""
echo -e "${C_CYAN}══ /pipeline:plan skill 구조 테스트 (P2) ══${C_NC}"

[ -f "$SKILL" ] || { fail "SKILL.md 존재"; echo "통과 0 실패 1"; exit 1; }

echo -e "\n${C_CYAN}── (A) skill 변환 불변식 ──${C_NC}"
# A-1 placeholder 0
if grep -qoE '__[A-Z_]+__' "$SKILL"; then fail "(A-1) SKILL.md placeholder 0"; else pass "(A-1) SKILL.md placeholder 0"; fi
if grep -rqoE '__[A-Z_]+__' "$REF"; then fail "(A-1) reference/ placeholder 0"; else pass "(A-1) reference/ placeholder 0"; fi

# A-2 oh-my-claudecode ref 0 (P3.5: codex 폴백도 범용 pipeline:ask 에이전트로 대체 — 완전 0)
absentE 'oh-my-claudecode' "$SKILL" "(A-2) SKILL.md oh-my-claudecode ref 0"
if grep -rqE 'oh-my-claudecode' "$REF"; then fail "(A-2) reference/ oh-my-claudecode ref 0"; else pass "(A-2) reference/ oh-my-claudecode ref 0"; fi

# A-3 pipeline 에이전트 호출
has 'subagent_type="pipeline:planner"' "$SKILL" "(A-3) pipeline:planner 호출"
has 'subagent_type="pipeline:critic"' "$SKILL" "(A-3) pipeline:critic 호출"
# P3.5: codex 교차검증을 범용 pipeline:ask 에이전트로 best-effort 호출 (OMC ask 대체)
has 'subagent_type="pipeline:ask"' "$SKILL" "(A-3) pipeline:ask 호출(2차 교차검증, best-effort)"
absent 'subagent_type="pipeline:cross-check"' "$SKILL" "(A-3) pipeline:cross-check 에이전트 잔재 0(ask 로 일반화)"
has '"$CFG" cross-check-tool' "$SKILL" "(A-3) cross-check-tool 런타임 읽기(도구명 주입 — config 키는 유지)"
# #83: 교차검증 모델·effort 도 통합 키(codex-model·codex-reasoning-effort)로 config 주입 → ask 프롬프트 전달
has '"$CFG" codex-model' "$SKILL" "(A-3) codex-model 런타임 읽기(교차검증 모델 주입 — 통합 키)"
has '"$CFG" codex-reasoning-effort' "$SKILL" "(A-3) codex-reasoning-effort 런타임 읽기(교차검증 effort 주입)"
has '모델=\[${MODEL}\]' "$SKILL" "(A-3) ask 프롬프트에 모델 전달(대괄호 경계 — codex-model → pipeline:ask)"
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

# A-9 모듈 동작은 리더 인터페이스로 읽음 (#42 — 모듈명·Status 하드코딩 제거).
#   planner 스킵·Cross-area 트리거·default-status·area-id 분기가 특정 모듈명이 아니라 플래그로.
has '"$CFG" --modules-table' "$SKILL" "(A-9) --modules-table 동작표 읽기"
hasE '"\$CFG" --modules-where planner=false' "$SKILL" "(A-9) planner=false 모듈 placeholder 분기"
hasE 'module\.<[^>]+>\.default-status|"\$CFG" "module\.<area>\.default-status"' "$SKILL" "(A-9) default-status 플래그로 Status 결정"
hasE 'module\.<[^>]+>\.cross-area-group|cross-area-group 값' "$SKILL" "(A-9) Cross-area 는 cross-area-group 값 동일성으로 판정"
hasE 'module\.<[^>]+>\.area-id|--modules-table.*area-id|area-id 컬럼' "$SKILL" "(A-9) area-id 는 모듈 동작표/플래그로"
# A-9b area-id 개별 6종 호출(하드코딩) 부재 — 특정 모듈명에 묶인 area-id.<이름> 호출이 없어야 함.
absentE '"\$CFG" area-id\.(Backend|Admin|Frontend|iOS|Android|Design)' "$SKILL" "(A-9b) 모듈명 area-id.<이름> 개별호출 부재(하드코딩 제거)"
# A-9c default-status 분기에 'Backlog' 리터럴이 동작 분기로 남지 않음(샘플/주석 예시는 허용).
#   "Design은 Backlog" 같은 모듈명-Status 하드코딩 분기 부재.
absentE 'Design.{0,4}Backlog|Backlog.{0,4}Design' "$SKILL" "(A-9c) Design↔Backlog 하드코딩 분기 부재"

# A-8 reference 4종 링크 + 파일 존재
for rf in interview-guide contract-template requirements-template design-placeholder-template; do
  has "reference/$rf.md" "$SKILL" "(A-8) reference 링크: $rf"
  if [ -f "$REF/$rf.md" ]; then pass "(A-8) reference 파일 존재: $rf.md"; else fail "(A-8) reference 파일 없음: $rf.md"; fi
done

echo -e "\n${C_CYAN}── (M) 단계별 계측 (#83) ──${C_NC}"
# M-0 계측 헬퍼 스크립트 존재 + 실행권한.
METRICS_SH="$TEST_DIR/../scripts/plan-metrics.sh"
if [ -x "$METRICS_SH" ]; then pass "(M-0) plan-metrics.sh 존재+실행권한"; else fail "(M-0) plan-metrics.sh 없음/비실행: $METRICS_SH"; fi
# M-1 SKILL.md 가 헬퍼를 참조(경로 주입)하고 mark/report 펜스를 가짐.
has 'scripts/plan-metrics.sh' "$SKILL" "(M-1) SKILL.md 가 plan-metrics.sh 참조"
hasE '"\$METRICS" mark "\$TSV"' "$SKILL" "(M-1) mark 펜스(date 경계 기록) 존재"
hasE '"\$METRICS" report "\$TSV"' "$SKILL" "(M-1) report 펜스(콘솔 집계) 존재"
has 'report-comment' "$SKILL" "(M-1) report-comment(코멘트 박제) 존재"
# M-2 4개 무거운 단계 라벨이 start/end 경계로 박혀 있음 (planner 는 페이즈 경계).
for lbl in planner completeness-critic consistency-critic codex-crosscheck; do
  hasE "mark \"\\\$TSV\" $lbl start" "$SKILL" "(M-2) $lbl start 경계"
  hasE "mark \"\\\$TSV\" $lbl end"   "$SKILL" "(M-2) $lbl end 경계"
done
# M-3 시각은 LLM 추정이 아니라 shell date — 헬퍼가 date +%s 를 쓰는지(스크립트 측).
has 'date +%s' "$METRICS_SH" "(M-3) 헬퍼가 shell date +%s 로 기록(추정 금지)"
# M-4 dry-run 안전: 코멘트 박제는 toggle ON + non-dry-run 게이트 뒤에만.
has 'metrics.usage-tracking-enabled' "$SKILL" "(M-4) 코멘트 박제는 계측 토글로 게이트"
hasE 'case " \$ARGUMENTS " in \*" --dry-run "\*\).*exit 0' "$SKILL" "(M-4) dry-run 이면 코멘트 스킵(표준 self-guard: exit 0)"
# M-5 상태파일 정리(rm) 가 있음.
hasE 'rm -f "\$TSV"' "$SKILL" "(M-5) 상태파일 정리(rm)"
# M-6 첫 펜스에서 reset(truncate) — 잔여 TSV 누적 오염(특히 토큰 합산) 차단.
hasE '"\$METRICS" reset "\$TSV"' "$SKILL" "(M-6) 첫 펜스 reset(잔여 TSV 누적 오염 차단)"

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

echo -e "\n${C_CYAN}── (C) dry-run 안전 가드 (plugin 내부 분석기 재사용) ──${C_NC}"
if [ -f "$DRY_RUN_GUARD" ]; then
  if TEMPLATE="$SKILL" bash "$DRY_RUN_GUARD" >/dev/null 2>&1; then
    pass "(C-1) dry-run-guard.lib.sh (TEMPLATE=SKILL.md) 통과"
  else
    fail "(C-1) dry-run-guard.lib.sh (TEMPLATE=SKILL.md) 실패 — 안전 가드 훼손"
  fi
else
  fail "(C-1) dry-run-guard.lib.sh 없음: $DRY_RUN_GUARD"
fi

# C-2 (정적 회귀 가드, #88): 분석기 소스에 SIGPIPE 취약 패턴이 0건이어야 한다.
#   취약 패턴 = "파이프로 grep 에 넘기는데 grep 이 조용히 조기종료(-q 류/--quiet)하는 형태".
#   pipefail 환경에서 grep 이 첫 매칭에 즉시 종료·파이프를 닫으면, 아직 출력 중이던
#   생산자(printf·echo·cat …)가 SIGPIPE(141)로 죽어 파이프라인 실패로 오판된다(비결정적 CI 실패).
#   → here-string(`grep … <<< "$VAR"`)으로 작성해 파이프 자체를 없애야 한다.
#
#   탐지 정규식은 생산자 무관(printf/echo/cat 등 무엇이 좌변이든)으로 `| grep … -q류/--quiet` 를 잡는다.
#   q 위치 변형(-qE·-Eq)·긴 옵션(--quiet) 포함. `grep -c` 는 입력 전체를 읽어 조기종료가 없으므로
#   (생산자 SIGPIPE 무발생) 일부러 매칭에서 제외한다.
#   한계: 단일 물리줄만 탐지 — 백슬래시 줄연속으로 `| grep -q` 가 다음 줄로 쪼개진 형태는 미탐(줄단위 grep 의 본질적 한계).
SIGPIPE_RE='\| *grep ([^|]* )?(-[A-Za-z]*q[A-Za-z]*|--quiet)'

# C-2a: 가드 정규식 자체 검증 — 양성은 잡고 음성은 안 잡는지(빈 껍데기 가드 방지).
c2_re_ok=1
for c2_pos in \
  'echo "$x" | grep -q foo' \
  "printf '%s' \"\$x\" | grep -qE bar" \
  'cat f | grep --quiet baz'; do
  printf '%s\n' "$c2_pos" | grep -Eq "$SIGPIPE_RE" || { c2_re_ok=0; printf '  양성 미탐: %s\n' "$c2_pos" >&2; }
done
for c2_neg in \
  'grep -q foo <<< "$x"' \
  "printf '%s' \"\$x\" | awk '{print}'" \
  'grep -F x <<< "$v" | head -n1' \
  "printf '%s' \"\$x\" | grep -c foo"; do
  if printf '%s\n' "$c2_neg" | grep -Eq "$SIGPIPE_RE"; then c2_re_ok=0; printf '  음성 오탐: %s\n' "$c2_neg" >&2; fi
done
if [ "$c2_re_ok" -eq 1 ]; then
  pass "(C-2a) SIGPIPE 가드 정규식이 양성 3종 탐지·음성 4종 미탐(클래스 식별 입증)"
else
  fail "(C-2a) SIGPIPE 가드 정규식 오탐/미탐 — 정규식 SIGPIPE_RE 조정 필요"
fi

# C-2b: 분석기 소스 실제 스캔 — 취약 패턴 0건.
if [ -f "$DRY_RUN_GUARD" ]; then
  # 주석 줄(# 로 시작)은 제외 — 이 가드의 설명 주석 자체가 패턴 텍스트를 담아 자기검출되는 것 방지.
  SIGPIPE_HITS="$(grep -nE "$SIGPIPE_RE" "$DRY_RUN_GUARD" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -z "$SIGPIPE_HITS" ]; then
    pass "(C-2b) 분석기 소스에 SIGPIPE 취약 패턴(| grep -q류/--quiet) 0건"
  else
    fail "(C-2b) 분석기 소스에 SIGPIPE 취약 패턴 잔존 — here-string 으로 바꿀 것:"
    printf '%s\n' "$SIGPIPE_HITS" >&2
  fi
fi

# C-3 (행동 회귀 가드, #88): 분석기를 SKILL.md 대상으로 20회 반복해 항상 정상 종료(exit 0)인지.
#   본질적으로 레이스라 결정적이진 않다(핵심 가드는 C-2 정적검사). exit≠0 은 'SIGPIPE 레이스'
#   라고 단정하지 않는다 — 아무 가드나 실패해도 비0 이므로, C-1/C-2 와 함께 원인을 확인한다.
if [ -f "$DRY_RUN_GUARD" ]; then
  C3_FAIL=0
  for _ in $(seq 1 20); do
    TEMPLATE="$SKILL" bash "$DRY_RUN_GUARD" >/dev/null 2>&1 || C3_FAIL=$((C3_FAIL+1))
  done
  if [ "$C3_FAIL" -eq 0 ]; then
    pass "(C-3) 분석기 20회 반복 전부 정상 종료(exit 0)"
  else
    fail "(C-3) 분석기 20회 중 $C3_FAIL 회 비정상 종료 — 원인은 C-1/C-2 함께 확인(SIGPIPE 레이스일 수도, 다른 가드 실패일 수도)"
  fi
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
