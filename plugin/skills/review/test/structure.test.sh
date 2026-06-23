#!/usr/bin/env bash
# structure.test.sh — /pipeline:review skill 구조 정적 분석 테스트 (P2b R2).
#
# SKILL.md 가 가져야 할 구조 불변식을 단언한다(P3.1: 배포 SSOT 가 SKILL.md 로 일원화돼
# templates/claude-commands/review.md.tmpl 의존을 제거함. 검증은 plugin 내부 자산만 대상으로 한다):
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
# C-3 .omc/ 잔재 0 (#65 — 상태경로도 중립 경로로 탈종속. state·scripts 등 omc 경로 전체가 새어들면 잡는다)
#   상태경로 드리프트(#54: .omc/state 잔재 → verdict=null 자동머지 차단 회귀)는 이 광역 검사가
#   .omc/state 를 포함하므로 SKILL.md+reference 만으로 잡힌다(P3.1 전엔 tmpl 도 별도 검사했으나
#   배포 SSOT 가 SKILL.md 로 일원화돼 tmpl 의존 제거).
if grep -qE '\.omc/' "$SKILL"; then fail "(C-3) .omc/ 잔재 0"; else pass "(C-3) .omc/ 잔재 0"; fi
if grep -rqE '\.omc/' "$REF"; then fail "(C-3) reference/ .omc/ 잔재 0"; else pass "(C-3) reference/ .omc/ 잔재 0"; fi

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

echo -e "\n${C_CYAN}── (D-6b~e) critic verdict 死문 정정 (#47) ──${C_NC}"
CTX_MD="$REF/context-md.md"
SCHEMA_MD="$REF/state-schema.md"
# D-6b 死문 필드 criticVerdict 재유입 차단 (context-md.md R11 트리거)
absentE 'criticVerdict' "$CTX_MD" "(D-6b) context-md.md criticVerdict 死문 필드 부재"
# D-6c 정정된 트리거 (d) — criticFindings 가 비어있지 않으면
hasE 'criticFindings.* 가 비어있지 않' "$CTX_MD" "(D-6c) context-md.md 트리거 (d) criticFindings 비어있지 않음"
# D-6d state-schema.md 8-c-bis ↔ critic.yml verdict 계약 잠금.
#   8-c-bis 블록(## 8-c-bis ~ 다음 ## 헤더)만 추출해 검사. (앵커가 사라지면 awk 가
#   파일 끝까지 삼키지 않도록, 다음 '## ' 헤더를 터미네이터로 쓴다 — 특정 섹션명에 비의존.)
SCHEMA_8CBIS="$(awk '/^## 8-c-bis/{f=1; next} f&&/^## /{exit} f{print}' "$SCHEMA_MD")"
# D-6d-1 死문 필드 criticVerdict 재유입 차단 (맞는 검증 — 유지).
if printf '%s' "$SCHEMA_8CBIS" | grep -q 'criticVerdict'; then
  fail "(D-6d-1) state-schema 8-c-bis criticVerdict 死문 부재"; else pass "(D-6d-1) state-schema 8-c-bis criticVerdict 死문 부재"; fi
# D-6d-2 GHA 계약 잠금 (#47 핵심): aggregate.verdict 의 enum 예시가 critic 종합 verdict
#   (pass|concerns|blocker)로 존재하고, 실제 소비자 critic.yml 의 verdict allowlist(case)와
#   토큰 집합이 정확히 일치하는지 검증. 문서↔GHA 한쪽만 바뀌면 FAIL → 런타임 계약 깨짐 사전 차단.
#   (이번 #47 의 critical: 8-c-bis enum 을 approved/changes-requested/escalated 로 바꿔
#    critic.yml allowlist 와 어긋났는데 기존 테스트가 못 잡았음 → 이 테스트가 그걸 잠근다.)
CRITIC_YML="$TEST_DIR/../../../../.github/workflows/critic.yml"
# 8-c-bis 예시에서 "verdict": "a" | "b" | "c" 의 값 토큰만 추출(키 "verdict" 자체는 제외).
#   colon 뒤의 값 부분만 잘라낸 뒤 따옴표 안 소문자 토큰을 모은다.
schema_enum="$(printf '%s' "$SCHEMA_8CBIS" \
  | grep -E '"verdict":' | sed -E 's/^.*"verdict":[[:space:]]*//' \
  | grep -oE '"[a-z]+"' | tr -d '"' | sort -u | paste -sd'|' -)"
if [ -f "$CRITIC_YML" ]; then
  # critic.yml 의 allowlist case 라인(예: `pass|concerns|blocker) ;;`)에서 토큰 추출.
  #   indeterminate 는 allowlist 통과값이 아니라 fallback(*) 흡수값이므로 계약 enum 에서 제외.
  yml_enum="$(grep -oE '^[[:space:]]*[a-z|]+\)[[:space:]]*;;' "$CRITIC_YML" \
    | grep -F 'pass' | grep -oE '[a-z]+' | grep -v '^indeterminate$' | sort -u | paste -sd'|' -)"
  if [ -n "$schema_enum" ] && [ "$schema_enum" = "$yml_enum" ]; then
    pass "(D-6d-2) 8-c-bis aggregate.verdict enum($schema_enum) ↔ critic.yml allowlist($yml_enum) 일치"
  else
    fail "(D-6d-2) 8-c-bis aggregate.verdict enum($schema_enum) ≠ critic.yml allowlist($yml_enum) — 런타임 계약 불일치"
  fi
else
  fail "(D-6d-2) critic.yml 존재: $CRITIC_YML"
fi
# (P3.1) D-6e 의 tmpl 동기 검증은 제거했다 — 배포 SSOT 가 SKILL.md 로 일원화됐다.
#   원래 D-6e 가 보던 두 불변식은 plugin 자산 대상으로 이미 보존된다:
#     · 트리거 (d) 'criticFindings 가 비어있지 않' → 위 D-6c 가 context-md.md(CTX_MD)에서 검증
#     · 10-a 라이브 트리거에 criticVerdict 死문 부재 → 아래 D-6e' 가 SKILL.md 에서 검증
# D-6e' SKILL.md 의 10-a Docs 커밋 트리거 블록에 死문 필드 criticVerdict 가 재유입되지 않았는지.
#   (R11 이력 노트는 死문 정정 블레임으로 그 단어를 정당히 인용하므로, 라이브 트리거 블록만 한정 검사.
#    터미네이터는 다음 헤더 — '#### ' 또는 더 얕은 '### '(10-a 다음 섹션이 ### 11 처럼 얕을 수 있어
#    '#### ' 만 보면 EOF 까지 과추출됨). 특정 문구에 비의존.)
SKILL_10A="$(awk '/^#### 10-a\./{f=1; next} f&&/^#### |^### /{exit} f{print}' "$SKILL")"
if printf '%s' "$SKILL_10A" | grep -q 'criticVerdict'; then
  fail "(D-6e') SKILL 10-a 트리거 criticVerdict 死문 부재"; else pass "(D-6e') SKILL 10-a 트리거 criticVerdict 死문 부재"; fi

echo -e "\n${C_CYAN}── (D-8) aggregate.verdict write 단계 존재 (#54) ──${C_NC}"
# #54 critical: aggregate.verdict 를 상태파일에 쓰는 실행 단계가 처음부터 없어 항상 null →
#   critic.yml allowlist 미스 → indeterminate → critic 자동머지 영구 차단. 8-c-bis 에 write 추가.
#   SKILL.md 8-c-bis 에 jq 로 .aggregate.verdict 를 세팅하는 실행 블록이 있어야 한다.
#   (8-c-bis 블록만 추출해 검사 — 다음 '#### ' 헤더를 터미네이터로.)
#   (P3.1) tmpl 동기 검증은 제거 — 배포 SSOT 가 SKILL.md 로 일원화됐다.
SKILL_8CBIS="$(awk '/^#### 8-c-bis/{f=1; next} f&&/^#### /{exit} f{print}' "$SKILL")"
# jq 로 .aggregate.verdict 를 대입하는 실행 패턴 존재(공백 변형 허용).
if printf '%s' "$SKILL_8CBIS" | grep -qE '\.aggregate\.verdict[[:space:]]*='; then
  pass "(D-8) SKILL 8-c-bis aggregate.verdict write 실행 단계 존재"
else fail "(D-8) SKILL 8-c-bis aggregate.verdict write 실행 단계 존재"; fi
if printf '%s' "$SKILL_8CBIS" | grep -qE 'jq .*--argjson|jq .*--arg cv'; then
  pass "(D-8) SKILL 8-c-bis jq 트랜잭션(verdict 캡처) 존재"
else fail "(D-8) SKILL 8-c-bis jq 트랜잭션(verdict 캡처) 존재"; fi
# 원자적 temp+mv 규칙 준수(L250) — write 블록에 mv 가 있어야 partial write 방지.
if printf '%s' "$SKILL_8CBIS" | grep -qE 'mv .*STATE_FILE|mv "\$TEMP"'; then
  pass "(D-8) SKILL 8-c-bis 원자적 temp+mv 준수"
else fail "(D-8) SKILL 8-c-bis 원자적 temp+mv 준수"; fi
# D-8b STATE_FILE 와이어링 가드 (#54 후속 [major]): 8-c-bis 의 STATE_FILE 대입이
#   Step4/5 컨벤션인 라이브 변수 ${SLUG} 여야 한다. 리터럴 angle-bracket(<slug>.json)을
#   박으면 별개 셸에서 치환 누락 시 jq no-such-file → mv 스킵 → verdict 미기록 → #54 회귀.
#   SKILL.md: ${SLUG} 존재 + 리터럴 <slug>.json 부재 정적 단언.
state_assign="$(printf '%s\n' "$SKILL_8CBIS" | grep -E 'STATE_FILE=' | grep -E 'reviews/' )"
if printf '%s' "$state_assign" | grep -qF '${SLUG}.json'; then
  pass "(D-8b) SKILL 8-c-bis STATE_FILE 라이브 변수 \${SLUG} 사용"
else fail "(D-8b) SKILL 8-c-bis STATE_FILE 라이브 변수 \${SLUG} 사용"; fi
if printf '%s' "$state_assign" | grep -qF '<slug>.json'; then
  fail "(D-8b) SKILL 8-c-bis STATE_FILE 리터럴 <slug> 부재(치환누락 회귀 함정)"
else pass "(D-8b) SKILL 8-c-bis STATE_FILE 리터럴 <slug> 부재(치환누락 회귀 함정)"; fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
