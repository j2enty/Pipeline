#!/usr/bin/env bash
# pipeline-config.test.sh — config 리더(pipeline-config.sh) 단위 테스트.
#
# 검증: 스칼라 추출 / 파생키(parent-repo-name·project-number) / area-id /
#       plan 토글(기본 true·명시 false·따옴표 false) / 인라인 주석 / config 부재
#       fail-soft / 알 수 없는 키 / install.sh parity.
#
# 사용법: plugin/skills/plan/test/pipeline-config.test.sh
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$TEST_DIR/../scripts/pipeline-config.sh"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${C_GREEN}✓${C_NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${C_RED}✗${C_NC} %s\n    %s\n" "$1" "${2:-}" >&2; }

# 키 값이 기대와 같은지 — assert_key <key> <expected> [PIPELINE_CONFIG경로]
assert_key() {
  local key="$1" expected="$2" cfg="${3:-$FIXTURE}"
  local actual
  actual="$(PIPELINE_CONFIG="$cfg" bash "$READER" "$key" 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then
    pass "$key == '$expected'"
  else
    fail "$key == '$expected'" "실제='$actual'"
  fi
}

# ── 픽스처 config 생성 ───────────────────────────────────────
FIXTURE="$(mktemp)"
cat > "$FIXTURE" <<'EOF'
project:
  owner: BlueOrg
  parent-repository: BlueOrg/MainRepo
  project-numbers: [7, 9]
  slack-channel: "#blue-alerts"

claude-commands:
  enabled: true
  project-name: BlueProject
  project-id: PVT_blue123
  status-field-id: PVTSSF_status9
  area-field-id: PVTSSF_area9
  local-account: blue-dev   # 무따옴표 값 뒤 인라인 주석 — 스트립되어야 함
  docs-context-dir: Docs/claude/context
  area-ids:
    Backend: aa11bb22
    iOS: cc33dd44
  plan:
    completeness-critic-enabled: true
    consistency-critic-enabled: false
    consistency-critic-dual-model: "false"
    # contract-doc-enabled 누락 → 기본 true 여야 함
EOF

echo ""
echo -e "${C_CYAN}══ pipeline-config.sh 단위 테스트 ══${C_NC}"

# ── project 스칼라 ──
assert_key owner BlueOrg
assert_key parent-repository BlueOrg/MainRepo
assert_key slack-channel "#blue-alerts"

# ── 파생 키 ──
assert_key parent-repo-name MainRepo
assert_key project-number 7

# ── claude-commands 스칼라 ──
assert_key project-name BlueProject
assert_key project-id PVT_blue123
assert_key status-field-id PVTSSF_status9
assert_key area-field-id PVTSSF_area9
assert_key local-account blue-dev
assert_key docs-context-dir Docs/claude/context

# ── area-id ──
assert_key area-id.Backend aa11bb22
assert_key area-id.iOS cc33dd44
assert_key area-id.Nonexistent ""

# ── plan 토글 ──
assert_key plan.completeness-critic-enabled true
assert_key plan.consistency-critic-enabled false
assert_key plan.consistency-critic-dual-model false   # 따옴표 "false" 도 false 로
assert_key plan.contract-doc-enabled true             # 누락 → 기본 true

# ── 알 수 없는 키 → 빈 값 (fail-soft) ──
assert_key bogus-key ""

# ── config 부재 → fail-soft (토글 기본 true, 나머지 빈 값) ──
MISSING="$(mktemp -u)/nope.yml"
assert_key owner "" "$MISSING"
assert_key plan.contract-doc-enabled true "$MISSING"

# ── --dump 동작 (owner 줄 포함) ──
if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --dump 2>/dev/null | grep -q "owner = BlueOrg"; then
  pass "--dump 에 owner=BlueOrg 포함"
else
  fail "--dump 출력" "owner 줄 없음"
fi

# ── install.sh parity — 실제 examples/reclip config 로 핵심값 ──
RECLIP="$TEST_DIR/../../../../examples/reclip/pipeline-config.yml"
if [ -f "$RECLIP" ]; then
  pname="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" project-name 2>/dev/null)"
  if [ "$pname" = "Reclip" ]; then
    pass "parity: examples/reclip project-name == 'Reclip'"
  else
    fail "parity: examples/reclip project-name" "실제='$pname'"
  fi
  beid="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" area-id.Backend 2>/dev/null)"
  if [ "$beid" = "7a506b5e" ]; then
    pass "parity: examples/reclip area-id.Backend == '7a506b5e'"
  else
    fail "parity: examples/reclip area-id.Backend" "실제='$beid'"
  fi
else
  printf "(parity 스킵 — %s 없음)\n" "$RECLIP"
fi

rm -f "$FIXTURE"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
