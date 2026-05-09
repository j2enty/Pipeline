import type { Context } from "probot";

// PR이 닫는 sub-issue → parent → sibling sub-issue들의 review 집계 결과
export interface SiblingApprovalAggregate {
  parentUrl: string;
  parentRepo: string;
  parentNumber: number;
  totalSiblings: number;
  approvedSiblings: number;
}

// GraphQL 응답 타입 (선언만)
interface SiblingQueryResponse {
  repository: {
    pullRequest: {
      closingIssuesReferences: {
        nodes: Array<{
          number: number;
          parent: {
            number: number;
            repository: { nameWithOwner: string };
            subIssues: {
              nodes: Array<{
                number: number;
                state: string;
                repository: { nameWithOwner: string; name: string };
                closedByPullRequestsReferences: {
                  nodes: Array<{
                    state: string;
                    reviews: {
                      nodes: Array<{
                        state: string;
                        author: { login: string };
                      }>;
                    };
                  }>;
                };
              }>;
            };
          } | null;
        }>;
      };
    } | null;
  };
}

// PR review APPROVED 시 sibling 전부 APPROVED 인지 집계
//
// 한 GraphQL 쿼리로 PR → sub-issue → parent → sibling sub-issues → 각 PR review
// 까지 일괄 조회. modules-ignore 에 포함된 모듈은 sibling 집계에서 제외.
//
// 반환값:
//   - null: PR 이 sub-issue 를 닫지 않거나 parent 가 없음 → critic 대상 아님
//   - SiblingApprovalAggregate: parent + sibling APPROVED 카운트
export async function aggregateSiblingApprovalStatus(
  context: Context<"pull_request_review">,
  options: {
    prOwner: string;
    prRepo: string;
    prNumber: number;
    reviewerBotLoginPrefix: string;
    modulesIgnore: string[];
  }
): Promise<SiblingApprovalAggregate | null> {
  const { prOwner, prRepo, prNumber, reviewerBotLoginPrefix, modulesIgnore } =
    options;

  const result = await context.octokit.graphql<SiblingQueryResponse>(
    `
    query($owner: String!, $repo: String!, $num: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $num) {
          closingIssuesReferences(first: 5) {
            nodes {
              number
              parent {
                number
                repository { nameWithOwner }
                subIssues(first: 50) {
                  nodes {
                    number
                    state
                    repository { nameWithOwner name }
                    closedByPullRequestsReferences(first: 3, includeClosedPrs: false) {
                      nodes {
                        state
                        reviews(first: 20) {
                          nodes {
                            state
                            author { login }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    `,
    { owner: prOwner, repo: prRepo, num: prNumber }
  );

  const closingNodes =
    result.repository.pullRequest?.closingIssuesReferences?.nodes ?? [];
  const subIssue = closingNodes[0];
  if (!subIssue?.parent) return null;

  const parent = subIssue.parent;
  const parentRepo = parent.repository.nameWithOwner;
  const parentNumber = parent.number;
  const parentUrl = `https://github.com/${parentRepo}/issues/${parentNumber}`;

  // 영역 모듈만 필터링 (modules-ignore 제외, 닫힌 sub-issue 제외)
  const activeSiblings = parent.subIssues.nodes.filter(
    (sib) =>
      sib.state !== "CLOSED" && !modulesIgnore.includes(sib.repository.name)
  );

  // 각 sibling 의 OPEN PR 중 reviewer-bot APPROVED 가 있는지 확인
  let approvedCount = 0;
  for (const sib of activeSiblings) {
    const openPullRequests = sib.closedByPullRequestsReferences.nodes.filter(
      (pr) => pr.state === "OPEN"
    );
    const isApproved = openPullRequests.some((pr) =>
      pr.reviews.nodes.some(
        (review) =>
          review.state === "APPROVED" &&
          review.author.login.startsWith(reviewerBotLoginPrefix)
      )
    );
    if (isApproved) approvedCount++;
  }

  return {
    parentUrl,
    parentRepo,
    parentNumber,
    totalSiblings: activeSiblings.length,
    approvedSiblings: approvedCount,
  };
}
