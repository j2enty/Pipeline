import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Probot } from "probot";

// status-poller.ts M6 검증 — "조용한 실패 → 시끄러운 실패".
//
// 핵심 불변식:
//   (a) 전 프로젝트 조회 실패 → runPollingTick 이 throw (tick 승격 → recordTick 스킵
//       → 헬스 degraded 유도) + 실패 프로젝트마다 notifyFailure 1회.
//   (b) 일부 프로젝트만 실패 → throw 안 함 (부분 실패는 tick 성공) + 실패한 그
//       프로젝트에만 notifyFailure.
//
// project-graphql(fetch)·alert(notifyFailure) 는 vi.mock 으로 대체해
// 외부 GitHub API·Slack 없이 실패 경로만 결정적으로 검증한다.

vi.mock("../src/lib/project-graphql", () => ({
  fetchProjectV2Items: vi.fn(),
}));
vi.mock("../src/lib/alert", () => ({
  notifyFailure: vi.fn(),
}));
// 아이템 처리 경로의 다운스트림 — 이걸 throw 시켜 "아이템 처리 실패"를 결정적으로 만든다.
vi.mock("../src/lib/workflow-runs", () => ({
  isWorkflowFileInProgress: vi.fn(),
}));
vi.mock("../src/lib/dispatch", () => ({
  fireRepositoryDispatch: vi.fn(),
}));

import {
  runPollingTick,
  type StatusPollerOptions,
} from "../src/pollers/status-poller";
import {
  fetchProjectV2Items,
  type ProjectV2ItemSnapshot,
} from "../src/lib/project-graphql";
import { notifyFailure } from "../src/lib/alert";
import { isWorkflowFileInProgress } from "../src/lib/workflow-runs";
import { fireRepositoryDispatch } from "../src/lib/dispatch";

const fetchProjectV2ItemsMock = vi.mocked(fetchProjectV2Items);
const notifyFailureMock = vi.mocked(notifyFailure);
const isWorkflowFileInProgressMock = vi.mocked(isWorkflowFileInProgress);
const fireRepositoryDispatchMock = vi.mocked(fireRepositoryDispatch);

// 임의의 Status 컬럼값을 가진 kickoff-형태 아이템(유효 Parent 라인 포함).
function makeItemWithStatus(
  status: string,
  issueNumber: number
): ProjectV2ItemSnapshot {
  return {
    itemNodeId: `item-${issueNumber}`,
    status,
    issue: {
      number: issueNumber,
      state: "OPEN",
      body: "Parent: acme/Backend#99",
      repositoryName: "Backend",
      repositoryOwner: "acme",
    },
  };
}

// "In Progress" 상태 + 유효한 Parent 라인을 가진 kickoff 대상 아이템.
// processProjectItem → dispatchKickoffIfNotRunning → isWorkflowFileInProgress 로 진입한다.
function makeKickoffItem(issueNumber: number): ProjectV2ItemSnapshot {
  return {
    itemNodeId: `item-${issueNumber}`,
    status: "In Progress",
    issue: {
      number: issueNumber,
      state: "OPEN",
      body: "Parent: acme/Backend#99",
      repositoryName: "Backend",
      repositoryOwner: "acme",
    },
  };
}

// app.log 최소 스텁 — runPollingTick 은 info/error/debug/warn 만 부른다 (no-op).
function makeFakeApp(): Probot {
  return {
    log: {
      info: vi.fn(),
      error: vi.fn(),
      debug: vi.fn(),
      warn: vi.fn(),
    },
  } as unknown as Probot;
}

const baseOptions: StatusPollerOptions = {
  ownerLogin: "acme",
  projectNumbers: [3, 5],
  modules: ["Backend", "iOS"],
  authorInstallationId: 12345,
  intervalMs: 60000,
  statusTriggersKickoff: "In Progress",
  statusTriggersReview: "Bot Review",
};

describe("runPollingTick — 조회 실패 관측성 (M6)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("전 프로젝트 조회가 실패하면 throw 하고 프로젝트마다 notifyFailure 를 부른다", async () => {
    fetchProjectV2ItemsMock.mockRejectedValue(new Error("401 Bad credentials"));
    const app = makeFakeApp();

    // 전체 실패 → tick 실패로 승격 (recordTick 스킵 유도).
    await expect(runPollingTick(app, baseOptions)).rejects.toThrow(
      /전 프로젝트/
    );

    // 프로젝트 2개 각각 알림 — 쿨다운 키는 프로젝트 단위로 분리.
    expect(notifyFailureMock).toHaveBeenCalledTimes(2);
    const keys = notifyFailureMock.mock.calls.map(
      ([, opts]) => (opts as { key?: string }).key
    );
    expect(keys).toContain("project-fetch-fail-3");
    expect(keys).toContain("project-fetch-fail-5");
  });

  it("일부 프로젝트만 실패하면 throw 하지 않고 그 프로젝트에만 notifyFailure 를 부른다", async () => {
    // 프로젝트 3 은 실패, 5 는 성공(빈 아이템 → processProjectItem 미실행).
    fetchProjectV2ItemsMock.mockImplementation(async (_app, _id, params) => {
      if (params.projectNumber === 3) {
        throw new Error("일시적 503");
      }
      return [];
    });
    const app = makeFakeApp();

    // 부분 실패는 tick 성공 → throw 없음.
    await expect(runPollingTick(app, baseOptions)).resolves.toBeUndefined();

    // 실패한 프로젝트(3)에만 알림.
    expect(notifyFailureMock).toHaveBeenCalledTimes(1);
    const [, opts] = notifyFailureMock.mock.calls[0];
    expect((opts as { key?: string }).key).toBe("project-fetch-fail-3");
  });

  it("모든 프로젝트 조회가 성공하면 throw·알림 둘 다 없다", async () => {
    fetchProjectV2ItemsMock.mockResolvedValue([]);
    const app = makeFakeApp();

    await expect(runPollingTick(app, baseOptions)).resolves.toBeUndefined();
    expect(notifyFailureMock).not.toHaveBeenCalled();
  });
});

// 조회는 성공했지만 아이템 처리가 실패하는 경우의 관측성 (Codex #1).
//
//   핵심 불변식:
//     (1) fetch 성공 & items≥1 & '모든' 아이템 처리 throw → 프로젝트 실패로 집계.
//         전 프로젝트가 그러면 runPollingTick throw + project-process-fail 알림.
//     (2) '일부' 아이템만 처리 실패(나머지 성공) → 진전 있음 → 프로젝트 실패 아님 → throw 없음.
describe("runPollingTick — 아이템 처리 실패 관측성 (Codex #1)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("전 프로젝트에서 아이템이 전부 처리 실패하면 throw 하고 project-process-fail 알림을 부른다", async () => {
    // 두 프로젝트 모두 kickoff 아이템 반환.
    fetchProjectV2ItemsMock.mockResolvedValue([makeKickoffItem(1)]);
    // 처리 경로(isWorkflowFileInProgress)가 항상 throw → 모든 아이템 처리 실패.
    isWorkflowFileInProgressMock.mockRejectedValue(new Error("500 API 오류"));
    const app = makeFakeApp();

    // 전 프로젝트가 '진전 전무' → tick 실패로 승격.
    await expect(runPollingTick(app, baseOptions)).rejects.toThrow(/전 프로젝트/);

    // 프로젝트마다 process-fail 알림 (fetch 는 성공했으므로 fetch-fail 은 없어야 함).
    expect(notifyFailureMock).toHaveBeenCalledTimes(2);
    const keys = notifyFailureMock.mock.calls.map(
      ([, opts]) => (opts as { key?: string }).key
    );
    expect(keys).toContain("project-process-fail-3");
    expect(keys).toContain("project-process-fail-5");
  });

  it("한 프로젝트의 아이템이 일부만 처리 실패하면(나머지 성공) throw 하지 않고 알림도 없다", async () => {
    // 프로젝트당 아이템 2개. 5 는 아이템 없음(할 일 없음).
    fetchProjectV2ItemsMock.mockImplementation(async (_app, _id, params) => {
      if (params.projectNumber === 3) {
        return [makeKickoffItem(1), makeKickoffItem(2)];
      }
      return [];
    });
    // 첫 아이템 처리만 throw, 나머지는 성공(false → dispatch 경로로 정상 종료).
    // params 에 issue 번호가 없으므로 호출 순서로 구분한다.
    let call = 0;
    isWorkflowFileInProgressMock.mockImplementation(async () => {
      call += 1;
      if (call === 1) throw new Error("일시적 처리 실패");
      return false; // 실행 중 아님 → dispatch 진행(fireRepositoryDispatch 는 mock)
    });
    const app = makeFakeApp();

    // 프로젝트 3 은 1건 성공(진전 있음) → 실패 아님. 프로젝트 5 는 0건 → 실패 아님.
    await expect(runPollingTick(app, baseOptions)).resolves.toBeUndefined();
    expect(notifyFailureMock).not.toHaveBeenCalled();
  });
});

// #106 app-p5 — Status 트리거 컬럼명이 하드코딩이 아니라 주입값을 따르는지 검증.
//   핵심 불변식: processProjectItem 은 options.statusTriggersKickoff/Review 와
//   '정확히' 일치하는 아이템만 dispatch 한다. 프로젝트가 컬럼명을 바꿔 config 로
//   주입하면 그 새 컬럼명으로 트리거되고, 옛 기본값("In Progress")은 트리거하지 않는다.
describe("processProjectItem — Status 트리거 컬럼명 주입 (app-p5)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // dispatch 경로가 진행되도록: 실행 중 아님 → dispatch 호출.
    isWorkflowFileInProgressMock.mockResolvedValue(false);
  });

  const customOptions: StatusPollerOptions = {
    ...baseOptions,
    projectNumbers: [3],
    statusTriggersKickoff: "작업중",
    statusTriggersReview: "리뷰대기",
  };

  it("커스텀 kickoff 컬럼명과 일치하는 아이템만 kickoff dispatch 한다", async () => {
    // "작업중" → 트리거 대상, 옛 기본값 "In Progress" → 무시돼야 함.
    fetchProjectV2ItemsMock.mockResolvedValue([
      makeItemWithStatus("작업중", 1),
      makeItemWithStatus("In Progress", 2),
    ]);
    const app = makeFakeApp();

    await expect(runPollingTick(app, customOptions)).resolves.toBeUndefined();

    // 정확히 1회(#1 만), eventType=kickoff-triggered.
    expect(fireRepositoryDispatchMock).toHaveBeenCalledTimes(1);
    const [, , params] = fireRepositoryDispatchMock.mock.calls[0];
    expect((params as { eventType?: string }).eventType).toBe(
      "kickoff-triggered"
    );
  });

  it("옛 기본 컬럼명('In Progress')은 커스텀 주입 시 아무 것도 트리거하지 않는다(무음 정지 재현 방지)", async () => {
    // 컬럼명을 바꿨는데 주입을 안 하면 발생하던 무음 정지 — 주입값과 안 맞으면 no-op.
    fetchProjectV2ItemsMock.mockResolvedValue([
      makeItemWithStatus("In Progress", 1),
      makeItemWithStatus("Bot Review", 2),
    ]);
    const app = makeFakeApp();

    await expect(runPollingTick(app, customOptions)).resolves.toBeUndefined();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });
});
