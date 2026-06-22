#!/usr/bin/env bash
# pipeline-config.test.sh — kickoff skill 의 config 리더(pipeline-config.sh) 단위 테스트.
#
# kickoff 리더는 review 리더와 byte-identical(공통 코어 + review 전용 4키 포함).
# 이 테스트는 (1) 스칼라/파생/area-id/plan 토글 회귀 + (2) review 전용 4키 +
# (3) #42 modules 인터페이스(module.<Name>.<flag>·--list-modules·--modules-where·
# --modules-table·기본값·대소문자·area-id resolve 순서·lead 다중 경고) 를 검증한다.
#
# 사용법: plugin/skills/kickoff/test/pipeline-config.test.sh
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

assert_dump_absent() {
  local pattern="$1" cfg="${2:-$FIXTURE}"
  if PIPELINE_CONFIG="$cfg" bash "$READER" --dump 2>/dev/null | grep -qF "$pattern"; then
    fail "--dump 에 '$pattern' 미노출" "노출됨(보안 위반)"
  else
    pass "--dump 에 '$pattern' 미노출"
  fi
}

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

# ── 픽스처 config 생성 ───────────────────────────────────────
FIXTURE="$(mktemp)"
cat > "$FIXTURE" <<'EOF'
project:
  owner: BlueOrg
  parent-repository: BlueOrg/MainRepo
  project-numbers: [7, 9]
  slack-channel: "#blue-alerts"

modules:
  - name: Alpha
    role: server
    ci-workflow-name: Alpha CI
    area-id: alpha-modid
    planner: true
    review: true
    kickoff: true
    lead: true
    default-status: Ready
  - name: Beta
    role: client
    ci-workflow-name: Beta CI
    cross-area-group: client
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
  reviewer-app-id: "9988776"
  reviewer-bot-slug: blue-review-bot
  reviewer-token-key: BLUE_REVIEW_BOT
  slack-token-key: BLUE_SLACK_WEBHOOK
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
EOF

echo ""
echo -e "${C_CYAN}══ kickoff pipeline-config.sh 단위 테스트 ══${C_NC}"

# ── (회귀) 스칼라/파생/area-id/plan 토글 ──
assert_key owner BlueOrg
assert_key parent-repo-name MainRepo
assert_key project-number 7
assert_key project-name BlueProject
assert_key local-account blue-dev
assert_key area-id.Backend aa11bb22
assert_key plan.consistency-critic-dual-model false
assert_key plan.contract-doc-enabled true

# ── review 전용 4키 (kickoff 리더는 review 와 byte-identical) ──
assert_key reviewer-app-id "9988776"
assert_key reviewer-token-key BLUE_REVIEW_BOT
assert_dump_absent "reviewer-app-id"
assert_dump_absent "BLUE_REVIEW_BOT"

# ── modules 인터페이스 (#42) ──
assert_mod Alpha role server
assert_mod Alpha ci-workflow-name "Alpha CI"
assert_mod Alpha lead true
assert_mod Alpha area-id alpha-modid       # modules 우선
assert_mod Beta planner true               # 누락 → 기본 true
assert_mod Beta lead false                 # 누락 → 기본 false
assert_mod Beta default-status Ready       # 누락 → 기본 Ready
assert_mod Beta cross-area-group client
assert_mod Gamma kickoff false
assert_mod Gamma default-status Backlog
assert_mod Gamma area-id gamma-legacy      # legacy 폴백
assert_mod Nonexistent planner ""

# 대소문자 구분
mismatch="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" module.ALPHA.role 2>/dev/null)"
[ -z "$mismatch" ] && pass "대소문자 구분: module.ALPHA.role == ''" || fail "대소문자 module.ALPHA.role" "실제='$mismatch'"

# area-id.<Name> resolve 순서
assert_key area-id.Alpha alpha-modid
assert_key area-id.Gamma gamma-legacy

# --list-modules 정의순
list_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
[ "$list_out" = "Alpha,Beta,Gamma," ] && pass "--list-modules == 'Alpha,Beta,Gamma'" || fail "--list-modules" "실제='$list_out'"

# --modules-where
wl="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where lead=true 2>/dev/null | tr '\n' ',')"
[ "$wl" = "Alpha," ] && pass "--modules-where lead=true == 'Alpha'" || fail "--modules-where lead=true" "실제='$wl'"
wk="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where kickoff=false 2>/dev/null | tr '\n' ',')"
[ "$wk" = "Gamma," ] && pass "--modules-where kickoff=false == 'Gamma'" || fail "--modules-where kickoff=false" "실제='$wk'"

# --modules-table 헤더 + Alpha 행
table_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-table 2>/dev/null)"
printf '%s\n' "$table_out" | head -1 | grep -q $'name\trole\tplanner' && pass "--modules-table 헤더행" || fail "--modules-table 헤더행" "첫줄='$(printf '%s\n' "$table_out" | head -1)'"
alpha_row="$(printf '%s\n' "$table_out" | grep '^Alpha')"
[ "$alpha_row" = $'Alpha\tserver\ttrue\ttrue\ttrue\ttrue\tReady\t\talpha-modid\tAlpha CI' ] && pass "--modules-table Alpha 행 정확" || fail "--modules-table Alpha 행" "실제='$alpha_row'"

# lead 다중 경고
MULTI_LEAD="$(mktemp)"
printf 'modules:\n  - name: One\n    lead: true\n  - name: Two\n    lead: true\n' > "$MULTI_LEAD"
ml_stderr="$(PIPELINE_CONFIG="$MULTI_LEAD" bash "$READER" --modules-table 2>&1 >/dev/null)"
printf '%s' "$ml_stderr" | grep -q "lead 모듈이 2개 이상" && pass "lead 다중 → stderr 경고" || fail "lead 다중 경고" "stderr='$ml_stderr'"
rm -f "$MULTI_LEAD"

# modules-table 값은 --dump 에 노출 안 됨
assert_dump_absent "Alpha CI"
assert_dump_absent "alpha-modid"

# ── config 부재 fail-soft ──
MISSING="$(mktemp -u)/nope.yml"
assert_key owner "" "$MISSING"
# config 부재 + --modules-table → 헤더행만(빈 모듈)
mt_missing="$(PIPELINE_CONFIG="$MISSING" bash "$READER" --modules-table 2>/dev/null)"
if [ "$(printf '%s\n' "$mt_missing" | wc -l | tr -d ' ')" = "1" ] && printf '%s' "$mt_missing" | grep -q $'name\trole'; then
  pass "config 부재 --modules-table → 헤더행만"
else
  fail "config 부재 --modules-table" "실제='$mt_missing'"
fi

# ── 빈 스칼라 흡수 회귀 (이중리뷰 버그) ─────────────────────────────────
# 빈 스칼라 필드(area-id/role/default-status/cross-area-group/ci-workflow-name)가
# 다음 줄 키를 값으로 흡수하면 안 된다. (\s* 가 개행을 먹는 버그 — [ \t]* 로 수정.)
EMPTY_ABSORB="$(mktemp)"
cat > "$EMPTY_ABSORB" <<'EOF'
modules:
  - name: Alpha
    area-id:
    role:
    default-status:
    cross-area-group:
    ci-workflow-name:
    planner:
    lead: false
claude-commands:
  area-ids:
    Alpha: legacyfallback
EOF
ea_modid="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.area-id 2>/dev/null)"
[ "$ea_modid" = "legacyfallback" ] && pass "빈 area-id → legacy 폴백(흡수 안 함)" || fail "빈 area-id legacy 폴백" "실제='$ea_modid'"
ea_legacy="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" area-id.Alpha 2>/dev/null)"
[ "$ea_legacy" = "legacyfallback" ] && pass "빈 area-id.Alpha → legacy 폴백" || fail "area-id.Alpha legacy 폴백" "실제='$ea_legacy'"
ea_role="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.role 2>/dev/null)"
[ -z "$ea_role" ] && pass "빈 role → 빈 값(흡수 안 함)" || fail "빈 role 비흡수" "실제='$ea_role'"
ea_ds="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.default-status 2>/dev/null)"
[ "$ea_ds" = "Ready" ] && pass "빈 default-status → 기본 Ready(흡수 안 함)" || fail "빈 default-status 기본값" "실제='$ea_ds'"
ea_cg="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.cross-area-group 2>/dev/null)"
[ -z "$ea_cg" ] && pass "빈 cross-area-group → 빈 값(흡수 안 함)" || fail "빈 cross-area-group 비흡수" "실제='$ea_cg'"
ea_ci="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.ci-workflow-name 2>/dev/null)"
[ -z "$ea_ci" ] && pass "빈 ci-workflow-name → 빈 값(흡수 안 함)" || fail "빈 ci-workflow-name 비흡수" "실제='$ea_ci'"
ea_planner="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.planner 2>/dev/null)"
[ "$ea_planner" = "true" ] && pass "빈 planner → 기본 true" || fail "빈 planner 기본값" "실제='$ea_planner'"
rm -f "$EMPTY_ABSORB"

# ── install.sh parity — 실제 examples/reclip config 모듈 의미론 골든 ──
RECLIP="$TEST_DIR/../../../../examples/reclip/pipeline-config.yml"
if [ -f "$RECLIP" ]; then
  rb="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" module.Backend.lead 2>/dev/null)"
  [ "$rb" = "true" ] && pass "parity: reclip Backend lead==true" || fail "parity: reclip Backend lead" "실제='$rb'"
  dk="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" module.Design.kickoff 2>/dev/null)"
  [ "$dk" = "false" ] && pass "parity: reclip Design kickoff==false" || fail "parity: reclip Design kickoff" "실제='$dk'"
  ds="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" module.Design.default-status 2>/dev/null)"
  [ "$ds" = "Backlog" ] && pass "parity: reclip Design default-status==Backlog" || fail "parity: reclip Design default-status" "실제='$ds'"
  cg="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" --modules-where cross-area-group=client 2>/dev/null | tr '\n' ',')"
  [ "$cg" = "Frontend,iOS,Android," ] && pass "parity: reclip client 그룹" || fail "parity: reclip client 그룹" "실제='$cg'"
  ba="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" area-id.Backend 2>/dev/null)"
  [ "$ba" = "7a506b5e" ] && pass "parity: reclip area-id.Backend==7a506b5e" || fail "parity: reclip area-id.Backend" "실제='$ba'"
else
  printf "(parity 스킵 — %s 없음)\n" "$RECLIP"
fi

rm -f "$FIXTURE"


# ── 인라인 주석 내성 회귀 (#52) ─────────────────────────────────────
# modules 블록의 줄끝 강제(\s*$) 추출이 인라인 주석에서 값을 통째로 잃지 않는지.
# 점검 필드: - name / ci-workflow-name / area-id(modules) / area-ids(legacy 맵).
# (이 fail 은 수정 전 패턴 `"?([^"#\n]+)"?\s*$` 에서 모듈/값이 사라지는 footgun.)
INLINE_FIX="$(mktemp)"
cat > "$INLINE_FIX" <<'EOF'
project:
  owner: RedOrg
modules:
  - name: Backend  # 인라인 주석
    ci-workflow-name: Backend CI  # 인라인 주석
    area-id: be-mod  # 주석
  - name: iOS
    ci-workflow-name: iOS CI
claude-commands:
  enabled: true
  area-ids:
    Frontend: fe-legacy  # 주석
EOF
# name 인라인 주석 → 모듈 비소실 (--list-modules 에 Backend·iOS 둘 다)
ic_list="$(PIPELINE_CONFIG="$INLINE_FIX" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
[ "$ic_list" = "Backend,iOS," ] && pass "인라인주석 name → 모듈 비소실(--list-modules)" || fail "인라인주석 name 모듈 소실" "실제='$ic_list'"
# ci-workflow-name 인라인 주석 → 값 보존
assert_key module.Backend.ci-workflow-name "Backend CI" "$INLINE_FIX"
# modules area-id 인라인 주석 → 값 보존
assert_key module.Backend.area-id be-mod "$INLINE_FIX"
assert_key area-id.Backend be-mod "$INLINE_FIX"
# legacy area-ids 맵 인라인 주석 → 값 보존(폴백)
assert_key area-id.Frontend fe-legacy "$INLINE_FIX"
# 대조군: 주석 없는 iOS 정상
assert_key module.iOS.ci-workflow-name "iOS CI" "$INLINE_FIX"
rm -f "$INLINE_FIX"

# ── 따옴표 값 + 인라인 주석 / 하이픈 키 parity 회귀 (#52 이중리뷰) ─────────────
# get_scalar_in 따옴표 분기 `"([^"\n]*)"\s*$` 가 `key: "X"  # 주석` 에서 뒤 주석 때문에
# 매칭 실패 → 무따옴표 폴백이 빈 캡처로 값 소실. + legacy area-ids 하이픈 키.
# (이 fail 은 따옴표 분기 수정/하이픈 키 패턴 되돌리면 빈값으로 재현.)
QC_FIX="$(mktemp)"
cat > "$QC_FIX" <<'EOF'
project:
  owner: "RedOrg"  # 따옴표+주석
  slack-channel: "#blue-alerts"  # 따옴표 안 # 보존 + 뒤 주석
modules:
  - name: Backend
    ci-workflow-name: "Backend CI"  # 따옴표+주석
    area-id: "be-mod"  # 따옴표+주석
claude-commands:
  enabled: true
  project-name: "Blue Proj"  # 따옴표+주석
  area-ids:
    Frontend-1: feh   # 하이픈 키 + 주석
EOF
# 따옴표+주석 스칼라 — 값 보존
assert_key owner RedOrg "$QC_FIX"
assert_key project-name "Blue Proj" "$QC_FIX"
# 대조군: 따옴표 안 # 은 그대로
assert_key slack-channel "#blue-alerts" "$QC_FIX"
# per-module 따옴표+주석 (리더 get_scalar_in 경로)
assert_key module.Backend.ci-workflow-name "Backend CI" "$QC_FIX"
assert_key module.Backend.area-id be-mod "$QC_FIX"
# 하이픈 legacy area-ids 키
assert_key area-id.Frontend-1 feh "$QC_FIX"
rm -f "$QC_FIX"
echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
