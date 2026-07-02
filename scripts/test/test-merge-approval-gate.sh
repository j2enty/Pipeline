#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
#
# test-merge-approval-gate.sh — merge.yml 승인 게이트·상태전환 결함 검증 (#100)
#
# 배경(#100 감사 M4·M5):
#   M4 — merge.yml "머지 조건 확인" 은 REVIEWER_BOT_LOGIN 에서 '[bot]' 접미를 잘라
#        BOT_PREFIX 를 만든 뒤 startswith(BOT_PREFIX) 로 Reviewer 봇 APPROVE 를 센다.
#        BOT_PREFIX 가 빈 문자열이면 startswith("") 가 "모든" 로그인에 참이 돼
#        아무 사용자나 APPROVE 만 하면 머지되는 fail-open 이 된다(org var 누락이
#        승인 게이트를 조용히 붕괴). 처방: BOT_PREFIX 가 비면 fail-closed(exit 1).
#   M5 — Status=Done 전환의 Project 메타 조회가 organization() 과 user() 를 "한 쿼리"에
#        함께 넣어, owner 가 user 면 organization(login:<user>) 가 top-level errors 를
#        반환 → gh api graphql non-zero → set -euo pipefail 로 step 사망 →
#        continue-on-error:true 가 삼켜 user 소유 Project 는 전환이 항상 조용히 실패.
#        처방: org·user 쿼리를 분리 호출하고 org 가 비면 user 로 폴백.
#
# 테스트 전략:
#   merge.yml 의 run 블록은 yml 인라인 셸이라 직접 호출이 어렵다. test-merge-ci-gate-skip.sh
#   와 동일하게, merge.yml 과 *동일한* 결정 로직을 순수 함수로 복제해 경계를 검증하고,
#   복제본이 merge.yml 본체와 드리프트하지 않도록 실제 표현식을 grep 으로 존재 단언한다.

MERGE_YML="$REPO_ROOT/.github/workflows/merge.yml"

# ── M4: BOT_PREFIX 게이트 결정 함수 (merge.yml 과 1:1 복제) ────────────
# 입력: $1 = REVIEWER_BOT_LOGIN (raw). 출력코드: 0 = 진행, 1 = fail-closed 차단.
bot_prefix_gate() {
  local reviewer_bot_login="$1" bot_prefix
  bot_prefix="${reviewer_bot_login%%\[*}"
  if [ -z "$bot_prefix" ]; then
    echo "::error::Reviewer 봇 로그인 미설정 — 머지 차단(fail-closed)"
    return 1
  fi
  echo "BOT_PREFIX=$bot_prefix"
  return 0
}

# T-AG-1: 빈 REVIEWER_BOT_LOGIN → BOT_PREFIX 빈 값 → fail-closed 차단
it "T-AG-1 REVIEWER_BOT_LOGIN='' → fail-closed(차단) — fail-open(#100 M4) 회귀 방지"
(
  rc=0
  out="$(bot_prefix_gate "")" || rc=$?
  assert_eq "1" "$rc" "빈 봇 로그인인데 통과함 — 아무나 머지 가능한 fail-open 회귀(#100 M4)" || return
  assert_contains "$out" "fail-closed" "fail-closed 차단 로그 미출력" && pass
)

# T-AG-2: '[bot]' 만 있는 병리적 입력 → 잘라내면 빈 prefix → 차단
it "T-AG-2 REVIEWER_BOT_LOGIN='[bot]' → 접미 제거 후 빈 prefix → 차단"
(
  rc=0
  bot_prefix_gate "[bot]" >/dev/null || rc=$?
  assert_eq "1" "$rc" "'[bot]' 만 있어 prefix 가 비는데 통과함 — fail-open" && pass
)

# T-AG-3: 정상 봇 로그인 → 진행 + prefix 는 '[bot]' 접미가 제거된 값
it "T-AG-3 REVIEWER_BOT_LOGIN='reviewer-bot[bot]' → 진행 + prefix='reviewer-bot'"
(
  rc=0
  out="$(bot_prefix_gate "reviewer-bot[bot]")" || rc=$?
  assert_eq "0" "$rc" "정상 봇 로그인인데 차단됨(게이트 오작동)" || return
  assert_contains "$out" "BOT_PREFIX=reviewer-bot" "접미 제거된 prefix 계산 오류" && pass
)

# ── M5: org/user 메타 조회 폴백 선택 로직 (merge.yml 과 1:1 복제) ──────
# merge.yml 은 org 쿼리를 먼저 시도하고(실패/빈값이면 --jq 결과가 ''/'null'),
# 비면 user 쿼리로 폴백한다. 이 선택 로직만 순수 함수로 복제.
# 입력: $1 = org 쿼리 --jq 결과, $2 = user 쿼리 --jq 결과.
# 출력(stdout): 최종 선택된 PROJECT_META. 비면 빈 문자열.
select_project_meta() {
  local org_result="$1" user_result="$2" meta
  meta="$org_result"
  if [ -z "$meta" ] || [ "$meta" = "null" ]; then
    meta="$user_result"
  fi
  if [ -z "$meta" ] || [ "$meta" = "null" ]; then
    return 0  # 둘 다 없음 → 빈 출력(호출부에서 스킵)
  fi
  echo "$meta"
}

# T-AG-4: org 소유 → org 결과 사용 (user 폴백 안 탐)
it "T-AG-4 org 소유(org 쿼리 채워짐) → org 메타 사용"
(
  out="$(select_project_meta '{"id":"ORG"}' '')"
  assert_eq '{"id":"ORG"}' "$out" "org 소유인데 org 메타를 안 씀" && pass
)

# T-AG-5: user 소유 → org 결과 빈값 → user 로 폴백 (#100 M5 핵심)
it "T-AG-5 user 소유(org 쿼리 빈값) → user 메타로 폴백 — M5 핵심 회귀 방지"
(
  out="$(select_project_meta '' '{"id":"USER"}')"
  assert_eq '{"id":"USER"}' "$out" "user 소유인데 폴백 실패 — Status=Done 조용히 실패 회귀(#100 M5)" || return
  # org 쿼리가 'null' 문자열을 뱉는 케이스도 폴백돼야 함
  out2="$(select_project_meta 'null' '{"id":"USER"}')"
  assert_eq '{"id":"USER"}' "$out2" "org 결과가 'null' 문자열일 때 폴백 실패" && pass
)

# T-AG-6: 둘 다 없음 → 빈 출력 (호출부가 스킵 판정)
it "T-AG-6 org·user 둘 다 빈값 → 빈 메타(스킵)"
(
  out="$(select_project_meta '' '')"
  assert_eq "" "$out" "둘 다 없는데 빈 메타가 아님" && pass
)

# ── 드리프트 가드 ─────────────────────────────────────────────────
# 위 복제 함수들은 merge.yml 의 *복제본*이다. merge.yml 만 바뀌고 복제본이 안 바뀌면
# 위 케이스가 가짜 통과한다. merge.yml 의 실제 라인을 grep 으로 존재 단언한다.

# T-AG-7: M4 — merge.yml 에 BOT_PREFIX 빈값 fail-fast(exit 1) 분기 존재
it "T-AG-7 드리프트 가드: merge.yml BOT_PREFIX 빈값 fail-closed 분기 존재(M4)"
(
  assert_file_present "$MERGE_YML" "merge.yml 경로 못 찾음" || return
  if grep -qF 'if [ -z "$BOT_PREFIX" ]; then' "$MERGE_YML"; then
    pass
  else
    fail "merge.yml 에 BOT_PREFIX 빈값 fail-closed 분기 없음 — fail-open 회귀(#100 M4)"
  fi
)

# T-AG-8: M5 — merge.yml 에 organization·user 가 "분리된" 두 쿼리로 존재
# 결합 안티패턴(--jq '.data.organization.projectV2 // .data.user.projectV2')이 사라지고
# org·user 각각의 --jq 추출이 있어야 한다.
it "T-AG-8 드리프트 가드: merge.yml org/user 쿼리 분리(결합 안티패턴 부재) (M5)"
(
  assert_file_present "$MERGE_YML" "merge.yml 경로 못 찾음" || return
  # 결합 폴백 --jq 가 남아 있으면 M5 미수정 (한 쿼리에 org+user)
  if grep -qF ".data.organization.projectV2 // .data.user.projectV2" "$MERGE_YML"; then
    fail "merge.yml 에 org+user 결합 --jq 가 남음 — user 소유 전환 실패 회귀(#100 M5)"
    return
  fi
  # 분리된 두 추출이 각각 존재해야 함
  if grep -qF "'.data.organization.projectV2'" "$MERGE_YML" \
     && grep -qF "'.data.user.projectV2'" "$MERGE_YML"; then
    pass
  else
    fail "merge.yml 에 분리된 org/user --jq 추출이 없음 — M5 분리 미적용"
  fi
)

# T-AG-9: M5 — 분리 쿼리가 예상된 org 실패를 삼키도록 '|| true' 로 감싸짐
it "T-AG-9 드리프트 가드: merge.yml org 쿼리가 '|| true' 로 감싸짐(user 소유 폴백) (M5)"
(
  assert_file_present "$MERGE_YML" "merge.yml 경로 못 찾음" || return
  # org --jq 추출 라인 근처에 '|| true' 가 있어야 (owner=user 시 non-zero 를 흡수)
  if grep -qF -- "--jq '.data.organization.projectV2' 2>\"\$ORG_STDERR\" || true" "$MERGE_YML"; then
    pass
  else
    fail "merge.yml org 쿼리에 '2>\"\$ORG_STDERR\" || true' 가드 없음 — set -euo pipefail 로 step 사망(#100 M5)"
  fi
)

# ── M5 실행 스니펫 (merge.yml 구조 복제, gh 는 주입 스텁이 처리) ──────
# merge.yml 의 "org 먼저 → 비면 user 폴백 + set -euo pipefail" 을 그대로 실행한다.
# 핵심은 '|| true' 가 pipefail 사망을 막느냐 — 그래서 여기서 || true 를 빼면 gh 가
# non-zero 일 때 assignment 가 set -e 로 이 함수(서브셸)를 죽여 호출부 rc≠0 이 된다.
# (순수함수 select_project_meta 는 '선택'만 보증하지 못하는 실행 레벨 회귀를 잡는다 — 리뷰 minor #2)
m5_fallback_snippet() {
  set -euo pipefail
  local org_stderr meta
  org_stderr="$(mktemp)"
  meta=$(gh api graphql -q 'organization{projectV2}' --jq '.data.organization.projectV2' 2>"$org_stderr" || true)
  if [ -z "$meta" ] || [ "$meta" = "null" ]; then
    meta=$(gh api graphql -q 'user{projectV2}' --jq '.data.user.projectV2' 2>/dev/null || true)
  fi
  echo "$meta"
}

# T-AG-10: M5 본질 회귀를 "실행"으로 검증
it "T-AG-10 실행 검증: gh non-zero 여도 pipefail 하에서 폴백 진행(M5 본질)"
(
  # gh 스텁 — organization 쿼리(인자에 'organization' 포함)면 exit 1(owner=user 시
  # NOT_FOUND 재현), 그 외(user)면 성공 JSON. 함수 호출 시점에 이 스텁이 lookup 된다.
  gh() {
    case "$*" in
      *organization*) echo "GraphQL: Could not resolve to an Organization" >&2; return 1 ;;
      *) echo '{"id":"USER"}' ;;
    esac
  }
  rc=0
  out="$(m5_fallback_snippet)" || rc=$?
  assert_eq "0" "$rc" "gh non-zero 에 서브셸이 죽음 — || true 가드가 pipefail 생존 못 시킴(#100 M5 본질 회귀)" || return
  assert_eq '{"id":"USER"}' "$out" "org 실패 시 user 폴백 결과가 안 나옴" && pass
)

# T-AG-11: M5 관측성 — 최종 실패 경로에서 stderr 를 캡처·노출해 진짜 장애를 숨기지 않는가
# (2>/dev/null 로 통째로 버리면 auth·rate-limit·network 오류가 조용한 회귀가 됨 — 리뷰 minor #1)
it "T-AG-11 드리프트 가드: merge.yml 이 org/user 조회 stderr 를 캡처·진단 노출(M5 관측성)"
(
  assert_file_present "$MERGE_YML" "merge.yml 경로 못 찾음" || return
  # stderr 를 /dev/null 로 버리지 않고 임시파일로 캡처
  if ! grep -qF 'ORG_STDERR="$(mktemp)"' "$MERGE_YML"; then
    fail "merge.yml 이 org 조회 stderr 를 캡처하지 않음 — 진짜 장애가 조용히 묻힘(#100 관측성)"
    return
  fi
  # 최종 실패 경로에서 캡처한 오류를 로그로 노출
  if grep -qF '[org 조회 오류]' "$MERGE_YML" && grep -qF '[user 조회 오류]' "$MERGE_YML"; then
    pass
  else
    fail "merge.yml 최종 실패 경로에 stderr 진단 노출 없음 — 실패 원인 사후 추적 불가"
  fi
)
