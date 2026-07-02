import { describe, it, expect, vi } from "vitest";
import type { Probot } from "probot";
import { isWorkflowFileInProgress } from "../src/lib/workflow-runs";

// isWorkflowFileInProgress — 특정 workflow yml 이 in_progress/queued 인지 판정해
// 폴러의 "중복 dispatch 방지"를 담당한다. #19 회귀 대상:
//   - queued(runner 없어 시작 대기 중) 도 "실행 중"으로 봐야 중복 dispatch 를 막는다.
//   - 조회 실패는 false 로 폴백해 "미실행보다는 중복 실행" 정책(yml 멱등성으로 흡수)을 지킨다.
//
// 실제 함수가 쓰는 것은 app.auth() → octokit.rest.actions.listWorkflowRuns 뿐이라
// 그 두 겹만 스텁한다(HTTP 계층 불필요).

// listWorkflowRuns 를 status 별(in_progress/queued) 응답으로 흉내내는 octokit 스텁.
// 함수는 두 status 를 Promise.all 로 동시 조회하므로 status 인자로 분기한다.
function makeOctokit(counts: {
  inProgress?: number;
  queued?: number;
  throwOn?: "in_progress" | "queued" | "both";
}) {
  return {
    rest: {
      actions: {
        listWorkflowRuns: vi.fn(
          async (params: { status: "in_progress" | "queued" }) => {
            if (counts.throwOn === "both" || counts.throwOn === params.status) {
              throw new Error(`403 Forbidden (${params.status})`);
            }
            const total =
              params.status === "in_progress"
                ? counts.inProgress ?? 0
                : counts.queued ?? 0;
            return { data: { total_count: total } };
          }
        ),
      },
    },
  };
}

// app.auth(id) 가 위 octokit 을 돌려주도록 만든 최소 app 스텁.
function makeApp(octokit: unknown): Probot {
  return {
    auth: vi.fn(async () => octokit),
    log: { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() },
  } as unknown as Probot;
}

const opts = {
  owner: "acme",
  repo: "Backend",
  workflowFileName: "auto-kickoff.yml",
};

describe("isWorkflowFileInProgress — 중복 dispatch 방지 판정 (#19)", () => {
  it("in_progress 실행이 1건 이상이면 true (실행 중 → dispatch 스킵)", async () => {
    const app = makeApp(makeOctokit({ inProgress: 1, queued: 0 }));
    await expect(isWorkflowFileInProgress(app, 123, opts)).resolves.toBe(true);
  });

  it("queued 실행이 1건 이상이면 true — runner 대기 중도 '실행 중'으로 본다(#19 회귀)", async () => {
    // #19 핵심: queued 를 안 세면 runner 없이 대기 중인 run 을 못 봐서 중복 dispatch 됐다.
    const app = makeApp(makeOctokit({ inProgress: 0, queued: 1 }));
    await expect(isWorkflowFileInProgress(app, 123, opts)).resolves.toBe(true);
  });

  it("in_progress·queued 둘 다 0건이면 false (실행 중 아님 → dispatch 진행)", async () => {
    const app = makeApp(makeOctokit({ inProgress: 0, queued: 0 }));
    await expect(isWorkflowFileInProgress(app, 123, opts)).resolves.toBe(false);
  });

  it("조회가 실패하면 false 로 폴백한다 (안전한 false — 중복은 yml 멱등성이 흡수)", async () => {
    const app = makeApp(makeOctokit({ throwOn: "both" }));
    await expect(isWorkflowFileInProgress(app, 123, opts)).resolves.toBe(false);
  });

  it("한쪽 조회만 실패해도(Promise.all reject) false 로 폴백한다", async () => {
    // Promise.all 은 하나라도 reject 하면 전체 reject → catch → false.
    const app = makeApp(makeOctokit({ inProgress: 5, throwOn: "queued" }));
    await expect(isWorkflowFileInProgress(app, 123, opts)).resolves.toBe(false);
  });

  it("조회 시 주입된 owner/repo/workflowFileName·installationId 를 그대로 넘긴다", async () => {
    const octokit = makeOctokit({ inProgress: 0, queued: 0 });
    const app = makeApp(octokit);
    await isWorkflowFileInProgress(app, 777, opts);
    const calls = (
      octokit.rest.actions.listWorkflowRuns as ReturnType<typeof vi.fn>
    ).mock.calls;
    // in_progress + queued 두 번 호출, 둘 다 동일한 식별자를 실어야 한다.
    expect(calls).toHaveLength(2);
    for (const [params] of calls) {
      expect(params).toMatchObject({
        owner: "acme",
        repo: "Backend",
        workflow_id: "auto-kickoff.yml",
      });
    }
    // app.auth 는 주입된 installationId 로 호출된다.
    expect(app.auth).toHaveBeenCalledWith(777);
  });
});
