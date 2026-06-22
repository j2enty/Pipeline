#!/usr/bin/env bash
# structure.test.sh — /pipeline:kickoff skill 구조 정적 분석 테스트 (P2b K2).
#
# kickoff.md.tmpl → SKILL.md 변환의 불변식을 단언한다:
#   (A) skill 변환 불변식: placeholder 0, pipeline:executor·verifier 호출,
#       disable-model-invocation, config 리더(--dump + CFG) 주입,
#       모듈 동작은 리더 인터페이스(--modules-table/--modules-where)로 읽음(모듈명 비종속, #42).
#   (B) OMC degrade: oh-my-claudecode 참조는 degrade(--agent 폴백) 컨텍스트에서만 허용,
#       그 외 0. degrade 분기 문구 존재.
#   (C) review 자동 체이닝: Skill(skill="pipeline:review") 존재.
#   (D) 핵심 동작 보존: 8-c 재시도 루프·로컬-원격 동기화 가드·AC 치환·Status=Bot Review 전환.
#   (E) 헬퍼 경로 ${CLAUDE_SKILL_DIR}/scripts (.omc/scripts 헬퍼 잔재 0).
#   (F) 보안: 실제 시크릿 패턴 부재.
#   (G) reference 분리 + 파일 존재.
#
# 결정적·격리: 순수 텍스트 정적 분석. gh·git 등 외부 호출 없음.
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$TEST_DIR/../SKILL.md"
REF="$TEST_DIR/../reference"
SCRIPTS="$TEST_DIR/../scripts"
EXEC_AGENT="$TEST_DIR/../../../agents/executor.md"
VF_AGENT="$TEST_DIR/../../../agents/verifier.md"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${C_RED}✗${C_NC} %s\n" "$1" >&2; }

has()  { if grep -qF -- "$1" "$2"; then pass "$3"; else fail "$3"; fi; }
hasE() { if grep -qE -- "$1" "$2"; then pass "$3"; else fail "$3"; fi; }
absentE() { if grep -qE -- "$1" "$2"; then fail "$3"; else pass "$3"; fi; }

echo ""
echo -e "${C_CYAN}══ /pipeline:kickoff skill 구조 테스트 (P2b K2) ══${C_NC}"

[ -f "$SKILL" ] || { fail "SKILL.md 존재"; echo "통과 0 실패 1"; exit 1; }

echo -e "\n${C_CYAN}── (A) skill 변환 불변식 ──${C_NC}"
# A-1 placeholder 0 (SKILL.md + reference/)
if grep -qoE '__[A-Z_]+__' "$SKILL"; then fail "(A-1) SKILL.md placeholder 0"; else pass "(A-1) SKILL.md placeholder 0"; fi
if grep -rqoE '__[A-Z_]+__' "$REF"; then fail "(A-1) reference/ placeholder 0"; else pass "(A-1) reference/ placeholder 0"; fi

# A-2 pipeline 에이전트 2종 호출
has 'subagent_type="pipeline:executor"' "$SKILL" "(A-2) pipeline:executor 호출"
has 'subagent_type="pipeline:verifier"' "$SKILL" "(A-2) pipeline:verifier 호출"

# A-3 frontmatter disable-model-invocation
has 'disable-model-invocation: true' "$SKILL" "(A-3) disable-model-invocation: true (사람 전용)"

# A-4 config 리더 주입 (--dump) + CFG 정의
has 'pipeline-config.sh" --dump' "$SKILL" "(A-4) --dump 주입(프로젝트 설정 인지)"
has 'CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"' "$SKILL" "(A-4) CFG 리더 경로 정의"

# A-5 config 키 개별 읽기 — 상수
for k in owner parent-repo-name project-id project-number status-field-id area-field-id docs-context-dir; do
  has "\"\$CFG\" $k" "$SKILL" "(A-5) config 키 개별 읽기: $k"
done
# A-5a 모듈 동작은 리더 인터페이스(--modules-table 등)로 읽는다 (#42 — 모듈명 하드코딩 제거).
#   area-id 개별 6종 호출(area-id.Backend 등)이 동작 분기에서 사라지고 표 1회 읽기로 대체됐는지 검증.
has '"$CFG" --modules-table' "$SKILL" "(A-5a) --modules-table 1회 읽기로 모듈표 주입"
hasE '\-\-modules-where (lead|kickoff)' "$SKILL" "(A-5a) --modules-where 로 lead/kickoff 분기"
# A-5b 모듈명 area-id 개별호출(하드코딩) 부재 — 특정 모듈명에 묶인 area-id.<이름> 호출이 없어야 함.
#   (리더는 여전히 area-id.<Name>·module.<Name> 키를 지원하지만, SKILL.md 동작이 특정
#    모듈명으로 area-id 를 개별 호출하면 종속성 회귀. 예시 토큰 <Name>·<name> 은 허용.)
absentE '"\$CFG" area-id\.(Backend|Admin|Frontend|iOS|Android|Design)' "$SKILL" "(A-5b) 모듈명 area-id.<이름> 개별호출 부재(하드코딩 제거)"
absentE 'area-id\.IOS' "$SKILL" "(A-5b) area-id.IOS(오타) 부재"

echo -e "\n${C_CYAN}── (B) OMC degrade (oh-my-claudecode 참조 통제) ──${C_NC}"
# B-1 SKILL.md 의 oh-my-claudecode 참조는 전부 team/ultra degrade 컨텍스트(폴백 prose)
#     또는 혼동 금지(네임스페이스 구분) 주의 줄에만 있어야 한다.
#     #49-2: 화이트리스트에서 generic 토큰(agent·bare team·bare ultra)을 제거하고
#     강한 degrade/disambiguation 컨텍스트 토큰만 허용한다. generic 'agent' 는 일반 산문
#     어디에나 등장해서 진짜 잘못된 primary OMC 참조("…를 주 오케스트레이터로 쓴다" 류)도
#     통과시켜 버린다. 'team'·'ultra' 도 bare 로는 너무 흔하므로 OMC 전용 플래그
#     '--team'·'--ultra' 또는 명시 네임스페이스 'oh-my-claudecode:' 형태일 때만 인정.
#     각 매치 줄에 다음 중 하나가 함께 있어야 한다:
#       degrade·폴백·fallback (degrade 컨텍스트)
#       혼동·네임스페이스      (disambiguation 컨텍스트)
#       부재                   (OMC 부재 = degrade 트리거 컨텍스트)
#       --team·--ultra         (OMC 전용 플래그 — bare team/ultra 아님)
#       oh-my-claudecode:      (명시 OMC 네임스페이스 — 대안 경로 표기)
OMC_CTX_RE='degrade|폴백|fallback|혼동|네임스페이스|부재|--team|--ultra|oh-my-claudecode:'
OMC_LINES="$(grep -nE 'oh-my-claudecode' "$SKILL" || true)"
if [ -z "$OMC_LINES" ]; then
  # kickoff 은 degrade 를 설명해야 하므로 oh-my-claudecode 가 0이면 오히려 degrade 누락 의심.
  fail "(B-1) oh-my-claudecode 참조 0 — team/ultra degrade 문맥 누락 의심"
else
  bad_ctx=0
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -qE "$OMC_CTX_RE"; then :; else
      bad_ctx=$((bad_ctx+1)); printf "    ↳ degrade 무관 oh-my-claudecode 줄: %s\n" "$line" >&2
    fi
  done <<EOF
$OMC_LINES
EOF
  if [ "$bad_ctx" -eq 0 ]; then pass "(B-1) oh-my-claudecode 참조는 전부 team/ultra degrade 컨텍스트"; else fail "(B-1) degrade 무관 oh-my-claudecode 참조 $bad_ctx 건"; fi
fi
# reference/ 도 동일 — runtime-degrade.md 외에는 oh-my-claudecode 가 없어야 함
OTHER_REF_OMC="$(grep -rlE 'oh-my-claudecode' "$REF" 2>/dev/null | grep -v 'runtime-degrade.md' || true)"
if [ -z "$OTHER_REF_OMC" ]; then pass "(B-1) reference/ oh-my-claudecode 는 runtime-degrade.md 한정"; else fail "(B-1) runtime-degrade.md 밖 oh-my-claudecode 참조: $OTHER_REF_OMC"; fi

# B-2 degrade 분기 문구 — OMC 없으면 --agent 폴백
hasE 'degrade' "$SKILL" "(B-2) degrade 키워드 존재"
hasE '\-\-agent' "$SKILL" "(B-2) --agent 폴백 언급 존재"
hasE '없으면.*--agent|--agent.*폴백|폴백.*--agent' "$SKILL" "(B-2) 'OMC 없으면 --agent 폴백' 분기 문구"
# B-3 --serial/--agent 는 OMC 무관 (executor 직접) 명시
hasE 'OMC 무관|OMC 와 무관|OMC 설치 여부와 무관' "$SKILL" "(B-3) executor 직접경로 OMC 무관 명시"

echo -e "\n${C_CYAN}── (C) review 자동 체이닝 ──${C_NC}"
has 'skill="pipeline:review"' "$SKILL" "(C-1) Skill(skill=\"pipeline:review\") 체이닝"
hasE '자동 체이닝' "$SKILL" "(C-1) /review 자동 체이닝 보존"
# 혼동 금지: oh-my-claudecode:review 로 체이닝하면 안 됨
absentE 'skill="oh-my-claudecode:review"' "$SKILL" "(C-1) oh-my-claudecode:review 체이닝 부재(혼동 금지)"

echo -e "\n${C_CYAN}── (D) 핵심 동작 보존 ──${C_NC}"
# D-1 로컬-원격 동기화 가드 (G15, 2026-04-20 Android)
hasE 'rev-list origin' "$SKILL" "(D-1) 로컬-원격 동기화 가드(rev-list) 보존"
hasE '동기화 가드|동기화 실패|원격 동기화' "$SKILL" "(D-1) 동기화 가드 문맥 보존"
# D-2 8-c 재시도 3분류 루프 (fixing 5 / transient 3 백오프 / immediate)
hasE 'fixing|transient|immediate' "$SKILL" "(D-2) 재시도 3분류 보존"
hasE 'fixing.*5|5.*fixing|fixing ≥ 5|fixing < 5' "$SKILL" "(D-2) fixing 상한 5 보존"
hasE 'transient.*3|3.*transient|백오프' "$SKILL" "(D-2) transient 3 + 백오프 보존"
# D-3 AC 체크박스 치환 (멱등)
hasE '## AC' "$SKILL" "(D-3) AC 섹션 치환 보존"
hasE 'idempotent|멱등|이미 체크된' "$SKILL" "(D-3) AC 치환 멱등성 보존"
hasE 'gsub' "$SKILL" "(D-3) AC awk gsub 치환 보존"
# D-4 Status=Bot Review 전환
has 'Bot Review' "$SKILL" "(D-4) Status Bot Review 전환 보존"
hasE 'updateProjectV2ItemFieldValue' "$SKILL" "(D-4) Project Status GraphQL mutation 보존"
# D-5 Backend 게이트 + sub-issue 발견
hasE 'Backend 게이트|G1-a' "$SKILL" "(D-5) Backend 게이트 보존"
hasE 'sub_issues' "$SKILL" "(D-5) sub-issue 발견(GitHub native API) 보존"
# D-6 Status 필터 / kickoff=false 제외(모듈명 비종속) / restart 재개
hasE 'In Progress만 처리|Status 필터' "$SKILL" "(D-6) Status 필터 보존"
# 제외 분기는 모듈명이 아니라 kickoff 플래그로 — #42 일반화. (구버전 'Design.*제외' 리터럴 대체)
hasE 'kickoff=false|module\..*\.kickoff' "$SKILL" "(D-6) kickoff=false 모듈 제외(플래그 기반)"
hasE '재개|--restart' "$SKILL" "(D-6) restart/이어서 로직 보존"
# D-7 에스컬 + Slack 이중 발송
hasE '에스컬' "$SKILL" "(D-7) 에스컬레이션 보존"
hasE 'slack-notify\.sh' "$SKILL" "(D-7) Slack 이중 발송 보존"

echo -e "\n${C_CYAN}── (E) 헬퍼 경로 ──${C_NC}"
has '"${CLAUDE_SKILL_DIR}/scripts/slack-notify.sh"' "$SKILL" "(E-1) slack-notify.sh 헬퍼 경로"
# .omc/scripts 헬퍼 잔재 0 (상태파일 .omc/state 는 정상이므로 scripts 만 검사)
if grep -qE '\.omc/scripts' "$SKILL"; then fail "(E-2) .omc/scripts 헬퍼 잔재 0"; else pass "(E-2) .omc/scripts 헬퍼 잔재 0"; fi
if grep -rqE '\.omc/scripts' "$REF"; then fail "(E-2) reference/ .omc/scripts 헬퍼 잔재 0"; else pass "(E-2) reference/ .omc/scripts 헬퍼 잔재 0"; fi
# 동봉 헬퍼 실제 존재 + 실행권한
for sh in pipeline-config.sh slack-notify.sh; do
  if [ -f "$SCRIPTS/$sh" ]; then pass "(E-3) 동봉 헬퍼 존재: $sh"; else fail "(E-3) 동봉 헬퍼 없음: $sh"; fi
  if [ -x "$SCRIPTS/$sh" ]; then pass "(E-3) 실행권한: $sh"; else fail "(E-3) 실행권한 없음: $sh"; fi
done

echo -e "\n${C_CYAN}── (F) 보안: 시크릿 부재 ──${C_NC}"
absentE 'BEGIN[ A-Z]*PRIVATE KEY' "$SKILL" "(F-1) PEM 본문 부재"
absentE 'ghs_[A-Za-z0-9]{20,}' "$SKILL" "(F-1) installation token(ghs_) 부재"
absentE 'ghp_[A-Za-z0-9]{20,}' "$SKILL" "(F-1) PAT(ghp_) 부재"
if grep -rqE 'BEGIN[ A-Z]*PRIVATE KEY|ghs_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}' "$REF"; then
  fail "(F-1) reference/ 시크릿 패턴 부재"; else pass "(F-1) reference/ 시크릿 패턴 부재"; fi

echo -e "\n${C_CYAN}── (G) reference 분리 ──${C_NC}"
for rf in agent-prompts escalation context-md runtime-degrade minor-gaps; do
  has "reference/$rf.md" "$SKILL" "(G-1) reference 링크: $rf"
  if [ -f "$REF/$rf.md" ]; then pass "(G-1) reference 파일 존재: $rf.md"; else fail "(G-1) reference 파일 없음: $rf.md"; fi
done
# G-2 에이전트가 절차/체크리스트를 소유(skill 에서 빠진 게 사라진 게 아님)
hasE 'ready_for_pr' "$EXEC_AGENT" "(G-2) executor 반환 스키마 → executor 에이전트"
has '인수 기준' "$VF_AGENT" "(G-2) 인수 기준 체크 → verifier 에이전트"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
