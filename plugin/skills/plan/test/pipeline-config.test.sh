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

# ── cross-check-tool (외부 2차 의견 도구 — 기본 codex) ──
# 픽스처엔 키가 없으므로 기본값 codex 여야 한다.
assert_key cross-check-tool codex
# config 에 명시되면 그 값(gemini) 반환
CCT_FIX="$(mktemp)"; printf 'claude-commands:\n  cross-check-tool: gemini\n' > "$CCT_FIX"
assert_key cross-check-tool gemini "$CCT_FIX"
rm -f "$CCT_FIX"
# 명시적 빈 따옴표("")·빈값도 codex 폴백 — "항상 비지 않은 도구명" 불변식(빈따옴표 회귀 잠금, finder 반영)
CCT_EMPTY="$(mktemp)"; printf 'claude-commands:\n  cross-check-tool: ""\n' > "$CCT_EMPTY"
assert_key cross-check-tool codex "$CCT_EMPTY"
rm -f "$CCT_EMPTY"
# config 파일 부재 시에도 기본값 codex (빈 값 아님 — 다른 claude-commands 스칼라와 다름)
CCT_MISSING="$(mktemp -u)/none.yml"
assert_key cross-check-tool codex "$CCT_MISSING"

# ── codex-model / codex-reasoning-effort (plan codex exec + review codex review 교차검증 공통 통합 키 — #83) ──
# cross-check-tool 과 달리 빈값 기본 스칼라다(다른 claude-commands 빈값 스칼라와 동일).
# 픽스처엔 키가 없으므로 기본 빈값이어야 한다(빈값이면 SKILL 이 codex 플래그 미부착 → codex 기본).
assert_key codex-model ""
assert_key codex-reasoning-effort ""
# config 에 명시되면 그 값 반환 (주입 모델명은 real 모델명 회피 — 리더 동작만 검증)
CRM_FIX="$(mktemp)"; printf 'claude-commands:\n  codex-model: model-x\n  codex-reasoning-effort: high\n' > "$CRM_FIX"
assert_key codex-model model-x "$CRM_FIX"
assert_key codex-reasoning-effort high "$CRM_FIX"
rm -f "$CRM_FIX"
# config 파일 부재 시에도 빈값 (cross-check-tool 과 달리 폴백 기본값 없음)
CRM_MISSING="$(mktemp -u)/none.yml"
assert_key codex-model "" "$CRM_MISSING"
assert_key codex-reasoning-effort "" "$CRM_MISSING"

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
# area-id 빈 필드 → 다음 줄 키 흡수 안 함 + legacy 맵으로 폴백
ea_modid="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.area-id 2>/dev/null)"
[ "$ea_modid" = "legacyfallback" ] && pass "빈 area-id → legacy 폴백(흡수 안 함)" || fail "빈 area-id legacy 폴백" "실제='$ea_modid'"
# 친화 키 area-id.Alpha 도 동일
ea_legacy="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" area-id.Alpha 2>/dev/null)"
[ "$ea_legacy" = "legacyfallback" ] && pass "빈 area-id.Alpha → legacy 폴백" || fail "area-id.Alpha legacy 폴백" "실제='$ea_legacy'"
# role/default-status/cross-area-group 빈 필드 → 다음 줄 비흡수(기본값/빈값)
ea_role="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.role 2>/dev/null)"
[ -z "$ea_role" ] && pass "빈 role → 빈 값(흡수 안 함)" || fail "빈 role 비흡수" "실제='$ea_role'"
ea_ds="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.default-status 2>/dev/null)"
[ "$ea_ds" = "Ready" ] && pass "빈 default-status → 기본 Ready(흡수 안 함)" || fail "빈 default-status 기본값" "실제='$ea_ds'"
ea_cg="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.cross-area-group 2>/dev/null)"
[ -z "$ea_cg" ] && pass "빈 cross-area-group → 빈 값(흡수 안 함)" || fail "빈 cross-area-group 비흡수" "실제='$ea_cg'"
ea_ci="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.ci-workflow-name 2>/dev/null)"
[ -z "$ea_ci" ] && pass "빈 ci-workflow-name → 빈 값(흡수 안 함)" || fail "빈 ci-workflow-name 비흡수" "실제='$ea_ci'"
# boolean 빈 필드 → 기본값 (앵커가 (true|false) 라 원래 흡수 안 하지만 확인)
ea_planner="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.planner 2>/dev/null)"
[ "$ea_planner" = "true" ] && pass "빈 planner → 기본 true" || fail "빈 planner 기본값" "실제='$ea_planner'"
ea_lead="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Alpha.lead 2>/dev/null)"
[ "$ea_lead" = "false" ] && pass "lead: false 정상(흡수 영향 없음)" || fail "lead false" "실제='$ea_lead'"
rm -f "$EMPTY_ABSORB"

# ── install.sh parity — 실제 projects/reclip config 로 핵심값 ──
RECLIP="$TEST_DIR/../../../../projects/reclip/pipeline-config.yml"
if [ -f "$RECLIP" ]; then
  pname="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" project-name 2>/dev/null)"
  if [ "$pname" = "Reclip" ]; then
    pass "parity: projects/reclip project-name == 'Reclip'"
  else
    fail "parity: projects/reclip project-name" "실제='$pname'"
  fi
  beid="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" area-id.Backend 2>/dev/null)"
  if [ "$beid" = "7a506b5e" ]; then
    pass "parity: projects/reclip area-id.Backend == '7a506b5e'"
  else
    fail "parity: projects/reclip area-id.Backend" "실제='$beid'"
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
  # codex 교차검증 공통 모델·effort 주입값 (#83 통합 키) — Reclip 은 더 강한 모델 명시
  crm="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" codex-model 2>/dev/null)"
  [ "$crm" = "gpt-5.5" ] && pass "parity: reclip codex-model==gpt-5.5" || fail "parity: reclip codex-model" "실제='$crm'"
  cre="$(PIPELINE_CONFIG="$RECLIP" bash "$READER" codex-reasoning-effort 2>/dev/null)"
  [ "$cre" = "high" ] && pass "parity: reclip codex-reasoning-effort==high" || fail "parity: reclip codex-reasoning-effort" "실제='$cre'"
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

# ── 따옴표 값 안 # 보존 회귀 (#57) ──────────────────────────────────
# modules 블록 전용 추출(name / legacy area-ids)이 따옴표로 감싼 값 안의 # 를
# 주석으로 오인해 자르면 안 된다(`name: "a#b"` → 'a#b'). 무따옴표 인라인 주석은 유지.
H57_FIX="$(mktemp)"
cat > "$H57_FIX" <<'EOF'
project:
  owner: RedOrg
modules:
  - name: "a#b"
    ci-workflow-name: "CI#1"
    area-id: "h#1"
  - name: Plain  # 무따옴표 인라인 주석(유지)
    area-id: pid  # 주석
claude-commands:
  enabled: true
  area-ids:
    Frontend: "v#1"
    Legacy: lv1  # 주석
EOF
# 따옴표 안 # 보존 — module_blocks name (a#b 가 살아있어야 module.a#b.* 도 동작)
h57_list="$(PIPELINE_CONFIG="$H57_FIX" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
[ "$h57_list" = "a#b,Plain," ] && pass "따옴표 안 # 보존: --list-modules == 'a#b,Plain'" || fail "따옴표 안 # name 보존" "실제='$h57_list'"
# per-module 따옴표 안 # (리더 get_scalar_in 경로 — 이미 보존이지만 parity 확인)
assert_key "module.a#b.ci-workflow-name" "CI#1" "$H57_FIX"
assert_key "module.a#b.area-id" "h#1" "$H57_FIX"
# legacy area-ids 맵 따옴표 안 # 보존
assert_key area-id.Frontend "v#1" "$H57_FIX"
# 무따옴표 인라인 주석 무회귀(#52)
assert_key area-id.Legacy lv1 "$H57_FIX"
assert_key module.Plain.area-id pid "$H57_FIX"
rm -f "$H57_FIX"

# ── 빈 따옴표 '' / "" parity 회귀 (#57 후속, Claude major) ─────────────
# 빈 단일/이중 따옴표가 리터럴 ''(2글자)로 새면 안 된다 — 빈값이어야 함.
# 또 모듈 area-id: '' + legacy area-ids 폴백 동시 존재 시 '' 가 legacy 를 덮으면 안 됨.
EQ_FIX="$(mktemp)"
cat > "$EQ_FIX" <<'EOF'
project:
  owner: RedOrg
modules:
  - name: Backend
    area-id: ''
    ci-workflow-name: ''
  - name: Admin
    area-id: ""
claude-commands:
  enabled: true
  area-ids:
    Backend: belegacy
    KSingle: ''
    KDouble: ""
EOF
# 빈 따옴표 → 빈값(리터럴 '' 아님). 모듈 area-id '' + legacy → legacy 폴백.
assert_key module.Backend.area-id belegacy "$EQ_FIX"   # '' 가 legacy 안 덮음
assert_key module.Backend.ci-workflow-name "" "$EQ_FIX" # '' → 빈값
assert_key module.Admin.area-id "" "$EQ_FIX"            # "" → 빈값(legacy 없음)
assert_key area-id.KSingle "" "$EQ_FIX"                 # 맵 '' → 빈값(리터럴 '' 아님)
assert_key area-id.KDouble "" "$EQ_FIX"                 # 맵 "" → 빈값
rm -f "$EQ_FIX"

# ── 미종결 따옴표 모듈 — stderr 경고(조용한 누락 방지, #57 minor) ──────────
MW_FIX="$(mktemp)"
printf 'modules:\n  - name: "ab\n  - name: Good\n' > "$MW_FIX"
mw_list="$(PIPELINE_CONFIG="$MW_FIX" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
[ "$mw_list" = "Good," ] && pass "미종결 따옴표: 정상 모듈(Good)은 유지" || fail "미종결 따옴표 정상모듈 유지" "실제='$mw_list'"
mw_err="$(PIPELINE_CONFIG="$MW_FIX" bash "$READER" --list-modules 2>&1 >/dev/null)"
printf '%s' "$mw_err" | grep -q "모듈 name 파싱 실패" && pass "미종결 따옴표: stderr 경고 발생" || fail "미종결 따옴표 stderr 경고" "stderr='$mw_err'"
rm -f "$MW_FIX"

# ── --keys 정적 카탈로그 회귀 (#45) ─────────────────────────────────────
# --keys 는 "지원키 목록"이라 config 유무와 무관하게 항상 동일 출력해야 한다.
# (수정 전 버그: config 부재 분기 `--keys|--dump) : ;;` 가 --keys 를 빈 출력으로 만듦.)
# 반대로 --dump 는 config 내용 요약이라 부재 시 빈 출력이 맞다(건드리면 안 됨).
KEYS_MISSING="$(mktemp -u)/none.yml"
# FIXTURE 는 위에서 rm 됐으므로 config 존재 케이스용 임시 config 를 새로 만든다(있음/없음 동일성만 보면 됨).
KEYS_FIX="$(mktemp)"; printf 'project:\n  owner: K\n' > "$KEYS_FIX"
keys_with="$(PIPELINE_CONFIG="$KEYS_FIX" bash "$READER" --keys 2>/dev/null)"
keys_without="$(PIPELINE_CONFIG="$KEYS_MISSING" bash "$READER" --keys 2>/dev/null)"
[ -n "$keys_without" ] && pass "--keys: config 부재에도 비어있지 않음(#45)" || fail "--keys config 부재 비어있음" "출력=''"
[ "$keys_with" = "$keys_without" ] && pass "--keys: config 유무 출력 동일" || fail "--keys config 유무 불일치" "with≠without"
# 카탈로그 핵심 키 포함 확인
printf '%s\n' "$keys_without" | grep -qx 'owner' && pass "--keys 에 owner 포함" || fail "--keys owner 누락" ""
printf '%s\n' "$keys_without" | grep -qx 'module.<Name>.<flag>' && pass "--keys 에 module.<Name>.<flag> 포함" || fail "--keys module 누락" ""
# plan 리더 카탈로그엔 review 전용 4키가 없어야(보안 의도 보존)
if printf '%s\n' "$keys_without" | grep -qE 'reviewer-app-id|reviewer-bot-slug|reviewer-token-key|slack-token-key'; then
  fail "--keys plan 에 review 4키 없어야" "발견됨"
else
  pass "--keys: plan 카탈로그에 review 전용 4키 없음(보안 의도)"
fi
# --dump 는 config 부재 시 여전히 빈 출력(회귀 방지 — 수정이 dump 를 건드리지 않았는지)
dump_missing="$(PIPELINE_CONFIG="$KEYS_MISSING" bash "$READER" --dump 2>/dev/null)"
[ -z "$dump_missing" ] && pass "--dump: config 부재 시 빈 출력(건드리지 않음)" || fail "--dump config 부재 비어있어야" "출력='$dump_missing'"
rm -f "$KEYS_FIX"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
