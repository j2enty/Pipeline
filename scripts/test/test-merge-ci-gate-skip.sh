#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
#
# test-merge-ci-gate-skip.sh — merge.yml CI 게이트 스킵 분기 검증 (#39)
#
# 배경(#39):
#   merge.yml 의 "CI 상태 확인" 은 gh run list --workflow "$CI_WORKFLOW_NAME" 로 CI 결과를
#   조회한다. CI workflow 가 없는 모듈(예: Design 같은 문서/리소스 전용 레포)은
#   ci-workflow-name 이 빈 문자열로 들어와 --workflow "" → 0건 매칭 → "missing" 이 되고
#   "$CI_CONCLUSION" != "success" 분기에 걸려 *영원히* 자동머지가 차단됐다.
#
# 수정:
#   CI 상태 확인 앞에서 CI_WORKFLOW_NAME 을 공백 제거(tr -d '[:space:]')해 비었으면
#   "CI 게이트 없는 모듈" 로 간주, CI 체크를 면제(스킵)하고 통과로 진행한다.
#   값이 있으면 기존대로 gh run list 결과로 판정한다.
#
# 테스트 전략:
#   merge.yml 의 run 블록은 yml 에 인라인된 셸이라 직접 호출이 어렵다.
#   과한 리팩터링(스크립트 추출) 대신, merge.yml 과 *동일한* 분기 로직을 순수 함수로
#   복제해 결정(스킵/평가) 경계를 검증한다. gh 호출은 주입된 CI_CONCLUSION 으로 대체.
#   merge.yml 본체의 트림 표현식·분기 구조와 1:1 대응되도록 작성.
#
# 검증:
#   T-CG-1: CI_WORKFLOW_NAME 비었음("") → CI 게이트 스킵 → 통과(should_merge 유지 true)
#   T-CG-2: 공백/탭/개행만 → 트림 후 빈 값 → 스킵 → 통과
#   T-CG-3: 이름 있음 + CI success → 통과
#   T-CG-4: 이름 있음 + CI missing → 차단 (이름 있는데 결과 없으면 여전히 막아야 함)
#   T-CG-5: 이름 있음 + CI failure → 차단
#   T-CG-6: 스킵 시 명확한 로그 출력(조용히 스킵 금지 — 추적 가능해야)

# ── merge.yml CI 게이트 분기를 그대로 복제한 결정 함수 ──────────────
# 입력:
#   $1 = CI_WORKFLOW_NAME (raw, 미트림)
#   $2 = CI_CONCLUSION    (gh run list 가 반환했을 값. 이름 있을 때만 의미)
# 출력(stdout): 결정 + 로그
# 종료코드: 0 = 통과(머지 진행), 1 = 차단(should_merge=false)
# ※ 이 분기 구조는 merge.yml "CI 상태 확인" 블록과 1:1 대응해야 한다.
ci_gate_decision() {
  local ci_workflow_name="$1" ci_conclusion="$2" trimmed
  trimmed="$(echo "$ci_workflow_name" | tr -d '[:space:]')"
  if [ -z "$trimmed" ]; then
    echo "CI workflow 미지정 — CI 게이트 스킵(CI 없는 모듈)"
    return 0
  fi
  if [ "$ci_conclusion" != "success" ]; then
    echo "CI 미통과 ($ci_conclusion) — 스킵"
    return 1
  fi
  echo "CI 통과"
  return 0
}

# T-CG-1: CI_WORKFLOW_NAME 비었음 → 스킵 → 통과
it "T-CG-1 CI_WORKFLOW_NAME='' → CI 게이트 스킵 → 통과"
(
  rc=0
  out="$(ci_gate_decision "" "missing")" || rc=$?
  assert_eq "0" "$rc" "빈 이름인데 통과(rc=0) 아님 — CI 없는 모듈 머지 차단 회귀(#39)" || return
  assert_contains "$out" "CI 게이트 스킵" "스킵 로그 미출력" && pass
)

# T-CG-2: 공백/탭/개행만 → 트림 후 빈 값 → 스킵 → 통과
it "T-CG-2 공백·탭·개행만 → 트림 후 빈 → 스킵 → 통과"
(
  rc=0
  out="$(ci_gate_decision "
 " "missing")" || rc=$?
  assert_eq "0" "$rc" "공백뿐인 이름이 차단됨 — 트림 누락" || return
  assert_contains "$out" "CI 게이트 스킵" "스킵 로그 미출력" && pass
)

# T-CG-3: 이름 있음 + success → 통과
it "T-CG-3 이름 있음 + CI success → 통과"
(
  rc=0
  out="$(ci_gate_decision "Backend CI" "success")" || rc=$?
  assert_eq "0" "$rc" "success 인데 차단됨" || return
  assert_not_contains "$out" "CI 게이트 스킵" "이름 있는데 게이트 스킵됨(면제 오작동)" && pass
)

# T-CG-4: 이름 있음 + missing → 차단 (이름 있으면 결과 없을 때 여전히 막아야 함)
it "T-CG-4 이름 있음 + CI missing → 차단(게이트 유지)"
(
  rc=0
  out="$(ci_gate_decision "Backend CI" "missing")" || rc=$?
  assert_eq "1" "$rc" "이름 있고 missing 인데 통과됨 — CI 게이트 약화(위험)" || return
  assert_contains "$out" "CI 미통과" "차단 로그 미출력" && pass
)

# T-CG-5: 이름 있음 + failure → 차단
it "T-CG-5 이름 있음 + CI failure → 차단"
(
  rc=0
  ci_gate_decision "Backend CI" "failure" >/dev/null || rc=$?
  assert_eq "1" "$rc" "failure 인데 통과됨 — CI 게이트 약화(위험)" && pass
)

# T-CG-6: 스킵 시 조용히 넘어가지 않고 명확한 로그(추적성)
it "T-CG-6 스킵 시 명확 로그(조용히 스킵 금지 — 사후 추적 가능)"
(
  out="$(ci_gate_decision "" "missing")"
  assert_contains "$out" "CI 없는 모듈" "CI 없는 모듈임을 알리는 로그 미포함" && pass
)

# ── 드리프트 가드 ─────────────────────────────────────────────────
# 위 ci_gate_decision 은 merge.yml 의 *복제본*이다. merge.yml 만 바뀌고 복제본이
# 안 바뀌면 위 케이스들은 가짜 통과한다. 그래서 merge.yml 의 실제 트림/분기 라인이
# 복제본과 동일한 표현식을 쓰는지 grep 으로 존재 단언한다.
# merge.yml 에서 이 표현식이 사라지거나 바뀌면(=드리프트) 아래 케이스가 fail 한다.
MERGE_YML="$REPO_ROOT/.github/workflows/merge.yml"

# T-CG-7: merge.yml 트림 라인 존재 단언 — ci_gate_decision 의 trimmed 계산과 동일해야 함
it "T-CG-7 드리프트 가드: merge.yml 트림 라인(tr -d '[:space:]') 존재"
(
  assert_file_present "$MERGE_YML" "merge.yml 경로 못 찾음" || return
  # 복제본(ci_gate_decision)이 쓰는 것과 동일한 트림 표현식이 merge.yml 에 있어야 함
  if grep -qF 'CI_WORKFLOW_NAME_TRIMMED="$(echo "$CI_WORKFLOW_NAME" | tr -d '"'"'[:space:]'"'"')"' "$MERGE_YML"; then
    pass
  else
    fail "merge.yml 의 트림 라인이 복제본과 다름 — 드리프트(merge.yml 표현식 변경됨)"
  fi
)

# T-CG-8: merge.yml 빈값 스킵 분기 존재 단언
it "T-CG-8 드리프트 가드: merge.yml 빈값 스킵 분기 존재"
(
  assert_file_present "$MERGE_YML" "merge.yml 경로 못 찾음" || return
  if grep -qF 'if [ -z "$CI_WORKFLOW_NAME_TRIMMED" ]; then' "$MERGE_YML"; then
    pass
  else
    fail "merge.yml 의 빈값 스킵 분기가 사라짐/변경됨 — 드리프트(CI 게이트 스킵 분기 누락)"
  fi
)

# T-CG-9: merge.yml fail-open 로그에 레포 식별자($PR_REPO) 포함 단언 (추적성)
it "T-CG-9 드리프트 가드: merge.yml 스킵 로그에 \$PR_REPO 포함(fail-open 추적성)"
(
  assert_file_present "$MERGE_YML" "merge.yml 경로 못 찾음" || return
  if grep -qF 'CI 게이트 스킵(CI 없는 모듈): $PR_REPO' "$MERGE_YML"; then
    pass
  else
    fail "merge.yml 스킵 로그에 \$PR_REPO 누락 — fail-open 사후 추적 불가"
  fi
)
