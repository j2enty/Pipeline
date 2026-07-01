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

import { runPollingTick, type StatusPollerOptions } from "../src/pollers/status-poller";
import { fetchProjectV2Items } from "../src/lib/project-graphql";
import { notifyFailure } from "../src/lib/alert";

const fetchProjectV2ItemsMock = vi.mocked(fetchProjectV2Items);
const notifyFailureMock = vi.mocked(notifyFailure);

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
