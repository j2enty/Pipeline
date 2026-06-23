#!/usr/bin/env bash
# structure.test.sh — plugin/agents/ 일꾼 에이전트 구조 정적 분석 테스트 (P2b R1).
#
# code-reviewer·verifier·critic(모드 A/B/C)·executor 에이전트 파일의 불변식을 단언한다:
#   (A) frontmatter 필수 필드(name·model) 존재 + name 일치.
#   (B) 반환 JSON 계약 보존 — code-reviewer·verifier·critic(모드C)·executor 의 필드명·
#       severity·status·category 값이 SKILL 파서와 1:1 (skill 파싱 강결합이라 한 글자도 못 바꿈).
#   (C) critic 모드 A/B/C 셋 다 존재(기존 A/B 보존 + C 추가).
#   (D) 프로젝트 식별자·시크릿 패턴 부재(이식성 — 본체 코드 종속성 제로).
#   (E) executor 가드 문구(플랜 밖 수정 금지 / 재시도 정책 호출자 소유).
#
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$TEST_DIR/.."
CODE_REVIEWER="$AGENTS_DIR/code-reviewer.md"
VERIFIER="$AGENTS_DIR/verifier.md"
CRITIC="$AGENTS_DIR/critic.md"
EXECUTOR="$AGENTS_DIR/executor.md"

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
absent() { if grep -q "$1" "$2"; then fail "$3"; else pass "$3"; fi; }

echo ""
echo -e "${C_CYAN}══ plugin/agents/ 구조 테스트 (P2b R1) ══${C_NC}"

for f in "$CODE_REVIEWER" "$VERIFIER" "$CRITIC" "$EXECUTOR"; do
  [ -f "$f" ] || { fail "에이전트 파일 존재: $(basename "$f")"; }
done

echo -e "\n${C_CYAN}── (A) frontmatter 필수 필드 ──${C_NC}"
# name·model 필드 존재 + name 값 일치
has '^name: code-reviewer$' "$CODE_REVIEWER" "(A) code-reviewer: name 일치"
has '^model:' "$CODE_REVIEWER" "(A) code-reviewer: model 존재"
has '^name: verifier$' "$VERIFIER" "(A) verifier: name 일치"
has '^model:' "$VERIFIER" "(A) verifier: model 존재"
has '^name: critic$' "$CRITIC" "(A) critic: name 일치"
has '^model:' "$CRITIC" "(A) critic: model 존재"
has '^name: executor$' "$EXECUTOR" "(A) executor: name 일치"
has '^model:' "$EXECUTOR" "(A) executor: model 존재"

echo -e "\n${C_CYAN}── (B) 반환 JSON 계약 보존 (skill 파싱 강결합) ──${C_NC}"
# B-1 code-reviewer findings[] 스키마: severity 값 4종 + 6개 필드
has '"blocker" | "major" | "minor" | "nit"' "$CODE_REVIEWER" "(B-1) code-reviewer severity 4종(blocker/major/minor/nit)"
for fld in '"summary"' '"findings"' '"severity"' '"file"' '"line"' '"title"' '"description"' '"suggestion"'; do
  has "$fld" "$CODE_REVIEWER" "(B-1) code-reviewer 필드: $fld"
done
# B-2 verifier 판정 스키마: verdict pass/fail + reasons
has '"verdict": "pass" | "fail"' "$VERIFIER" "(B-2) verifier verdict(pass/fail)"
has '"reasons"' "$VERIFIER" "(B-2) verifier reasons 필드"
# B-3 critic 모드C 스키마: verdict 3값 + cross-area 5개 필드(file/line 없음)
has '"verdict": "pass" | "concerns" | "blocker"' "$CRITIC" "(B-3) critic 모드C verdict(pass/concerns/blocker)"
has '"severity": "blocker" | "major" | "minor"' "$CRITIC" "(B-3) critic 모드C severity 3종(blocker/major/minor)"
for fld in '"area"' '"affected_prs"'; do
  has "$fld" "$CRITIC" "(B-3) critic 모드C 필드: $fld"
done
# B-4 executor 반환 스키마: status 2값 + category 3값 + 핵심 필드(skill 8-c 루프 파싱 강결합)
has '"status": "ready_for_pr" | "escalated"' "$EXECUTOR" "(B-4) executor status(ready_for_pr/escalated)"
has '"category": "fixing|transient|immediate"' "$EXECUTOR" "(B-4) executor errorSummary.category(fixing/transient/immediate)"
for fld in '"status"' '"branch"' '"testSummary"' '"passed"' '"failed"' '"skipped"' '"command"' '"commits"' '"errorSummary"' '"message"' '"rawTail"'; do
  has "$fld" "$EXECUTOR" "(B-4) executor 필드: $fld"
done

echo -e "\n${C_CYAN}── (C) critic 모드 A/B/C 셋 다 존재 ──${C_NC}"
has '## 모드 A — 완결성 critic' "$CRITIC" "(C) 모드 A(완결성) 보존"
has '## 모드 B — 정합성 critic' "$CRITIC" "(C) 모드 B(정합성) 보존"
has '## 모드 C — 영역 간 종합 리뷰 critic' "$CRITIC" "(C) 모드 C(cross-area) 추가"
# 모드 A/B 의 기존 핵심 문구도 회귀 없이 살아있는지(C 추가가 A/B 를 안 깼는지)
has '메우지 말고 분류' "$CRITIC" "(C) 모드 A/B '메우지 말고 분류' 보존"
has 'rate limit' "$CRITIC" "(C) 보안 강제 룰(rate limit) 보존"

echo -e "\n${C_CYAN}── (E) executor 가드 문구 보존 ──${C_NC}"
# 플랜 밖 수정 금지 가드(scope creep 차단) — kickoff 8-d 의 "금지: 플랜 밖 수정" 을 에이전트로 승격
has '플랜 밖 수정 금지' "$EXECUTOR" "(E) executor '플랜 밖 수정 금지' 가드"
# 재시도 정책이 호출자 소유라는 명시(executor 는 category 라벨만 반환)
has '재시도 정책' "$EXECUTOR" "(E) executor '재시도 정책 호출자 소유' 명시"

echo -e "\n${C_CYAN}── (D) 이식성: 프로젝트 식별자·시크릿 부재 ──${C_NC}"
for f in "$CODE_REVIEWER" "$VERIFIER" "$CRITIC" "$EXECUTOR"; do
  bn="$(basename "$f")"
  # placeholder(__FOO__) 부재 — 에이전트는 호출 시 주입받음
  if grep -qoE '__[A-Z_]+__' "$f"; then fail "(D) placeholder 부재: $bn"; else pass "(D) placeholder 부재: $bn"; fi
  # 프로젝트 식별자 하드코딩 부재
  absent 'Reclip' "$f" "(D) 'Reclip' 식별자 부재: $bn"
  # PEM/토큰 등 시크릿 본문 부재
  absent 'BEGIN.*PRIVATE KEY' "$f" "(D) PEM 본문 부재: $bn"
  absent 'ghp_' "$f" "(D) gh 토큰 부재: $bn"
done

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
