#!/usr/bin/env bash
# structure.test.sh — /pipeline:review skill 구조 정적 분석 테스트 (P2b R2).
#
# review.md.tmpl → SKILL.md 변환의 불변식을 단언한다:
#   (A) skill 변환 불변식: placeholder 0, oh-my-claudecode ref 0,
#       pipeline:code-reviewer·verifier·critic 호출, disable-model-invocation,
#       config 리더(--dump + CFG) 주입,
#       모듈 동작은 리더 인터페이스(--modules-where review/lead, --modules-table)로 읽음(#42).
#   (B) 보안: 민감 4키 개별 읽기 + --dump 미노출, 실제 시크릿 패턴 부재.
#   (C) self-approve 회피 게이트 + 헬퍼 경로(${CLAUDE_SKILL_DIR}/scripts).
#   (D) 핵심 동작 보존: self-approve 회피·Status 전환·에스컬·상태파일 sentinel 등.
#   (E) reference 분리 + 파일 존재.
#
# 결정적·격리: 순수 텍스트 정적 분석. gh·git 등 외부 호출 없음.
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$TEST_DIR/../SKILL.md"
REF="$TEST_DIR/../reference"
SCRIPTS="$TEST_DIR/../scripts"
CR_AGENT="$TEST_DIR/../../../agents/code-reviewer.md"
VF_AGENT="$TEST_DIR/../../../agents/verifier.md"
CRITIC_AGENT="$TEST_DIR/../../../agents/critic.md"

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
echo -e "${C_CYAN}══ /pipeline:review skill 구조 테스트 (P2b R2) ══${C_NC}"

[ -f "$SKILL" ] || { fail "SKILL.md 존재"; echo "통과 0 실패 1"; exit 1; }

echo -e "\n${C_CYAN}── (A) skill 변환 불변식 ──${C_NC}"
# A-1 placeholder 0 (SKILL.md + reference/)
if grep -qoE '__[A-Z_]+__' "$SKILL"; then fail "(A-1) SKILL.md placeholder 0"; else pass "(A-1) SKILL.md placeholder 0"; fi
if grep -rqoE '__[A-Z_]+__' "$REF"; then fail "(A-1) reference/ placeholder 0"; else pass "(A-1) reference/ placeholder 0"; fi

# A-2 oh-my-claudecode ref 0 (review 는 codex 폴백도 없음 — 완전 0)
absentE 'oh-my-claudecode' "$SKILL" "(A-2) SKILL.md oh-my-claudecode ref 0"
if grep -rqE 'oh-my-claudecode' "$REF"; then fail "(A-2) reference/ oh-my-claudecode ref 0"; else pass "(A-2) reference/ oh-my-claudecode ref 0"; fi

# A-3 pipeline 에이전트 3종 호출
has 'subagent_type="pipeline:code-reviewer"' "$SKILL" "(A-3) pipeline:code-reviewer 호출"
has 'subagent_type="pipeline:verifier"' "$SKILL" "(A-3) pipeline:verifier 호출"
has 'subagent_type="pipeline:critic"' "$SKILL" "(A-3) pipeline:critic 호출"
# critic 은 모드 C (영역 간 종합)
hasE '모드 C|영역 간 종합' "$SKILL" "(A-3) critic 모드 C(영역 간 종합) 명시"

# A-4 frontmatter disable-model-invocation
has 'disable-model-invocation: true' "$SKILL" "(A-4) disable-model-invocation: true (사람 전용)"

# A-5 config 리더 주입 (--dump) + CFG 정의
has 'pipeline-config.sh" --dump' "$SKILL" "(A-5) --dump 주입(프로젝트 설정 인지)"
has 'CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"' "$SKILL" "(A-5) CFG 리더 경로 정의"

# A-6 모듈 동작은 리더 인터페이스로 읽음 (#42 — 모듈명 하드코딩 제거).
#   영역↔레포 매핑·리뷰 대상 분기가 특정 모듈명이 아니라 review/lead 플래그로 표현됐는지 검증.
has '"$CFG" --modules-where review=true' "$SKILL" "(A-6) --modules-where review=true 로 리뷰 대상 선정"
hasE '--modules-where review=false' "$SKILL" "(A-6) review=false 모듈 자동 제외(플래그 기반)"
hasE '--modules-where lead=true' "$SKILL" "(A-6) lead 선행도 --modules-where lead=true 로"
has '"$CFG" --modules-table' "$SKILL" "(A-6) --modules-table 동작표 읽기"
# A-6b 동작 분기에 모듈 식별자 리터럴 부재 — 영역↔레포 매핑이 특정 모듈명으로 하드코딩되지 않음.
#   (예시 데이터/대소문자 설명/샘플 리포트는 허용. 여기선 "<owner>/Backend" 같은 매핑 리터럴만 검사.)
absentE '<owner>/(Backend|Admin|Android|Design)' "$SKILL" "(A-6b) <owner>/<모듈명> 매핑 하드코딩 부재"

echo -e "\n${C_CYAN}── (B) 보안: 민감 4키 + 시크릿 부재 ──${C_NC}"
# B-1 런타임에 실제 읽는 민감키는 개별 키 읽기($(bash "$CFG" <key>))로만 접근.
#     reviewer-token-key·slack-token-key 는 코드펜스에서 직접 값을 읽는다.
for k in reviewer-token-key slack-token-key; do
  has "\"\$CFG\" $k" "$SKILL" "(B-1) 민감키 개별 읽기: $k"
done
# reviewer-bot-slug 는 --require 게이트로 검증되고(개별 읽기 경로), reviewer-app-id 는
# R10 정보 표기용으로 config 키로만 언급된다(둘 다 --dump 미노출이어야 함).
has '"$CFG" --require reviewer-bot-slug reviewer-token-key' "$SKILL" "(B-1) reviewer-bot-slug --require 게이트 읽기"
hasE 'reviewer-app-id' "$SKILL" "(B-1) reviewer-app-id config 키 언급"

# B-2 민감 4키는 config 리더의 --dump 출력에서 제외돼야 한다(LLM 컨텍스트 노출 방지).
#     리더 스크립트의 --dump 키 목록 블록에 4키가 없는지 정적 단언.
CFG_READER="$SCRIPTS/pipeline-config.sh"
if [ -f "$CFG_READER" ]; then
  DUMP_BLOCK="$(awk '/elif arg == .--dump.:/{f=1} f{print} f&&/for k in keys:/{exit}' "$CFG_READER")"
  for k in reviewer-app-id reviewer-bot-slug reviewer-token-key slack-token-key; do
    if printf '%s' "$DUMP_BLOCK" | grep -qF "'$k'"; then
      fail "(B-2) $k 가 리더 --dump 목록에 포함됨(노출 위험)"
    else
      pass "(B-2) $k --dump 미노출(리더 제외 확인)"
    fi
  done
else
  fail "(B-2) config 리더 스크립트 없음: $CFG_READER"
fi
# SKILL 본문에서 --dump 에 키 인자를 붙이는 잘못된 패턴이 없는지(--dump 는 무인자)
if grep -qE -- '--dump[[:space:]]+(reviewer|slack)-' "$SKILL"; then
  fail "(B-2) SKILL 본문 --dump 에 민감키 인자 섞임"; else pass "(B-2) SKILL --dump 무인자 호출 확인"; fi
# B-3 실제 시크릿 패턴 부재 (PEM·토큰)
absentE 'BEGIN[ A-Z]*PRIVATE KEY' "$SKILL" "(B-3) PEM 본문 부재"
absentE 'ghs_[A-Za-z0-9]{20,}' "$SKILL" "(B-3) installation token(ghs_) 부재"
absentE 'ghp_[A-Za-z0-9]{20,}' "$SKILL" "(B-3) PAT(ghp_) 부재"
if grep -rqE 'BEGIN[ A-Z]*PRIVATE KEY|ghs_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}' "$REF"; then
  fail "(B-3) reference/ 시크릿 패턴 부재"; else pass "(B-3) reference/ 시크릿 패턴 부재"; fi

echo -e "\n${C_CYAN}── (C) self-approve 게이트 + 헬퍼 경로 ──${C_NC}"
# C-1 토큰 발급 펜스 앞 fail-fast 게이트
has '--require reviewer-bot-slug reviewer-token-key' "$SKILL" "(C-1) self-approve 토큰 fail-fast 게이트"
# C-2 헬퍼 경로 ${CLAUDE_SKILL_DIR}/scripts/ 형태
has '"${CLAUDE_SKILL_DIR}/scripts/gh-app-token.sh"' "$SKILL" "(C-2) gh-app-token.sh 헬퍼 경로"
has '"${CLAUDE_SKILL_DIR}/scripts/slack-notify.sh"' "$SKILL" "(C-2) slack-notify.sh 헬퍼 경로"
# C-3 .omc/scripts 잔재 0 (헬퍼 경로 한정 — 상태파일 .omc/state 는 정상이므로 scripts 만 검사)
if grep -qE '\.omc/scripts' "$SKILL"; then fail "(C-3) .omc/scripts 헬퍼 잔재 0"; else pass "(C-3) .omc/scripts 헬퍼 잔재 0"; fi

echo -e "\n${C_CYAN}── (D) 핵심 동작 보존 ──${C_NC}"
# D-1 self-approve 회피 키워드
hasE 'self-approve|self.approve' "$SKILL" "(D-1) self-approve 회피 보존"
# D-2 Status 전환 (Bot Review → In Review)
has 'Bot Review → In Review' "$SKILL" "(D-2) Status 전환(Bot Review→In Review) 보존"
hasE 'updateProjectV2ItemFieldValue' "$SKILL" "(D-2) Project Status GraphQL mutation 보존"
# D-3 에스컬 + Slack 이중 발송
hasE '에스컬' "$SKILL" "(D-3) 에스컬레이션 보존"
hasE 'slack-notify\.sh' "$SKILL" "(D-3) Slack 이중 발송 보존"
# D-4 상태파일 sentinel (결정적 식별)
has 'REVIEW_STATE_SENTINEL' "$SKILL" "(D-4) 상태파일 sentinel 보존"
# D-5 atomic REST review 제출 + 재시도 3분류
hasE 'pulls/<N>/reviews' "$SKILL" "(D-5) REST review 제출 보존"
hasE 'fixing|transient|immediate' "$SKILL" "(D-5) 재시도 3분류 보존"
# D-6 상태파일 schemaVersion 1.1 finding 보존 키
hasE 'findingsSummary' "$SKILL" "(D-6) findingsSummary 참조 보존"
hasE 'criticFindings' "$SKILL" "(D-6) aggregate.criticFindings 참조 보존"
# D-7 critic-only / codex 모드 보존
hasE 'CRITIC_ONLY|critic-only' "$SKILL" "(D-7) critic-only 모드 보존"
hasE 'CODEX_MODE|--codex' "$SKILL" "(D-7) codex 모드 보존"

echo -e "\n${C_CYAN}── (E) reference 분리 ──${C_NC}"
for rf in state-schema agent-prompts escalation context-md minor-gaps; do
  has "reference/$rf.md" "$SKILL" "(E-1) reference 링크: $rf"
  if [ -f "$REF/$rf.md" ]; then pass "(E-1) reference 파일 존재: $rf.md"; else fail "(E-1) reference 파일 없음: $rf.md"; fi
done
# E-2 핵심 스키마 키가 reference 로 이동 보존
has '"schemaVersion": "1.1"' "$REF/state-schema.md" "(E-2) state-schema: schemaVersion 1.1"
has '"codeReview"' "$REF/state-schema.md" "(E-2) state-schema: findings.codeReview"
# E-3 에이전트가 체크리스트를 소유(skill 에서 빠진 게 사라진 게 아님)
has 'severity' "$CR_AGENT" "(E-3) severity 분류 → code-reviewer 에이전트"
has '인수 기준' "$VF_AGENT" "(E-3) 인수 기준 체크 → verifier 에이전트"
hasE '모드 C' "$CRITIC_AGENT" "(E-3) 모드 C → critic 에이전트"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
