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

# ── codex-model / codex-reasoning-effort (plan·review codex 교차검증 공통 통합 키 — #83) ──
# 빈값 기본 스칼라 — 기본 픽스처엔 키가 없으므로 빈값(빈값이면 SKILL 이 codex 플래그 미부착 → codex 기본).
assert_key codex-model ""
assert_key codex-reasoning-effort ""
# config 에 명시되면 그 값 반환 (주입 모델명은 real 모델명 회피 — 리더 동작만 검증)
CRM_FIX="$(mktemp)"; printf 'claude-commands:\n  codex-model: model-x\n  codex-reasoning-effort: high\n' > "$CRM_FIX"
assert_key codex-model model-x "$CRM_FIX"
assert_key codex-reasoning-effort high "$CRM_FIX"
rm -f "$CRM_FIX"

# ── (회귀) 알 수 없는 키 → 빈 값 (fail-soft) ──
assert_key bogus-key ""

# ── (회귀+신규) config 부재 → fail-soft (토글 기본 true, 나머지 빈 값) ──
MISSING="$(mktemp -u)/nope.yml"
assert_key owner "" "$MISSING"
assert_key plan.contract-doc-enabled true "$MISSING"
# 신규 4키도 config 부재 시 빈 값 (fail-soft, exit 0)
assert_key reviewer-app-id "" "$MISSING"
assert_key reviewer-token-key "" "$MISSING"
# codex 교차검증 주입 키도 config 부재 시 빈값 (폴백 기본값 없음)
assert_key codex-model "" "$MISSING"
assert_key codex-reasoning-effort "" "$MISSING"

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

# ── modules 인터페이스 (#42 데이터층) ────────────────────────────────
# (plan 리더 테스트와 동일 검증 — 공통 코어가 byte-identical 임을 행동으로도 확인)
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

# area-id.<Name> 친화 키 resolve 순서
assert_key area-id.Alpha alpha-modid
assert_key area-id.Gamma gamma-legacy
assert_key area-id.Backend aa11bb22

# --list-modules 정의순
list_out="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
[ "$list_out" = "Alpha,Beta,Gamma," ] && pass "--list-modules == 'Alpha,Beta,Gamma'" || fail "--list-modules" "실제='$list_out'"

# --modules-where
wl="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where lead=true 2>/dev/null | tr '\n' ',')"
[ "$wl" = "Alpha," ] && pass "--modules-where lead=true == 'Alpha'" || fail "--modules-where lead=true" "실제='$wl'"
wr="$(PIPELINE_CONFIG="$FIXTURE" bash "$READER" --modules-where review=true 2>/dev/null | tr '\n' ',')"
[ "$wr" = "Alpha,Beta," ] && pass "--modules-where review=true == 'Alpha,Beta'" || fail "--modules-where review=true" "실제='$wr'"

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

# 신규 modules 인터페이스는 --dump 에 노출되지 않아야 함(modules-table 은 별도 경로)
assert_dump_absent "Alpha CI"
assert_dump_absent "alpha-modid"

# ── 빈 스칼라 흡수 회귀 (이중리뷰 버그) ─────────────────────────────────
# 빈 스칼라 필드(area-id/role/default-status/cross-area-group/ci-workflow-name)가
# 다음 줄 키를 값으로 흡수하면 안 된다. (\s* 가 개행을 먹는 버그 — [ \t]* 로 수정.)
EMPTY_ABSORB="$(mktemp)"
cat > "$EMPTY_ABSORB" <<'EOF'
modules:
  - name: Zeta
    area-id:
    role:
    default-status:
    cross-area-group:
    ci-workflow-name:
    planner:
    lead: false
claude-commands:
  area-ids:
    Zeta: legacyfallback
EOF
ea_modid="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Zeta.area-id 2>/dev/null)"
[ "$ea_modid" = "legacyfallback" ] && pass "빈 area-id → legacy 폴백(흡수 안 함)" || fail "빈 area-id legacy 폴백" "실제='$ea_modid'"
ea_legacy="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" area-id.Zeta 2>/dev/null)"
[ "$ea_legacy" = "legacyfallback" ] && pass "빈 area-id.Zeta → legacy 폴백" || fail "area-id.Zeta legacy 폴백" "실제='$ea_legacy'"
ea_role="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Zeta.role 2>/dev/null)"
[ -z "$ea_role" ] && pass "빈 role → 빈 값(흡수 안 함)" || fail "빈 role 비흡수" "실제='$ea_role'"
ea_ds="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Zeta.default-status 2>/dev/null)"
[ "$ea_ds" = "Ready" ] && pass "빈 default-status → 기본 Ready(흡수 안 함)" || fail "빈 default-status 기본값" "실제='$ea_ds'"
ea_cg="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Zeta.cross-area-group 2>/dev/null)"
[ -z "$ea_cg" ] && pass "빈 cross-area-group → 빈 값(흡수 안 함)" || fail "빈 cross-area-group 비흡수" "실제='$ea_cg'"
ea_ci="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Zeta.ci-workflow-name 2>/dev/null)"
[ -z "$ea_ci" ] && pass "빈 ci-workflow-name → 빈 값(흡수 안 함)" || fail "빈 ci-workflow-name 비흡수" "실제='$ea_ci'"
ea_planner="$(PIPELINE_CONFIG="$EMPTY_ABSORB" bash "$READER" module.Zeta.planner 2>/dev/null)"
[ "$ea_planner" = "true" ] && pass "빈 planner → 기본 true" || fail "빈 planner 기본값" "실제='$ea_planner'"
rm -f "$EMPTY_ABSORB"

# ── install.sh parity — 실제 projects/reclip config 로 신규 4키 값 ──
# (런타임 읽은 값 == install.sh 가 치환했을 값 임을 실제 설정 파일로 확인)
RECLIP="$TEST_DIR/../../../../projects/reclip/pipeline-config.yml"
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
      pass "parity: projects/reclip $k == '$exp'"
    else
      fail "parity: projects/reclip $k" "실제='$act'"
    fi
  done
else
  printf "(parity 스킵 — %s 없음)\n" "$RECLIP"
fi


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
# review 리더 카탈로그는 review 전용 4키를 포함한다(kickoff 리더와 byte-identical).
KEYS_MISSING="$(mktemp -u)/none.yml"
KEYS_FIX="$(mktemp)"; printf 'project:\n  owner: K\n' > "$KEYS_FIX"
keys_with="$(PIPELINE_CONFIG="$KEYS_FIX" bash "$READER" --keys 2>/dev/null)"
keys_without="$(PIPELINE_CONFIG="$KEYS_MISSING" bash "$READER" --keys 2>/dev/null)"
[ -n "$keys_without" ] && pass "--keys: config 부재에도 비어있지 않음(#45)" || fail "--keys config 부재 비어있음" "출력=''"
[ "$keys_with" = "$keys_without" ] && pass "--keys: config 유무 출력 동일" || fail "--keys config 유무 불일치" "with≠without"
printf '%s\n' "$keys_without" | grep -qx 'owner' && pass "--keys 에 owner 포함" || fail "--keys owner 누락" ""
printf '%s\n' "$keys_without" | grep -qx 'module.<Name>.<flag>' && pass "--keys 에 module.<Name>.<flag> 포함" || fail "--keys module 누락" ""
# review/kickoff 리더는 review 전용 4키를 카탈로그에 노출(config 부재에도 동일하게)
for kk in reviewer-app-id reviewer-bot-slug reviewer-token-key slack-token-key; do
  printf '%s\n' "$keys_without" | grep -qx "$kk" && pass "--keys(config부재) 에 '$kk' 노출" || fail "--keys '$kk' 누락" ""
done
# --dump 는 config 부재 시 여전히 빈 출력(회귀 방지 — 수정이 dump 를 건드리지 않았는지)
dump_missing="$(PIPELINE_CONFIG="$KEYS_MISSING" bash "$READER" --dump 2>/dev/null)"
[ -z "$dump_missing" ] && pass "--dump: config 부재 시 빈 출력(건드리지 않음)" || fail "--dump config 부재 비어있어야" "출력='$dump_missing'"
rm -f "$KEYS_FIX"

echo ""
echo -e "${C_CYAN}── 결과 ──${C_NC}"
printf "통과 %d · 실패 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo -e "${C_GREEN}전부 통과${C_NC}"; exit 0; } || { echo -e "${C_RED}실패 있음${C_NC}" >&2; exit 1; }
