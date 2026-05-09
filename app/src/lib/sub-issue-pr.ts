import type { Probot } from "probot";

// sub-issue 에 연결된 OPEN 상태의 PR URL 조회 (review-triggered dispatch 페이로드 용)
//
// 한 sub-issue 가 여러 PR 로 닫히는 경우는 거의 없지만, OPEN 첫 건만 사용.
// 매칭되는 OPEN PR 이 없으면 null 반환 → 폴러는 dispatch 스킵.
export async function findOpenPullRequestUrlForIssue(
  app: Probot,
  authorInstallationId: number,
  options: { owner: string; repo: string; issueNumber: number }
): Promise<string | null> {
  const octokit = await app.auth(authorInstallationId);

  interface QueryResponse {
    repository: {
      issue: {
        closedByPullRequestsReferences: {
          nodes: Array<{ url: string; state: string }>;
        };
      } | null;
    } | null;
  }

  const result = await octokit.graphql<QueryResponse>(
    `
    query($owner: String!, $repo: String!, $num: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $num) {
          closedByPullRequestsReferences(first: 5, includeClosedPrs: false) {
            nodes { url state }
          }
        }
      }
    }
    `,
    {
      owner: options.owner,
      repo: options.repo,
      num: options.issueNumber,
    }
  );

  const openPullRequest =
    result.repository?.issue?.closedByPullRequestsReferences?.nodes?.find(
      (pr) => pr.state === "OPEN"
    );

  return openPullRequest?.url ?? null;
}
