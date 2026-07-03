#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# test-reader-core-parity.sh — #105(감사 cross-p0) plan 사본 "공유 파싱 코어" 드리프트 가드.
#
# 배경: pipeline-config.sh 는 3벌(plan/kickoff/review) 복제인데, plan 사본만 의도적으로 다르다
#   (reviewer 전용 4키 없음 + cross-check-tool 있음). 그래서 test-script-parity.sh 의 바이트
#   동일 검사에서 plan 은 제외돼 있다. 문제는 plan 사본의 "공유 파싱 코어"(모듈 블록 분할·
#   따옴표/주석 처리·토글·legacy 폴백 등, 리더 3벌이 똑같아야 하는 부분)가 조용히 드리프트해도
#   바이트 검사로는 안 잡힌다는 점. 기존 parity 테스트가 "modules 블록만 잠가" 나머지 코어의
#   드리프트를 놓친 것과 같은 함정.
#
# 처방: 리더별로 "다른 게 정당한" 키(reviewer-*/slack-token-key/cross-check-tool)를 제외한
#   모든 공유 키에 대해 plan 리더와 kickoff 리더의 출력이 동일함을 동작 기준으로 강제한다.
#   plan 의 코어가 어긋나면 어떤 공유 키의 출력이 갈라져 이 테스트가 실패한다.
#   (kickoff↔review 는 test-script-parity.sh 가 바이트로 이미 잠갔으므로 여기선 plan↔kickoff 만.)
#
# 주: 넓은 코드경로 자극을 위해 전용 fixture(config-reader-core-parity.yml) 사용 —
#   다양한 모듈 플래그·따옴표·주석·빈값·legacy 폴백·토글을 한 파일에 담았다.

READER_PLAN="$REPO_ROOT/plugin/skills/plan/scripts/pipeline-config.sh"
READER_KICKOFF="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
CORE_FIX="$FIXTURES_DIR/config-reader-core-parity.yml"

# 두 리더에 같은 인자를 주고 stdout 이 동일한지 단언.
_assert_reader_parity() {
  local label="$1"; shift
  local p k
  p="$(PIPELINE_CONFIG="$CORE_FIX" bash "$READER_PLAN" "$@" 2>/dev/null)"
  k="$(PIPELINE_CONFIG="$CORE_FIX" bash "$READER_KICKOFF" "$@" 2>/dev/null)"
  if [ "$p" != "$k" ]; then
    fail "[$label] plan↔kickoff 코어 드리프트 (args: $*)
    plan   ='$p'
    kickoff='$k'"
    return 1
  fi
  return 0
}

# RC-1 — 스칼라·파생 공유 키 전부 동일
it "RC-1 공유 스칼라/파생 키 출력이 plan↔kickoff 동일"
(
  ok=1
  for key in owner parent-repository parent-repo-name project-number slack-channel \
             project-name project-id status-field-id area-field-id \
             author-login local-account docs-context-dir \
             codex-model codex-reasoning-effort \
             base-branch status-trigger-kickoff status-trigger-review \
             status-column-in-review status-column-ready status-column-backlog status-column-done; do
    _assert_reader_parity "scalar:$key" "$key" || ok=0
  done
  [ "$ok" = 1 ] && pass
)

# RC-2 — 토글(plan.* / metrics.*) 동일
it "RC-2 토글 키 출력이 plan↔kickoff 동일"
(
  ok=1
  for key in plan.completeness-critic-enabled plan.consistency-critic-enabled \
             plan.consistency-critic-dual-model plan.contract-doc-enabled \
             metrics.usage-tracking-enabled; do
    _assert_reader_parity "toggle:$key" "$key" || ok=0
  done
  [ "$ok" = 1 ] && pass
)

# RC-2b — 토글 default 폴백 경로 동일 (허위그린 차단, #112 리뷰 F1)
#   config-reader-core-parity.yml 은 토글을 전부 명시해 리더의 공유 default 상수
#   (plan_bool default='true' / metrics_bool default='false') 경로를 자극하지 못한다.
#   → plan:/metrics: 서브블록을 생략한 fixture 로 default 폴백을 자극하고,
#     (1) plan↔kickoff parity 강제 + (2) 실제 default 값까지 단언해
#     plan 리더의 default 상수 드리프트가 반드시 레드로 드러나게 한다.
it "RC-2b 토글 default 폴백(plan:/metrics: 생략)이 plan↔kickoff 동일 + 기대 default"
(
  CORE_FIX="$FIXTURES_DIR/config-reader-core-parity-defaults.yml"
  ok=1
  # plan.* 토글 4개 — default 는 true (config 에 plan: 서브블록 없음)
  for key in plan.completeness-critic-enabled plan.consistency-critic-enabled \
             plan.consistency-critic-dual-model plan.contract-doc-enabled; do
    _assert_reader_parity "toggle-default:$key" "$key" || ok=0
    kv="$(PIPELINE_CONFIG="$CORE_FIX" bash "$READER_KICKOFF" "$key" 2>/dev/null)"
    assert_eq "true" "$kv" "plan 토글 default 가 true 가 아님(폴백 경로 미자극?): $key" || ok=0
  done
  # metrics.* 토글 — default 는 false (config 에 metrics: 서브블록 없음)
  _assert_reader_parity "toggle-default:metrics.usage-tracking-enabled" metrics.usage-tracking-enabled || ok=0
  mv="$(PIPELINE_CONFIG="$CORE_FIX" bash "$READER_KICKOFF" metrics.usage-tracking-enabled 2>/dev/null)"
  assert_eq "false" "$mv" "metrics 토글 default 가 false 가 아님(폴백 경로 미자극?)" || ok=0
  [ "$ok" = 1 ] && pass
)

# RC-3 — 모듈 플래그 전종류 + area-id legacy 폴백 동일
it "RC-3 모듈 플래그/ area-id 폴백 출력이 plan↔kickoff 동일"
(
  ok=1
  for mod in Backend Admin Design; do
    for flag in role planner review kickoff lead default-status cross-area-group area-id ci-workflow-name; do
      _assert_reader_parity "module:$mod.$flag" "module.$mod.$flag" || ok=0
    done
  done
  # legacy area-ids 친화 키(모듈 area-id 빈값 → legacy 폴백) 및 순수 legacy 키
  _assert_reader_parity "area-id.Design" area-id.Design || ok=0
  _assert_reader_parity "area-id.Docs" area-id.Docs || ok=0
  [ "$ok" = 1 ] && pass
)

# RC-4 — 모듈 인터페이스(목록·표·조건 필터) 동일
it "RC-4 모듈 목록/표/조건필터 출력이 plan↔kickoff 동일"
(
  ok=1
  _assert_reader_parity "--list-modules" --list-modules || ok=0
  _assert_reader_parity "--modules-table" --modules-table || ok=0
  _assert_reader_parity "--modules-where lead=true" --modules-where lead=true || ok=0
  _assert_reader_parity "--modules-where review=false" --modules-where review=false || ok=0
  [ "$ok" = 1 ] && pass
)
