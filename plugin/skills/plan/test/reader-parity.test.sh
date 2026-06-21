#!/usr/bin/env bash
# reader-parity.test.sh — 3개 config 리더(plan·kickoff·review) 공통 코어 동일성 검증.
#
# 배경(#42 데이터층):
#   - kickoff·review 리더는 byte-identical 사본이어야 한다(공통 코어 + review 전용 4키 포함).
#   - plan 리더는 의도적으로 review 전용 4키(reviewer-app-id·reviewer-bot-slug·
#     reviewer-token-key·slack-token-key)가 빠진 버전이다(원작자 보안 의도 — 보존).
#   - 단, #42 에서 추가한 modules 인터페이스 공통 코어(블록분할·플래그 resolve·
#     --list-modules·--modules-where·--modules-table)는 3개 리더 모두 byte-identical 이어야 한다.
#
# 이 테스트는 위 불변식을 정적으로(파일 비교) + 행동으로(동일 입력→동일 출력) 잠근다.
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd "$TEST_DIR/../../.." && pwd)/skills"
PLAN="$SKILLS_DIR/plan/scripts/pipeline-config.sh"
KICKOFF="$SKILLS_DIR/kickoff/scripts/pipeline-config.sh"
REVIEW="$SKILLS_DIR/review/scripts/pipeline-config.sh"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${C_RED}✗${C_NC} %s\n    %s\n" "$1" "${2:-}" >&2; }

echo ""
echo -e "${C_CYAN}══ reader-parity 단위 테스트 ══${C_NC}"

# 세 파일 모두 존재
for f in "$PLAN" "$KICKOFF" "$REVIEW"; do
  [ -f "$f" ] || { fail "리더 파일 존재" "없음: $f"; }
done

# ── (1) kickoff == review (full byte-identical) ──
if cmp -s "$KICKOFF" "$REVIEW"; then
  pass "kickoff 리더 == review 리더 (byte-identical)"
else
  fail "kickoff == review" "두 파일이 다름 (diff: $KICKOFF vs $REVIEW)"
fi

# ── (2) modules 공통 코어가 3개 리더 모두 byte-identical ──
# '# ── modules 블록 파싱' 부터 'MODULE_TABLE_FLAGS = ...' 줄까지를 추출해 비교.
extract_core() {
  awk '/# ── modules 블록 파싱/{f=1} f{print} /^MODULE_TABLE_FLAGS = /{f=0}' "$1"
}
core_p="$(extract_core "$PLAN")"
core_k="$(extract_core "$KICKOFF")"
core_r="$(extract_core "$REVIEW")"
if [ -n "$core_p" ] && [ "$core_p" = "$core_k" ] && [ "$core_p" = "$core_r" ]; then
  pass "modules 공통 코어 3개 리더 byte-identical"
else
  fail "modules 공통 코어 동일성" "plan/kickoff/review 코어 블록이 다름"
fi

# 공통 코어 동작 동일성 — 같은 픽스처로 --modules-table 출력 동일한지
FIX="$(mktemp)"
cat > "$FIX" <<'EOF'
modules:
  - name: Alpha
    role: server
    area-id: a1
    lead: true
  - name: Beta
    role: client
    planner: false
EOF
out_p="$(PIPELINE_CONFIG="$FIX" bash "$PLAN" --modules-table 2>/dev/null)"
out_k="$(PIPELINE_CONFIG="$FIX" bash "$KICKOFF" --modules-table 2>/dev/null)"
out_r="$(PIPELINE_CONFIG="$FIX" bash "$REVIEW" --modules-table 2>/dev/null)"
if [ "$out_p" = "$out_k" ] && [ "$out_p" = "$out_r" ] && [ -n "$out_p" ]; then
  pass "--modules-table 출력 3개 리더 동일(행동 parity)"
else
  fail "--modules-table 행동 parity" "출력이 리더별로 다름"
fi
rm -f "$FIX"

# ── (3) plan 리더에는 review 전용 4키가 없어야 / kickoff·review 에는 있어야 ──
REV_KEYS=(reviewer-app-id reviewer-bot-slug reviewer-token-key slack-token-key)
# resolve() 의 claude-commands 스칼라 분기에서 4키 처리 여부를 grep 으로 확인.
plan_has=0; kick_has=0
for k in "${REV_KEYS[@]}"; do
  grep -q "'$k'" "$PLAN" && plan_has=$((plan_has+1))
  grep -q "'$k'" "$KICKOFF" || kick_has=$((kick_has+1))   # 없으면 카운트(누락 감지)
done
if [ "$plan_has" -eq 0 ]; then
  pass "plan 리더에 review 전용 4키 없음(보안 의도 보존)"
else
  fail "plan 리더 4키 부재" "plan 에 reviewer 키 $plan_has 개 발견(있으면 안 됨)"
fi
if [ "$kick_has" -eq 0 ]; then
  pass "kickoff 리더에 review 전용 4키 존재"
else
  fail "kickoff 리더 4키 존재" "kickoff 에 reviewer 키 $kick_has 개 누락"
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
