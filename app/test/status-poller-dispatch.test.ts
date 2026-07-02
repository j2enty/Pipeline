import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Probot } from "probot";

// status-poller 의 "결정 로직"(M8) 회귀 그물 — processProjectItem 스킵 조건 +
// dispatch 발사/미발사 판정. status-poller.test.ts(M6)는 실패 관측성이 주제이고,
// 이 파일은 "어느 아이템에 무엇을 쏘느냐"(핵심 위험 로직)를 고정한다.
//
// 검증 불변식:
//   (A) 스킵 조건 — issue 없음 / CLOSED / 모듈 밖 / 트리거 상태 아님 → dispatch 안 함.
//   (B) kickoff — parent URL 있고 미실행 → kickoff-triggered 발사(parent_url 포함).
//       parent URL 없으면 발사 안 함.
//   (C) review  — parent URL + OPEN PR 있고 미실행 → review-triggered 발사(pr_url+parent_url).
//       PR 없으면 발사 안 함.
//   (D) 중복 방지(#19) — isWorkflowFileInProgress=true 면 kickoff·review 둘 다 발사 안 함.
//
// project-graphql·alert·workflow-runs·dispatch·sub-issue-pr 는 mock,
// parent-extractor 는 실제 함수 사용(body "Parent: ..." 파싱까지 함께 검증).

vi.mock("../src/lib/project-graphql", () => ({
  fetchProjectV2Items: vi.fn(),
}));
vi.mock("../src/lib/alert", () => ({
  notifyFailure: vi.fn(),
}));
vi.mock("../src/lib/workflow-runs", () => ({
  isWorkflowFileInProgress: vi.fn(),
}));
vi.mock("../src/lib/dispatch", () => ({
  fireRepositoryDispatch: vi.fn(),
}));
vi.mock("../src/lib/sub-issue-pr", () => ({
  findOpenPullRequestUrlForIssue: vi.fn(),
}));

import {
  runPollingTick,
  type StatusPollerOptions,
} from "../src/pollers/status-poller";
import {
  fetchProjectV2Items,
  type ProjectV2ItemSnapshot,
} from "../src/lib/project-graphql";
import { isWorkflowFileInProgress } from "../src/lib/workflow-runs";
import { fireRepositoryDispatch } from "../src/lib/dispatch";
import { findOpenPullRequestUrlForIssue } from "../src/lib/sub-issue-pr";

const fetchProjectV2ItemsMock = vi.mocked(fetchProjectV2Items);
const isWorkflowFileInProgressMock = vi.mocked(isWorkflowFileInProgress);
const fireRepositoryDispatchMock = vi.mocked(fireRepositoryDispatch);
const findOpenPullRequestUrlForIssueMock = vi.mocked(
  findOpenPullRequestUrlForIssue
);

function makeFakeApp(): Probot {
  return {
    log: { info: vi.fn(), error: vi.fn(), debug: vi.fn(), warn: vi.fn() },
  } as unknown as Probot;
}

// 단일 프로젝트·단일 모듈(Backend) 로 단순화 — 결정 로직만 격리.
// 트리거 컬럼명은 기본값(In Progress/Bot Review) — 이 파일의 아이템 status 와 맞춘다(#106).
const options: StatusPollerOptions = {
  ownerLogin: "acme",
  projectNumbers: [3],
  modules: ["Backend"],
  authorInstallationId: 12345,
  intervalMs: 60000,
  statusTriggersKickoff: "In Progress",
  statusTriggersReview: "Bot Review",
};

// 아이템 팩토리 — 필요한 필드만 덮어쓴다.
type IssueShape = NonNullable<ProjectV2ItemSnapshot["issue"]>;
function makeItem(
  overrides: {
    itemNodeId?: string;
    status?: string;
    issue?: Partial<IssueShape> | null;
  } = {}
): ProjectV2ItemSnapshot {
  const baseIssue = {
    number: 42,
    state: "OPEN",
    body: "Parent: acme/Backend#99",
    repositoryName: "Backend",
    repositoryOwner: "acme",
  };
  const issue =
    overrides.issue === null
      ? null
      : { ...baseIssue, ...(overrides.issue ?? {}) };
  return {
    itemNodeId: overrides.itemNodeId ?? "item-1",
    status: overrides.status ?? "In Progress",
    issue,
  } as ProjectV2ItemSnapshot;
}

// runPollingTick 이 주어진 아이템 1개만 조회하도록 세팅.
function withItem(item: ProjectV2ItemSnapshot): void {
  fetchProjectV2ItemsMock.mockResolvedValue([item]);
}

beforeEach(() => {
  vi.clearAllMocks();
  // 기본값 — 미실행(false) 이라 dispatch 경로가 열림. 개별 테스트에서 덮어씀.
  isWorkflowFileInProgressMock.mockResolvedValue(false);
  findOpenPullRequestUrlForIssueMock.mockResolvedValue(null);
});

describe("processProjectItem — 스킵 조건 (A)", () => {
  it("issue 가 null 인 아이템은 아무것도 하지 않는다", async () => {
    withItem(makeItem({ issue: null }));
    await runPollingTick(makeFakeApp(), options);
    expect(isWorkflowFileInProgressMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("issue.state 가 CLOSED 면 스킵한다", async () => {
    withItem(makeItem({ issue: { state: "CLOSED" } }));
    await runPollingTick(makeFakeApp(), options);
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("repositoryName 이 modules 에 없으면 스킵한다", async () => {
    // Design 은 options.modules(["Backend"])에 없음.
    withItem(makeItem({ issue: { repositoryName: "Design" } }));
    await runPollingTick(makeFakeApp(), options);
    expect(isWorkflowFileInProgressMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("status 가 트리거 상태(In Progress·Bot Review)가 아니면 스킵한다", async () => {
    withItem(makeItem({ status: "Todo" }));
    await runPollingTick(makeFakeApp(), options);
    expect(isWorkflowFileInProgressMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });
});

describe("dispatchKickoff — In Progress 처리 (B, D)", () => {
  it("parent URL 있고 미실행이면 kickoff-triggered 를 발사한다", async () => {
    withItem(makeItem({ status: "In Progress" }));
    await runPollingTick(makeFakeApp(), options);

    expect(fireRepositoryDispatchMock).toHaveBeenCalledTimes(1);
    const [, installationId, payload] = fireRepositoryDispatchMock.mock.calls[0];
    expect(installationId).toBe(12345);
    expect(payload).toMatchObject({
      owner: "acme",
      repo: "Backend",
      eventType: "kickoff-triggered",
      clientPayload: { parent_url: "https://github.com/acme/Backend/issues/99" },
    });
  });

  it("body 에서 parent URL 을 못 뽑으면 발사하지 않는다(실행중 조회도 안 함)", async () => {
    withItem(makeItem({ status: "In Progress", issue: { body: "no parent here" } }));
    await runPollingTick(makeFakeApp(), options);
    expect(isWorkflowFileInProgressMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("이미 실행 중(#19)이면 kickoff 를 발사하지 않는다 — 중복 방지", async () => {
    isWorkflowFileInProgressMock.mockResolvedValue(true);
    withItem(makeItem({ status: "In Progress" }));
    await runPollingTick(makeFakeApp(), options);

    // 실행중 판정은 했지만(부작용 없는 조회) dispatch 는 안 함.
    expect(isWorkflowFileInProgressMock).toHaveBeenCalledTimes(1);
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });
});

describe("dispatchReview — Bot Review 처리 (C, D)", () => {
  it("parent URL + OPEN PR 있고 미실행이면 review-triggered 를 발사한다", async () => {
    findOpenPullRequestUrlForIssueMock.mockResolvedValue(
      "https://github.com/acme/Backend/pull/7"
    );
    withItem(makeItem({ status: "Bot Review" }));
    await runPollingTick(makeFakeApp(), options);

    expect(fireRepositoryDispatchMock).toHaveBeenCalledTimes(1);
    const [, , payload] = fireRepositoryDispatchMock.mock.calls[0];
    expect(payload).toMatchObject({
      owner: "acme",
      repo: "Backend",
      eventType: "review-triggered",
      clientPayload: {
        pr_url: "https://github.com/acme/Backend/pull/7",
        parent_url: "https://github.com/acme/Backend/issues/99",
      },
    });
  });

  it("OPEN PR 이 없으면 review 를 발사하지 않는다(실행중 조회도 안 함)", async () => {
    findOpenPullRequestUrlForIssueMock.mockResolvedValue(null);
    withItem(makeItem({ status: "Bot Review" }));
    await runPollingTick(makeFakeApp(), options);
    expect(isWorkflowFileInProgressMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("이미 실행 중(#19)이면 review 를 발사하지 않는다 — 중복 방지", async () => {
    findOpenPullRequestUrlForIssueMock.mockResolvedValue(
      "https://github.com/acme/Backend/pull/7"
    );
    isWorkflowFileInProgressMock.mockResolvedValue(true);
    withItem(makeItem({ status: "Bot Review" }));
    await runPollingTick(makeFakeApp(), options);

    expect(isWorkflowFileInProgressMock).toHaveBeenCalledTimes(1);
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });
});
