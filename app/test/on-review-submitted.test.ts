import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { Probot } from "probot";

// on-review-submitted 핸들러의 "critic 게이팅"(M8) 회귀 그물.
// 가장 위험한 결정: "언제 critic-triggered 를 쏘느냐". 잘못 쏘면 미완성 상태로 critic 이
// 돌고, 안 쏘면 파이프라인이 멈춘다.
//
// 검증 불변식:
//   - APPROVED 아님 / Reviewer 봇 아님 / REVIEWER_BOT_LOGIN 미설정 → 발사 안 함.
//   - sibling 집계 null → 발사 안 함.
//   - 단일 영역(total<=1) → critic 불필요, 발사 안 함.
//   - 부분 승인(approved < total) → 대기, 발사 안 함.   ← 핵심(미발사)
//   - 전원 승인(approved == total, total>1) → critic-triggered 발사. ← 핵심(발사)
//   - 전원 승인이지만 AUTHOR_INSTALLATION_ID 미설정 → 발사 못 함 + notifyFailure.
//
// github(aggregateSiblingApprovalStatus)·dispatch·alert 는 mock,
// env(parseModulesIgnore) 는 실제 사용. app.on 으로 등록된 콜백을 붙잡아 직접 호출한다.

vi.mock("../src/lib/github", () => ({
  aggregateSiblingApprovalStatus: vi.fn(),
}));
vi.mock("../src/lib/dispatch", () => ({
  fireRepositoryDispatch: vi.fn(),
}));
vi.mock("../src/lib/alert", () => ({
  notifyFailure: vi.fn(),
}));

import { registerOnReviewSubmitted } from "../src/handlers/on-review-submitted";
import { aggregateSiblingApprovalStatus } from "../src/lib/github";
import { fireRepositoryDispatch } from "../src/lib/dispatch";
import { notifyFailure } from "../src/lib/alert";

const aggregateMock = vi.mocked(aggregateSiblingApprovalStatus);
const fireRepositoryDispatchMock = vi.mocked(fireRepositoryDispatch);
const notifyFailureMock = vi.mocked(notifyFailure);

// app.on 으로 등록되는 콜백을 붙잡는 스텁 app. 반환된 handler 를 테스트가 직접 호출한다.
type Handler = (context: unknown) => Promise<void>;
function makeAppCapturingHandler(): { app: Probot; getHandler: () => Handler } {
  let handler: Handler | undefined;
  const app = {
    on: vi.fn((_event: string, cb: Handler) => {
      handler = cb;
    }),
    log: { info: vi.fn(), error: vi.fn(), debug: vi.fn(), warn: vi.fn() },
  } as unknown as Probot;
  return {
    app,
    getHandler: () => {
      if (!handler) throw new Error("handler 미등록");
      return handler;
    },
  };
}

// pull_request_review.submitted 페이로드 최소본.
function makeContext(overrides: {
  reviewState?: string;
  reviewerLogin?: string;
} = {}): unknown {
  return {
    payload: {
      review: {
        state: overrides.reviewState ?? "approved",
        user: { login: overrides.reviewerLogin ?? "review-bot[bot]" },
      },
      pull_request: {
        number: 200,
        html_url: "https://github.com/acme/Backend/pull/200",
      },
      repository: {
        name: "Backend",
        owner: { login: "acme" },
      },
    },
  };
}

// 집계 결과 팩토리 — total/approved 만 관심사.
function siblingStatus(total: number, approved: number) {
  return {
    parentUrl: "https://github.com/acme/parent/issues/7",
    parentRepo: "acme/parent",
    parentNumber: 7,
    totalSiblings: total,
    approvedSiblings: approved,
  };
}

// 각 테스트가 독립적인 env 를 갖도록 저장/복원.
const savedEnv = { ...process.env };
beforeEach(() => {
  vi.clearAllMocks();
  process.env.REVIEWER_BOT_LOGIN = "review-bot[bot]";
  process.env.AUTHOR_INSTALLATION_ID = "12345";
  delete process.env.MODULES_IGNORE;
});
afterEach(() => {
  process.env = { ...savedEnv };
});

// 핸들러를 등록·조회해 주어진 context 로 실행하는 헬퍼.
async function runHandler(context: unknown): Promise<Probot> {
  const { app, getHandler } = makeAppCapturingHandler();
  registerOnReviewSubmitted(app);
  await getHandler()(context);
  return app;
}

describe("on-review-submitted — 조기 스킵 조건", () => {
  it("리뷰 state 가 approved 가 아니면 집계도·발사도 안 한다", async () => {
    await runHandler(makeContext({ reviewState: "changes_requested" }));
    expect(aggregateMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("Reviewer 봇이 아니면 발사하지 않는다", async () => {
    await runHandler(makeContext({ reviewerLogin: "some-human" }));
    expect(aggregateMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("REVIEWER_BOT_LOGIN 미설정이면 발사하지 않는다", async () => {
    delete process.env.REVIEWER_BOT_LOGIN;
    await runHandler(makeContext());
    expect(aggregateMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("[bot] suffix 유무와 무관하게 prefix 로 봇을 식별한다", async () => {
    // env 엔 suffix 없이, 실제 리뷰어는 [bot] suffix 붙은 경우도 매칭돼야 한다.
    process.env.REVIEWER_BOT_LOGIN = "review-bot";
    aggregateMock.mockResolvedValue(siblingStatus(2, 2));
    await runHandler(makeContext({ reviewerLogin: "review-bot[bot]" }));
    expect(aggregateMock).toHaveBeenCalledTimes(1);
    expect(fireRepositoryDispatchMock).toHaveBeenCalledTimes(1);
  });
});

describe("on-review-submitted — critic 게이팅 (핵심)", () => {
  it("sibling 집계가 null 이면 발사하지 않는다", async () => {
    aggregateMock.mockResolvedValue(null);
    await runHandler(makeContext());
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("단일 영역(total<=1)이면 critic 불필요 — 발사하지 않는다", async () => {
    aggregateMock.mockResolvedValue(siblingStatus(1, 1));
    await runHandler(makeContext());
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("부분 승인(approved < total)이면 critic 을 발사하지 않는다 — 대기", async () => {
    aggregateMock.mockResolvedValue(siblingStatus(3, 2));
    await runHandler(makeContext());
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
  });

  it("전원 승인(approved == total, total>1)이면 critic-triggered 를 발사한다", async () => {
    aggregateMock.mockResolvedValue(siblingStatus(2, 2));
    const app = await runHandler(makeContext());

    expect(fireRepositoryDispatchMock).toHaveBeenCalledTimes(1);
    const [, installationId, payload] = fireRepositoryDispatchMock.mock.calls[0];
    expect(installationId).toBe(12345);
    expect(payload).toMatchObject({
      owner: "acme",
      repo: "Backend",
      eventType: "critic-triggered",
      clientPayload: {
        parent_url: "https://github.com/acme/parent/issues/7",
      },
    });
    expect(app.log.info).toHaveBeenCalled();
  });

  it("전원 승인이어도 AUTHOR_INSTALLATION_ID 미설정이면 발사 못 하고 notifyFailure 를 부른다", async () => {
    delete process.env.AUTHOR_INSTALLATION_ID;
    aggregateMock.mockResolvedValue(siblingStatus(2, 2));
    await runHandler(makeContext());

    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
    expect(notifyFailureMock).toHaveBeenCalledTimes(1);
  });
});

describe("on-review-submitted — MODULES_IGNORE 설정 오류", () => {
  it("MODULES_IGNORE 가 깨진 JSON 이면 발사하지 않고 notifyFailure 를 부른다", async () => {
    process.env.MODULES_IGNORE = "[Design]"; // 따옴표 없는 깨진 JSON → parseModulesIgnore throw
    await runHandler(makeContext());
    expect(aggregateMock).not.toHaveBeenCalled();
    expect(fireRepositoryDispatchMock).not.toHaveBeenCalled();
    expect(notifyFailureMock).toHaveBeenCalledTimes(1);
    const [, opts] = notifyFailureMock.mock.calls[0];
    expect((opts as { key?: string }).key).toBe("modules-ignore-parse-error");
  });
});
