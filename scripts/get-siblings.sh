#!/usr/bin/env bash
# get-siblings.sh — PR이 닫는 sub-issue의 sibling 목록 조회
#
# 배경:
#   auto-merge.yml 과 auto-critic.yml 양쪽에서 동일한 "PR → sub-issue → parent →
#   sibling 목록" GraphQL 조회를 반복. 이 스크립트로 공통화.
#
# 사용법:
#   RESULT=$(GH_TOKEN=<token> ./scripts/get-siblings.sh <PR_REPO> <PR_NUMBER>)
#
# 인자:
#   $1: PR_REPO   — 레포 (owner/repo 형식, 예: MKFactory-Reclip/Backend)
#   $2: PR_NUMBER — PR 번호
#
# 환경변수:
#   GH_TOKEN        — 인증 토큰 (필수)
#   MODULES_IGNORE  — 제외할 모듈 JSON 배열 (예: '["Design","Docs"]')
#                     미설정 시 기본값 '[]'
#
# 출력 (JSON, stdout):
#   성공:
#     {
#       "parent_url": "https://github.com/org/repo/issues/N",
#       "parent_repo": "org/repo",
#       "parent_number": N,
#       "sibling_count": N,
#       "siblings": [
#         { "repo": "org/Backend", "issue_number": N }
#       ]
#     }
#   에러:
#     { "error": "no-sub-issue" }   — PR이 sub-issue를 닫지 않음
#     { "error": "no-parent" }      — sub-issue에 parent 없음
#
# 예:
#   RESULT=$(GH_TOKEN=$TOKEN MODULES_IGNORE='["Design"]' \
#     ./scripts/get-siblings.sh MKFactory-Reclip/Backend 42)
#   SIBLING_COUNT=$(echo "$RESULT" | jq '.sibling_count')

set -euo pipefail

PR_REPO="${1:?PR_REPO 인자 필요 (예: org/Backend)}"
PR_NUMBER="${2:?PR_NUMBER 인자 필요}"
MODULES_IGNORE="${MODULES_IGNORE:-[]}"

PR_OWNER=$(echo "$PR_REPO" | cut -d/ -f1)
PR_REPO_NAME=$(echo "$PR_REPO" | cut -d/ -f2)

# PR → sub-issue → parent → sibling 일괄 조회
SUB_ISSUE_JSON=$(gh api graphql -f query='
  query($owner: String!, $repo: String!, $num: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $num) {
        closingIssuesReferences(first: 5) {
          nodes {
            number
            repository { nameWithOwner }
            parent {
              number
              repository { nameWithOwner }
              subIssues(first: 50) {
                nodes {
                  number
                  state
                  repository { nameWithOwner }
                }
              }
            }
          }
        }
      }
    }
  }
' -f owner="$PR_OWNER" -f repo="$PR_REPO_NAME" -F num="$PR_NUMBER" \
  --jq '.data.repository.pullRequest.closingIssuesReferences.nodes[0]')

if [ -z "$SUB_ISSUE_JSON" ] || [ "$SUB_ISSUE_JSON" = "null" ]; then
  echo '{"error":"no-sub-issue"}'
  exit 0
fi

PARENT_JSON=$(echo "$SUB_ISSUE_JSON" | jq '.parent')
if [ -z "$PARENT_JSON" ] || [ "$PARENT_JSON" = "null" ]; then
  echo '{"error":"no-parent"}'
  exit 0
fi

PARENT_REPO=$(echo "$PARENT_JSON" | jq -r '.repository.nameWithOwner')
PARENT_NUM=$(echo "$PARENT_JSON" | jq -r '.number')
PARENT_URL="https://github.com/$PARENT_REPO/issues/$PARENT_NUM"

# modules-ignore 필터 적용 — 레포 이름 기준으로 제외
RESULT=$(python3 - <<EOF
import json, sys

parent = json.loads("""$PARENT_JSON""")
modules_ignore = json.loads("""$MODULES_IGNORE""")

siblings = []
for node in parent['subIssues']['nodes']:
    repo = node['repository']['nameWithOwner']
    repo_name = repo.split('/')[-1]
    if repo_name not in modules_ignore:
        siblings.append({
            'repo': repo,
            'issue_number': node['number']
        })

print(json.dumps({
    'parent_url': '$PARENT_URL',
    'parent_repo': '$PARENT_REPO',
    'parent_number': $PARENT_NUM,
    'sibling_count': len(siblings),
    'siblings': siblings
}))
EOF
)

echo "$RESULT"
