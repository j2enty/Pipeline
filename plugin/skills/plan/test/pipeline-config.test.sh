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

modules:
  # Alpha — lead·전 플래그 명시. area-id 는 modules 에 명시(legacy 폴백보다 우선 검증).
  - name: Alpha
    role: server
    ci-workflow-name: Alpha CI
    area-id: alpha-modid
    planner: true
    review: true
    kickoff: true
    lead: true
    default-status: Ready
  # Beta — 플래그 전부 누락 → 기본값(planner/review/kickoff true·lead false·status Ready)
  - name: Beta
    role: client
    ci-workflow-name: Beta CI
    cross-area-group: client
  # Gamma — 동작 제외 영역(planner/review/kickoff false·Backlog). area-id 는 legacy 맵 폴백.
  - name: Gamma
    role: design
    planner: false
    review: false
    kickoff: false
    default-status: Backlog

claude-commands:
  enabled: true
  project-name: BlueProject
  project-id: PVT_blue123
  status-field-id: PVTSSF_status9
  area-field-id: PVTSSF_area9
  author-login: test-bot
  local-account: blue-dev   # 무따옴표 값 뒤 인라인 주석 — 스트립되어야 함
  docs-context-dir: Docs/claude/context
  area-ids:
    Backend: aa11bb22
    iOS: cc33dd44
    Gamma: gamma-legacy
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
# --dump 에 author-login·parent-repository·slack-channel 포함 (리뷰 보강)
for dk in "author-login = test-bot" "parent-repository = BlueOrg/MainRepo" "slack-channel = #blue-alerts"; do
  if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --dump 2>/dev/null | grep -qF "$dk"; then
    pass "--dump 에 '$dk' 포함"
  else
    fail "--dump '$dk'" "누락"
  fi
done

# ── --require (필수 키 fail-fast 게이트) ──
if PIPELINE_CONFIG="$FIXTURE" bash "$READER" --require owner parent-repo-name project-id author-login >/dev/null 2>&1; then
  pass "--require: 모든 필수 키 존재 → exit 0"
else
  fail "--require 정상 키" "exit != 0"
fi
# 빈 키 포함 → exit 1 (픽스처에 없는 키)
EMPTY_FIX="$(mktemp)"; printf 'project:\n  owner: OnlyOwner\n' > "$EMPTY_FIX"
if PIPELINE_CONFIG="$EMPTY_FIX" bash "$READER" --require owner project-id >/dev/null 2>&1; then
  fail "--require 빈 키" "project-id 비었는데 exit 0"
else
  pass "--require: 빈 필수 키(project-id) → exit 1"
fi
rm -f "$EMPTY_FIX"
# config 부재 + --require → exit 1
if PIPELINE_CONFIG="$(mktemp -u)/none.yml" bash "$READER" --require owner >/dev/null 2>&1; then
  fail "--require config 부재" "exit 0 (게이트 무력)"
else
  pass "--require: config 부재 → exit 1"
fi

# ── modules 인터페이스 (#42 데이터층) ────────────────────────────────
# module.<Name>.<flag> 단일값 / 기본값 / 대소문자 / area-id resolve 순서 /
# --list-modules 순서 / --modules-where / --modules-table / lead 다중 경고.

# 단일 모듈 플래그 — assert_mod <Name> <flag> <expected>
assert_mod() {
  local name="$1" flag="$2" expected="$3"
  local actual
  actual="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" "module.$name.$flag" 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then
    pass "module.$name.$flag == '$expected'"
  else
    fail "module.$name.$flag == '$expected'" "실제='$actual'"
  fi
}

# 전 플래그 명시(Alpha)
assert_mod Alpha role server
assert_mod Alpha ci-workflow-name "Alpha CI"
assert_mod Alpha lead true
assert_mod Alpha planner true
assert_mod Alpha default-status Ready
# area-id: modules[].area-id 우선
assert_mod Alpha area-id alpha-modid

# 기본값(Beta — 플래그 누락)
assert_mod Beta planner true        # 누락 → 기본 true
assert_mod Beta review true
assert_mod Beta kickoff true
assert_mod Beta lead false           # 누락 → 기본 false
assert_mod Beta default-status Ready # 누락 → 기본 Ready
assert_mod Beta cross-area-group client

# 동작 제외(Gamma — false 명시 + Backlog)
assert_mod Gamma planner false
assert_mod Gamma review false
assert_mod Gamma kickoff false
assert_mod Gamma default-status Backlog
# area-id: modules 에 없음 → legacy area-ids 맵 폴백
assert_mod Gamma area-id gamma-legacy

# 대소문자 구분 — module.Alpha 동작 / module.ALPHA 빈값
assert_mod Alpha role server
mismatch="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" module.ALPHA.role 2>/dev/null)"
if [ -z "$mismatch" ]; then
  pass "대소문자 구분: module.ALPHA.role == '' (Alpha≠ALPHA)"
else
  fail "대소문자 구분: module.ALPHA.role" "실제='$mismatch'"
fi

# 부재 모듈 → 빈 값(fail-soft)
assert_mod Nonexistent planner ""

# area-id.<Name> 친화 키도 동일 resolve 순서(modules 우선 → legacy 폴백)
assert_key area-id.Alpha alpha-modid   # modules 우선
assert_key area-id.Gamma gamma-legacy  # legacy 폴백
assert_key area-id.Backend aa11bb22    # modules 미정의 → legacy

# --list-modules — 정의(나열)순 보존
list_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
if [ "$list_out" = "Alpha,Beta,Gamma," ]; then
  pass "--list-modules 정의순 == 'Alpha,Beta,Gamma'"
else
  fail "--list-modules 정의순" "실제='$list_out'"
fi

# --modules-where lead=true → Alpha 만
where_lead="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where lead=true 2>/dev/null | tr '\n' ',')"
if [ "$where_lead" = "Alpha," ]; then
  pass "--modules-where lead=true == 'Alpha'"
else
  fail "--modules-where lead=true" "실제='$where_lead'"
fi

# --modules-where review=true → Alpha,Beta (Gamma 는 false)
where_review="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where review=true 2>/dev/null | tr '\n' ',')"
if [ "$where_review" = "Alpha,Beta," ]; then
  pass "--modules-where review=true == 'Alpha,Beta'"
else
  fail "--modules-where review=true" "실제='$where_review'"
fi

# --modules-where kickoff=false → Gamma
where_kf="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where kickoff=false 2>/dev/null | tr '\n' ',')"
if [ "$where_kf" = "Gamma," ]; then
  pass "--modules-where kickoff=false == 'Gamma'"
else
  fail "--modules-where kickoff=false" "실제='$where_kf'"
fi

# --modules-table — 헤더행 + 모듈별 1줄 (Alpha lead=true 칸 확인)
table_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-table 2>/dev/null)"
if printf '%s\n' "$table_out" | head -1 | grep -q $'name\trole\tplanner'; then
  pass "--modules-table 헤더행 존재"
else
  fail "--modules-table 헤더행" "실제 첫줄='$(printf '%s\n' "$table_out" | head -1)'"
fi
alpha_row="$(printf '%s\n' "$table_out" | grep '^Alpha')"
# name role planner review kickoff lead default-status cross-area-group area-id ci-workflow-name
if [ "$alpha_row" = $'Alpha\tserver\ttrue\ttrue\ttrue\ttrue\tReady\t\talpha-modid\tAlpha CI' ]; then
  pass "--modules-table Alpha 행 정확"
else
  fail "--modules-table Alpha 행" "실제='$alpha_row'"
fi

# lead 다중 경고 — Alpha+추가 lead 픽스처로 stderr 경고 확인
MULTI_LEAD="$(mktemp)"
cat > "$MULTI_LEAD" <<'EOF'
modules:
  - name: One
    lead: true
  - name: Two
    lead: true
EOF
ml_stderr="$(PIPELINE_CONFIG="$MULTI_LEAD" bash "$READER" --modules-table 2>&1 >/dev/null)"
if printf '%s' "$ml_stderr" | grep -q "lead 모듈이 2개 이상"; then
  pass "lead 다중 → stderr 경고"
else
  fail "lead 다중 경고" "stderr='$ml_stderr'"
fi
rm -f "$MULTI_LEAD"

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
  # 모듈 의미론 골든 — Backend lead / Design 동작제외·Backlog
  rb_lead="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" module.Backend.lead 2>/dev/null)"
  [ "$rb_lead" = "true" ] && pass "parity: reclip Backend lead==true" || fail "parity: reclip Backend lead" "실제='$rb_lead'"
  for f in planner review kickoff; do
    v="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" "module.Design.$f" 2>/dev/null)"
    [ "$v" = "false" ] && pass "parity: reclip Design $f==false" || fail "parity: reclip Design $f" "실제='$v'"
  done
  ds="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" module.Design.default-status 2>/dev/null)"
  [ "$ds" = "Backlog" ] && pass "parity: reclip Design default-status==Backlog" || fail "parity: reclip Design default-status" "실제='$ds'"
  # client cross-area-group 3개
  cg="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" --modules-where cross-area-group=client 2>/dev/null | tr '\n' ',')"
  [ "$cg" = "Frontend,iOS,Android," ] && pass "parity: reclip client 그룹==Frontend,iOS,Android" || fail "parity: reclip client 그룹" "실제='$cg'"
else
  printf "(parity 스킵 — %s 없음)\n" "$RECLIP"
fi

rm -f "$FIXTURE"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
