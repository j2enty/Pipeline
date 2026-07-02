#!/usr/bin/env bash
# verify-sibling-approvals.sh — 한 sibling(sub-issue)의 승인 상태를 critic.yml 과
#   "동일 판정"으로 재검증한다(추출/공유).
#
# 배경(M3 — 감사, 이슈 #99):
#   critic-dispatch.yml 은 App 이 critic-triggered dispatch 를 발사한 시점의 "전부 승인"
#   스냅샷만 믿고 나중에 머지한다. 그 사이 새 커밋·CHANGES_REQUESTED·blocked 라벨이
#   붙어도 낡은 승인 기준으로 머지하는 TOCTOU(Time-Of-Check to Time-Of-Use) 가 있다.
#   머지 직전에 이 스크립트로 각 sibling 의 승인 상태를 재검증해 fail-closed 로 막는다.
#
#   원래 이 판정 로직은 critic.yml 의 check-and-critic 잡(라인 204-259)에 인라인돼 있었다.
#   critic.yml 과 critic-dispatch.yml 이 "같은 승인 판정"을 공유(드리프트 방지)하도록
#   여기로 추출한다. 재사용/추출이지 재설계가 아니다 — 판정 의미는 critic.yml 과 100% 동일.
#
# 사용법:
#   GH_TOKEN=<token> REVIEWER_BOT_LOGIN='reviewer-bot[bot]' STRICT_REVIEW_BOT_CHECK=true \
#     ./scripts/verify-sibling-approvals.sh <SIBLING_REPO> <SIBLING_ISSUE_NUMBER>
#
# 인자:
#   $1: SIBLING_REPO  — sibling sub-issue 레포. 'owner/repo'(critic.yml 의 nameWithOwner)
#                       또는 'repo'(critic-dispatch 의 sub_issues .repository.name) + OWNER env.
#   $2: SIBLING_NUM   — sibling sub-issue 번호.
#
# 환경변수:
#   GH_TOKEN                 — 인증 토큰 (gh 가 소비, 필수)
#   REVIEWER_BOT_LOGIN       — Reviewer 봇 로그인 (예: 'reviewer-bot[bot]'). 필수.
#                              '[...]' 접미는 prefix 매칭을 위해 잘라낸다(critic.yml 과 동일).
#   STRICT_REVIEW_BOT_CHECK  — 'true'(기본): 누구의 CHANGES_REQUESTED 든 차단.
#                              'false': Reviewer 봇 것만 차단.
#   OWNER                    — SIBLING_REPO 에 owner('/')가 없을 때 owner 로 사용(선택).
#
# 출력 (stdout, 한 줄):
#   'ok'                — 승인 유효(봇 APPROVED 존재 + 차단 요소 없음) 또는 이슈 CLOSED(완료).
#   'blocked:<reason>'  — 재검증 실패. reason:
#                           no-pr             연결된 open PR 없음(미완료)
#                           blocked-label     blocked 라벨 존재
#                           no-approval       Reviewer 봇 APPROVE 없음
#                           changes-requested CHANGES_REQUESTED 존재
#                           verify-error      GraphQL 조회 실패(검증 불능)
#
# 종료 코드:
#   0  — ok
#   1  — blocked:<reason> (승인 무효/미완료/검증불능 — 모두 fail-closed 로 머지 차단)
#   2  — 사용법/설정 오류(인자·필수 env 누락)

set -euo pipefail

SIBLING_REPO="${1:-}"
SIBLING_NUM="${2:-}"

if [ -z "$SIBLING_REPO" ] || [ -z "$SIBLING_NUM" ]; then
  echo "usage: verify-sibling-approvals.sh <SIBLING_REPO> <SIBLING_ISSUE_NUMBER>" >&2
  exit 2
fi

REVIEWER_BOT_LOGIN="${REVIEWER_BOT_LOGIN:-}"
if [ -z "$REVIEWER_BOT_LOGIN" ]; then
  # 봇 로그인이 없으면 "봇 APPROVED" 를 판정할 수 없다 → fail-closed(설정 오류).
  # 빈 prefix 로 startswith 를 돌리면 아무 리뷰나 APPROVED 로 오인해 승인을 통과시키므로
  # 절대 빈 값으로 진행하지 않는다. (critic-dispatch 는 빈 값이면 이 스크립트를 아예
  # 호출하지 않고 재검증을 스킵한다 — degrade. 여기 가드는 이중 안전망.)
  echo "REVIEWER_BOT_LOGIN 필수 (Reviewer 봇 로그인)" >&2
  exit 2
fi

STRICT_REVIEW_BOT_CHECK="${STRICT_REVIEW_BOT_CHECK:-true}"

# owner/repo 분해 — SIBLING_REPO 에 '/' 가 있으면 그대로 쓰고, 없으면 OWNER env 로 보완.
# critic.yml 은 nameWithOwner('owner/repo'), critic-dispatch 는 name('repo')+OWNER 를 넘겨
# 두 호출부를 모두 수용한다.
case "$SIBLING_REPO" in
  */*)
    S_OWNER="${SIBLING_REPO%%/*}"
    S_REPO_NAME="${SIBLING_REPO##*/}"
    ;;
  *)
    S_OWNER="${OWNER:-}"
    S_REPO_NAME="$SIBLING_REPO"
    ;;
esac
if [ -z "$S_OWNER" ] || [ -z "$S_REPO_NAME" ]; then
  echo "SIBLING_REPO 에서 owner/repo 를 결정할 수 없음 (OWNER env 필요): '$SIBLING_REPO'" >&2
  exit 2
fi

# Reviewer 봇 로그인의 '[...]' 접미(예: 'reviewer-bot[bot]')를 잘라 prefix 로 매칭한다
# (critic.yml 라인 128 과 동일). 봇 리뷰 author.login 은 'reviewer-bot' 로 시작한다.
BOT_PREFIX="${REVIEWER_BOT_LOGIN%%\[*}"

# critic.yml 라인 204-220 과 동일 GraphQL — issue state + 연결된 open PR 의 labels/reviews.
# $owner/$repo/$num 는 GraphQL 변수 — single quote 안 미확장 의도적
# shellcheck disable=SC2016
SIBLING_PR=$(gh api graphql -f query='
  query($owner: String!, $repo: String!, $num: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $num) {
        state
        closedByPullRequestsReferences(first: 5, includeClosedPrs: false) {
          nodes {
            number state
            labels(first: 20) { nodes { name } }
            reviews(first: 50) { nodes { state author { login } } }
          }
        }
      }
    }
  }
' -f owner="$S_OWNER" -f repo="$S_REPO_NAME" -F num="$SIBLING_NUM" \
  --jq '.data.repository.issue') || {
    # GraphQL 조회 실패(네트워크·권한·rate limit 등) → 검증 불능 → fail-closed.
    echo "blocked:verify-error"
    exit 1
  }

if [ -z "$SIBLING_PR" ] || [ "$SIBLING_PR" = "null" ]; then
  # 이슈를 못 찾음(잘못된 번호·삭제 등) → 검증 불능 → fail-closed.
  echo "blocked:verify-error"
  exit 1
fi

S_STATE=$(echo "$SIBLING_PR" | jq -r '.state')
if [ "$S_STATE" = "CLOSED" ]; then
  # 이슈가 이미 닫힘 = 완료로 간주(critic.yml 라인 223-226 과 동일 — 승인 판정에서 제외).
  echo "ok"
  exit 0
fi

PR_NODES=$(echo "$SIBLING_PR" | jq '.closedByPullRequestsReferences.nodes')
if [ "$(echo "$PR_NODES" | jq 'length')" = "0" ]; then
  # 연결된 open PR 이 없음 = 미완료(critic.yml 라인 229-232).
  echo "blocked:no-pr"
  exit 1
fi

HAS_BLOCKED=$(echo "$PR_NODES" | jq '[.[] | .labels.nodes[] | select(.name == "blocked")] | length')
if [ "$HAS_BLOCKED" -gt 0 ]; then
  # blocked 라벨 = 사람이 명시적으로 막음(critic.yml 라인 234-239).
  echo "blocked:blocked-label"
  exit 1
fi

APPROVED=$(echo "$PR_NODES" | jq --arg bot "$BOT_PREFIX" \
  '[.[] | .reviews.nodes[] | select((.author.login | startswith($bot)) and .state == "APPROVED")] | length')
if [ "$APPROVED" = "0" ]; then
  # Reviewer 봇의 APPROVED 리뷰가 하나도 없음(critic.yml 라인 241-246).
  echo "blocked:no-approval"
  exit 1
fi

if [ "$STRICT_REVIEW_BOT_CHECK" = "true" ]; then
  # strict: 누구의 CHANGES_REQUESTED 든 차단(critic.yml 라인 248-250).
  CHANGES=$(echo "$PR_NODES" | jq \
    '[.[] | .reviews.nodes[] | select(.state == "CHANGES_REQUESTED")] | length')
else
  # 비strict: Reviewer 봇의 CHANGES_REQUESTED 만 차단(critic.yml 라인 251-254).
  CHANGES=$(echo "$PR_NODES" | jq --arg bot "$BOT_PREFIX" \
    '[.[] | .reviews.nodes[] | select((.author.login | startswith($bot)) and .state == "CHANGES_REQUESTED")] | length')
fi
if [ "$CHANGES" != "0" ]; then
  echo "blocked:changes-requested"
  exit 1
fi

echo "ok"
exit 0
