import { describe, it, expect } from "vitest";
import type { Context } from "probot";
import { aggregateSiblingApprovalStatus } from "../src/lib/github";

// aggregateSiblingApprovalStatus 는 context.octokit.graphql 한 번을 호출해
// PR → sub-issue → parent → sibling sub-issues → 각 PR review 를 일괄 조회한 뒤
// "전부 APPROVED 인지" 집계한다.
//
// 실제 함수가 context 에서 호출하는 것은 context.octokit.graphql(query, vars) 뿐이므로
// 그 함수만 고정 응답으로 stub 한다 (HTTP 계층 불필요).

// ── 응답 빌더 헬퍼 ─────────────────────────────────────────────
// GraphQL 응답 형태를 테스트에서 읽기 쉽게 조립하기 위한 최소 팩토리.

interface ReviewNode {
  state: string;
  author: { login: string };
}

interface PrNode {
  state: string;
  reviews: { nodes: ReviewNode[] };
}

interface SiblingNode {
  number: number;
  state: string;
  repository: { nameWithOwner: string; name: string };
  closedByPullRequestsReferences: { nodes: PrNode[] };
}

// reviewer-bot 이 APPROVED 한 OPEN PR 한 개를 가진 sibling
function siblingApprovedByBot(name: string, number: number): SiblingNode {
  return {
    number,
    state: "OPEN",
    repository: { nameWithOwner: `acme/${name}`, name },
    closedByPullRequestsReferences: {
      nodes: [
        {
          state: "OPEN",
          reviews: {
            nodes: [
              { state: "APPROVED", author: { login: "review-bot[bot]" } },
            ],
          },
        },
      ],
    },
  };
}

// 아직 승인 리뷰가 없는 (PENDING 리뷰만 있는) sibling
function siblingNotApproved(name: string, number: number): SiblingNode {
  return {
    number,
    state: "OPEN",
    repository: { nameWithOwner: `acme/${name}`, name },
    closedByPullRequestsReferences: {
      nodes: [
        {
          state: "OPEN",
          reviews: {
            nodes: [
              { state: "CHANGES_REQUESTED", author: { login: "review-bot[bot]" } },
            ],
          },
        },
      ],
    },
  };
}

// closing issue + parent + sibling 목록을 감싸는 전체 응답 빌더
function buildResponse(siblings: SiblingNode[]) {
  return {
    repository: {
      pullRequest: {
        closingIssuesReferences: {
          nodes: [
            {
              number: 100,
              parent: {
                number: 7,
                repository: { nameWithOwner: "acme/parent-repo" },
                subIssues: { nodes: siblings },
              },
            },
          ],
        },
      },
    },
  };
}

// graphql 만 stub 한 최소 Context (다른 필드는 이 함수에서 안 씀)
function makeContext(graphqlResponse: unknown): Context<"pull_request_review"> {
  return {
    octokit: {
      graphql: async () => graphqlResponse,
    },
  } as unknown as Context<"pull_request_review">;
}

const baseOptions = {
  prOwner: "acme",
  prRepo: "Backend",
  prNumber: 200,
  reviewerBotLoginPrefix: "review-bot",
  modulesIgnore: [] as string[],
};

describe("aggregateSiblingApprovalStatus", () => {
  it("PR 이 닫는 issue 가 없으면 null 을 반환한다", async () => {
    const response = {
      repository: {
        pullRequest: { closingIssuesReferences: { nodes: [] } },
      },
    };
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result).toBeNull();
  });

  it("닫는 issue 에 parent 가 없으면 null 을 반환한다", async () => {
    const response = {
      repository: {
        pullRequest: {
          closingIssuesReferences: {
            nodes: [{ number: 100, parent: null }],
          },
        },
      },
    };
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result).toBeNull();
  });

  it("pullRequest 가 null 이면 null 을 반환한다", async () => {
    const response = { repository: { pullRequest: null } };
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result).toBeNull();
  });

  it("sibling 이 전부 봇 APPROVED 면 approved == total 로 집계한다", async () => {
    const response = buildResponse([
      siblingApprovedByBot("Backend", 1),
      siblingApprovedByBot("iOS", 2),
    ]);
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result).toEqual({
      parentUrl: "https://github.com/acme/parent-repo/issues/7",
      parentRepo: "acme/parent-repo",
      parentNumber: 7,
      totalSiblings: 2,
      approvedSiblings: 2,
    });
  });

  it("일부만 APPROVED 면 approved < total 로 집계한다", async () => {
    const response = buildResponse([
      siblingApprovedByBot("Backend", 1),
      siblingNotApproved("iOS", 2),
    ]);
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result?.totalSiblings).toBe(2);
    expect(result?.approvedSiblings).toBe(1);
  });

  it("CLOSED 상태 sibling 은 집계에서 제외한다", async () => {
    const closedSibling = siblingApprovedByBot("Admin", 3);
    closedSibling.state = "CLOSED";
    const response = buildResponse([
      siblingApprovedByBot("Backend", 1),
      closedSibling, // CLOSED — total/approved 어디에도 안 들어가야 함
    ]);
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result?.totalSiblings).toBe(1);
    expect(result?.approvedSiblings).toBe(1);
  });

  it("modulesIgnore 에 포함된 모듈은 집계에서 제외한다", async () => {
    const response = buildResponse([
      siblingApprovedByBot("Backend", 1),
      siblingApprovedByBot("Design", 2), // ignore 대상
    ]);
    const result = await aggregateSiblingApprovalStatus(makeContext(response), {
      ...baseOptions,
      modulesIgnore: ["Design"],
    });
    expect(result?.totalSiblings).toBe(1);
    expect(result?.approvedSiblings).toBe(1);
  });

  it("reviewer-bot prefix 와 다른 봇의 APPROVED 는 승인으로 치지 않는다", async () => {
    const sibling: SiblingNode = {
      number: 1,
      state: "OPEN",
      repository: { nameWithOwner: "acme/Backend", name: "Backend" },
      closedByPullRequestsReferences: {
        nodes: [
          {
            state: "OPEN",
            reviews: {
              nodes: [
                // prefix 불일치 — 다른 봇
                { state: "APPROVED", author: { login: "other-bot[bot]" } },
              ],
            },
          },
        ],
      },
    };
    const response = buildResponse([sibling]);
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result?.totalSiblings).toBe(1);
    expect(result?.approvedSiblings).toBe(0);
  });

  it("사람(비-봇)의 APPROVED 는 승인으로 치지 않는다", async () => {
    const sibling: SiblingNode = {
      number: 1,
      state: "OPEN",
      repository: { nameWithOwner: "acme/Backend", name: "Backend" },
      closedByPullRequestsReferences: {
        nodes: [
          {
            state: "OPEN",
            reviews: {
              nodes: [
                // 사람 리뷰어 — prefix 불일치
                { state: "APPROVED", author: { login: "human-dev" } },
              ],
            },
          },
        ],
      },
    };
    const response = buildResponse([sibling]);
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result?.approvedSiblings).toBe(0);
  });

  it("OPEN 이 아닌 PR(MERGED)의 APPROVED 는 승인으로 치지 않는다", async () => {
    const sibling: SiblingNode = {
      number: 1,
      state: "OPEN",
      repository: { nameWithOwner: "acme/Backend", name: "Backend" },
      closedByPullRequestsReferences: {
        nodes: [
          {
            state: "MERGED", // OPEN 아님 → 필터링됨
            reviews: {
              nodes: [
                { state: "APPROVED", author: { login: "review-bot[bot]" } },
              ],
            },
          },
        ],
      },
    };
    const response = buildResponse([sibling]);
    const result = await aggregateSiblingApprovalStatus(
      makeContext(response),
      baseOptions
    );
    expect(result?.approvedSiblings).toBe(0);
  });
});
