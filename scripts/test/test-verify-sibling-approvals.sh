#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# 이슈 #99 M3 — verify-sibling-approvals.sh 단위테스트.
#   critic.yml 의 sibling 승인 판정을 추출한 스크립트가 "동일 판정"을 내는지 검증한다.
#   gh 호출은 scripts/test/stubs/gh 가 PATH 로 가로채고, sibling GraphQL 응답(issue 객체)은
#   GH_STUB_ISSUE_JSON 으로 결정적으로 주입한다(라이브 gh 없이 판정 경로 전체를 커버).

VERIFY_SH="$REPO_ROOT/scripts/verify-sibling-approvals.sh"
STUBS_DIR="$REPO_ROOT/scripts/test/stubs"

# 스텁 gh 를 PATH 로 가로채 verify 스크립트를 실행하고 stdout·exit code 를 반환한다.
#   run_verify <expected-json> <strict> <reviewer-bot-login> -- <verify args...>
# 결과: 전역 RC(종료코드)·OUT(stdout) 에 기록.
run_verify() {
  local issue_json="$1" strict="$2" bot="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  RC=0
  OUT="$(PATH="$STUBS_DIR:$PATH" \
    GH_TOKEN=dummy \
    GH_STUB_ISSUE_JSON="$issue_json" \
    STRICT_REVIEW_BOT_CHECK="$strict" \
    REVIEWER_BOT_LOGIN="$bot" \
    OWNER="org" \
    bash "$VERIFY_SH" "$@" 2>/dev/null)" || RC=$?
}

BOT='reviewer-bot[bot]'

# 승인 리뷰 1개(봇) + blocked 라벨 없음 → ok
JSON_OK='{"state":"OPEN","closedByPullRequestsReferences":{"nodes":[{"number":10,"state":"OPEN","labels":{"nodes":[]},"reviews":{"nodes":[{"state":"APPROVED","author":{"login":"reviewer-bot[bot]"}}]}}]}}'

# VS-1 — 봇 APPROVED + 문제없음 → ok (exit 0)
it "VS-1 봇 APPROVED + 문제없음 → ok"
(
  run_verify "$JSON_OK" true "$BOT" -- org/Backend 42
  assert_eq "0" "$RC" "정상 승인인데 exit 0 아님" || return
  assert_eq "ok" "$OUT" "정상 승인인데 ok 아님" && pass
)

# VS-2 — blocked 라벨 존재 → blocked:blocked-label (exit 1)
it "VS-2 blocked 라벨 → blocked:blocked-label"
(
  json='{"state":"OPEN","closedByPullRequestsReferences":{"nodes":[{"number":10,"state":"OPEN","labels":{"nodes":[{"name":"blocked"}]},"reviews":{"nodes":[{"state":"APPROVED","author":{"login":"reviewer-bot[bot]"}}]}}]}}'
  run_verify "$json" true "$BOT" -- org/Backend 42
  assert_eq "1" "$RC" "blocked 라벨인데 exit 1 아님" || return
  assert_eq "blocked:blocked-label" "$OUT" "blocked 라벨 판정 문자열 불일치" && pass
)

# VS-3 — 봇 APPROVE 없음(사람 승인만) → blocked:no-approval (exit 1)
it "VS-3 봇 APPROVE 없음(사람 승인만) → blocked:no-approval"
(
  json='{"state":"OPEN","closedByPullRequestsReferences":{"nodes":[{"number":10,"state":"OPEN","labels":{"nodes":[]},"reviews":{"nodes":[{"state":"APPROVED","author":{"login":"human-dev"}}]}}]}}'
  run_verify "$json" true "$BOT" -- org/Backend 42
  assert_eq "1" "$RC" "봇 승인 없는데 exit 1 아님" || return
  assert_eq "blocked:no-approval" "$OUT" "봇 승인 없음 판정 문자열 불일치" && pass
)

# 봇 APPROVED + 제3자 CHANGES_REQUESTED 공존 (VS-4/VS-5 공유)
JSON_THIRD_PARTY_CR='{"state":"OPEN","closedByPullRequestsReferences":{"nodes":[{"number":10,"state":"OPEN","labels":{"nodes":[]},"reviews":{"nodes":[{"state":"APPROVED","author":{"login":"reviewer-bot[bot]"}},{"state":"CHANGES_REQUESTED","author":{"login":"human-dev"}}]}}]}}'

# VS-4 — strict=true 에서 제3자 CHANGES_REQUESTED → blocked:changes-requested (exit 1)
it "VS-4 strict=true + 제3자 CHANGES_REQUESTED → blocked:changes-requested"
(
  run_verify "$JSON_THIRD_PARTY_CR" true "$BOT" -- org/Backend 42
  assert_eq "1" "$RC" "strict 제3자 CR 인데 exit 1 아님" || return
  assert_eq "blocked:changes-requested" "$OUT" "strict 제3자 CR 판정 문자열 불일치" && pass
)

# VS-5 — strict=false 에서 제3자 CHANGES_REQUESTED 는 무시(봇 것만 본다) → ok (exit 0)
#   VS-4 와 동일 입력이지만 strict 만 다르다 → strict 토글 의미를 직접 증명.
it "VS-5 strict=false + 제3자 CHANGES_REQUESTED 무시(봇만) → ok"
(
  run_verify "$JSON_THIRD_PARTY_CR" false "$BOT" -- org/Backend 42
  assert_eq "0" "$RC" "비strict 제3자 CR 무시인데 exit 0 아님" || return
  assert_eq "ok" "$OUT" "비strict 제3자 CR 인데 ok 아님" && pass
)

# VS-5b — strict=false 라도 봇 자신의 CHANGES_REQUESTED 는 차단 → blocked:changes-requested
#   비strict 가 "CR 을 전부 무시"가 아니라 "봇 CR 만 본다"임을 확인(무력화 회귀 방지).
it "VS-5b strict=false + 봇 CHANGES_REQUESTED → blocked:changes-requested"
(
  json='{"state":"OPEN","closedByPullRequestsReferences":{"nodes":[{"number":10,"state":"OPEN","labels":{"nodes":[]},"reviews":{"nodes":[{"state":"APPROVED","author":{"login":"reviewer-bot[bot]"}},{"state":"CHANGES_REQUESTED","author":{"login":"reviewer-bot[bot]"}}]}}]}}'
  run_verify "$json" false "$BOT" -- org/Backend 42
  assert_eq "1" "$RC" "비strict 봇 CR 인데 exit 1 아님" || return
  assert_eq "blocked:changes-requested" "$OUT" "비strict 봇 CR 판정 문자열 불일치" && pass
)

# VS-6 — 이슈 CLOSED → 완료로 간주 ok (exit 0)
it "VS-6 이슈 CLOSED → ok(완료로 간주)"
(
  json='{"state":"CLOSED","closedByPullRequestsReferences":{"nodes":[]}}'
  run_verify "$json" true "$BOT" -- org/Backend 42
  assert_eq "0" "$RC" "CLOSED 인데 exit 0 아님" || return
  assert_eq "ok" "$OUT" "CLOSED 인데 ok 아님" && pass
)

# VS-7 — 연결된 open PR 없음 → blocked:no-pr (exit 1)
it "VS-7 연결 PR 없음 → blocked:no-pr"
(
  json='{"state":"OPEN","closedByPullRequestsReferences":{"nodes":[]}}'
  run_verify "$json" true "$BOT" -- org/Backend 42
  assert_eq "1" "$RC" "연결 PR 없는데 exit 1 아님" || return
  assert_eq "blocked:no-pr" "$OUT" "연결 PR 없음 판정 문자열 불일치" && pass
)

# VS-8 — GraphQL 조회 실패(GH_STUB_ISSUE_JSON 미주입 → stub exit 1) → blocked:verify-error (exit 1)
it "VS-8 GraphQL 조회 실패 → blocked:verify-error"
(
  run_verify "" true "$BOT" -- org/Backend 42
  assert_eq "1" "$RC" "조회 실패인데 exit 1 아님" || return
  assert_eq "blocked:verify-error" "$OUT" "조회 실패 판정 문자열 불일치" && pass
)

# VS-9 — REVIEWER_BOT_LOGIN 미설정 → 설정 오류 exit 2 (빈 prefix 로 아무 승인 통과시키지 않음)
it "VS-9 REVIEWER_BOT_LOGIN 미설정 → exit 2(fail-closed)"
(
  run_verify "$JSON_OK" true "" -- org/Backend 42
  assert_eq "2" "$RC" "봇 로그인 미설정인데 exit 2 아님" && pass
)

# VS-10 — 인자 누락(sibling 번호 없음) → 사용법 오류 exit 2
it "VS-10 인자 누락 → exit 2"
(
  run_verify "$JSON_OK" true "$BOT" -- org/Backend
  assert_eq "2" "$RC" "인자 누락인데 exit 2 아님" && pass
)

# VS-11 — 'repo'(owner 없는) + OWNER env 로 보완 → 정상 판정(ok)
#   critic-dispatch 는 sub_issues .repository.name('repo')만 넘기고 OWNER 를 env 로 준다.
it "VS-11 owner 없는 repo + OWNER env → ok"
(
  run_verify "$JSON_OK" true "$BOT" -- Backend 42
  assert_eq "0" "$RC" "owner 보완 경로인데 exit 0 아님" || return
  assert_eq "ok" "$OUT" "owner 보완 경로인데 ok 아님" && pass
)
