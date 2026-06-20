#!/usr/bin/env bash
# pipeline-config.test.sh — review skill 의 config 리더(pipeline-config.sh) 단위 테스트.
#
# 이 리더는 plan skill 의 동명 리더 복사본 + review 전용 4키 추가 버전이다.
# 따라서 (1) 복사된 기존 키들이 회귀 없이 동작하는지 + (2) 신규 4키가 install.sh
# parse_config() 와 동일 경로(claude-commands.<key>)로 읽히는지 + (3) 신규 4키가
# --dump(LLM 컨텍스트 요약)에 노출되지 않는지 + (4) fail-soft 를 검증한다.
#
# 사용법: plugin/skills/review/test/pipeline-config.test.sh
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

# --dump 출력에 특정 패턴이 "없어야" 함을 검증 — assert_dump_absent <pattern> [cfg]
assert_dump_absent() {
  local pattern="$1" cfg="${2:-$FIXTURE}"
  if PIPELINE_CONFIG="$cfg" bash "$READER" --dump 2>/dev/null | grep -qF "$pattern"; then
    fail "--dump 에 '$pattern' 미노출" "노출됨(보안 위반)"
  else
    pass "--dump 에 '$pattern' 미노출"
  fi
}

# ── 픽스처 config 생성 ───────────────────────────────────────
# plan 픽스처 + review 전용 4키를 합성한 값. (실제 시크릿 아님 — env 이름표/합성값만)
FIXTURE="$TEST_DIR/fixtures/full.yml"

echo ""
echo -e "${C_CYAN}══ review pipeline-config.sh 단위 테스트 ══${C_NC}"

# ── (회귀) project 스칼라 — 복사 원본 동작 유지 ──
assert_key owner BlueOrg
assert_key parent-repository BlueOrg/MainRepo
assert_key slack-channel "#blue-alerts"

# ── (회귀) 파생 키 ──
assert_key parent-repo-name MainRepo
assert_key project-number 7

# ── (회귀) claude-commands 스칼라 ──
assert_key project-name BlueProject
assert_key project-id PVT_blue123
assert_key status-field-id PVTSSF_status9
assert_key area-field-id PVTSSF_area9
assert_key local-account blue-dev
assert_key docs-context-dir Docs/claude/context

# ── (회귀) area-id ──
assert_key area-id.Backend aa11bb22
assert_key area-id.iOS cc33dd44
assert_key area-id.Nonexistent ""

# ── (회귀) plan 토글 ──
assert_key plan.completeness-critic-enabled true
assert_key plan.consistency-critic-enabled false
assert_key plan.consistency-critic-dual-model false   # 따옴표 "false" 도 false 로
assert_key plan.contract-doc-enabled true             # 누락 → 기본 true

# ── ★ 신규 review 전용 4키 — round-trip (합성 픽스처) ──
assert_key reviewer-app-id "9988776"
assert_key reviewer-bot-slug blue-review-bot
assert_key reviewer-token-key BLUE_REVIEW_BOT
assert_key slack-token-key BLUE_SLACK_WEBHOOK

# ── (회귀) 알 수 없는 키 → 빈 값 (fail-soft) ──
assert_key bogus-key ""

# ── (회귀+신규) config 부재 → fail-soft (토글 기본 true, 나머지 빈 값) ──
MISSING="$(mktemp -u)/nope.yml"
assert_key owner "" "$MISSING"
assert_key plan.contract-doc-enabled true "$MISSING"
# 신규 4키도 config 부재 시 빈 값 (fail-soft, exit 0)
assert_key reviewer-app-id "" "$MISSING"
assert_key reviewer-token-key "" "$MISSING"

# ── 신규 4키 fail-soft: config 는 있으나 키 부재 → 빈 값 + exit 0 ──
NO_REVIEW="$(mktemp)"
printf 'project:\n  owner: OnlyOwner\nclaude-commands:\n  enabled: true\n' > "$NO_REVIEW"
for k in reviewer-app-id reviewer-bot-slug reviewer-token-key slack-token-key; do
  out="$(PIPELINE_CONFIG="$NO_REVIEW" bash "$READER" "$k" 2>/dev/null)"; rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    pass "fail-soft: $k 부재 → 빈 값 + exit 0"
  else
    fail "fail-soft: $k 부재" "out='$out' rc=$rc"
  fi
done
rm -f "$NO_REVIEW"

# ── (회귀) --dump 동작 (owner 줄 포함) ──
if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --dump 2>/dev/null | grep -q "owner = BlueOrg"; then
  pass "--dump 에 owner=BlueOrg 포함"
else
  fail "--dump 출력" "owner 줄 없음"
fi
for dk in "author-login = test-bot" "parent-repository = BlueOrg/MainRepo" "slack-channel = #blue-alerts"; do
  if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --dump 2>/dev/null | grep -qF "$dk"; then
    pass "--dump 에 '$dk' 포함"
  else
    fail "--dump '$dk'" "누락"
  fi
done

# ── ★ 보안: 신규 4키는 --dump 에 노출되지 않아야 함 ──
# 키 이름 자체가 dump 줄로 등장하지 않는지 + 합성값이 새지 않는지 둘 다 확인.
assert_dump_absent "reviewer-app-id"
assert_dump_absent "reviewer-bot-slug"
assert_dump_absent "reviewer-token-key"
assert_dump_absent "slack-token-key"
assert_dump_absent "9988776"            # reviewer-app-id 값
assert_dump_absent "blue-review-bot"    # reviewer-bot-slug 값
assert_dump_absent "BLUE_REVIEW_BOT"    # reviewer-token-key 값
assert_dump_absent "BLUE_SLACK_WEBHOOK" # slack-token-key 값

# ── 신규 4키는 --keys 카탈로그에는 노출되어야 함 (접근 가능 키 안내용) ──
for kk in reviewer-app-id reviewer-bot-slug reviewer-token-key slack-token-key; do
  if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --keys 2>/dev/null | grep -qx "$kk"; then
    pass "--keys 에 '$kk' 노출"
  else
    fail "--keys '$kk'" "누락"
  fi
done

# ── (회귀) --require (필수 키 fail-fast 게이트) ──
if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --require owner parent-repo-name project-id author-login >/dev/null 2>&1; then
  pass "--require: 모든 필수 키 존재 → exit 0"
else
  fail "--require 정상 키" "exit != 0"
fi
# 신규 4키도 --require 게이트로 검증 가능해야 함 (전부 존재 → exit 0)
if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --require reviewer-app-id reviewer-bot-slug reviewer-token-key slack-token-key >/dev/null 2>&1; then
  pass "--require: 신규 4키 전부 존재 → exit 0"
else
  fail "--require 신규 4키" "exit != 0"
fi
# 빈 키 포함 → exit 1
EMPTY_FIX="$(mktemp)"; printf 'project:\n  owner: OnlyOwner\n' > "$EMPTY_FIX"
if PIPELINE_CONFIG="$EMPTY_FIX" bash "$READER" --require owner reviewer-token-key >/dev/null 2>&1; then
  fail "--require 빈 키" "reviewer-token-key 비었는데 exit 0"
else
  pass "--require: 빈 필수 키(reviewer-token-key) → exit 1"
fi
rm -f "$EMPTY_FIX"
# config 부재 + --require → exit 1
if PIPELINE_CONFIG="$(mktemp -u)/none.yml" bash "$READER" --require owner >/dev/null 2>&1; then
  fail "--require config 부재" "exit 0 (게이트 무력)"
else
  pass "--require: config 부재 → exit 1"
fi

# ── install.sh parity — 실제 examples/reclip config 로 신규 4키 값 ──
# (런타임 읽은 값 == install.sh 가 치환했을 값 임을 실제 설정 파일로 확인)
RECLIP="$TEST_DIR/../../../../examples/reclip/pipeline-config.yml"
if [ -f "$RECLIP" ]; then
  declare -a RECLIP_EXPECT=(
    "project-name:Reclip"
    "area-id.Backend:7a506b5e"
    "reviewer-app-id:3569774"
    "reviewer-bot-slug:reclip-review-bot"
    "reviewer-token-key:RECLIP_REVIEW_BOT"
    "slack-token-key:RECLIP_SLACK_WEBHOOK"
  )
  for pair in "${RECLIP_EXPECT[@]}"; do
    k="${pair%%:*}"; exp="${pair#*:}"
    act="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" "$k" 2>/dev/null)"
    if [ "$act" = "$exp" ]; then
      pass "parity: examples/reclip $k == '$exp'"
    else
      fail "parity: examples/reclip $k" "실제='$act'"
    fi
  done
else
  printf "(parity 스킵 — %s 없음)\n" "$RECLIP"
fi

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
