import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import crypto from "crypto";
import type { Request, Response } from "express";
import type { Probot } from "probot";
import {
  verifyJanusSignature,
  isTimestampFresh,
  parseInteractionPayload,
  validateSetStatusValue,
  shouldProcessOnce,
  processInteractionCallback,
  createJanusCallbackHandler,
  registerJanusCallback,
  resetJanusDedupeForTest,
  type JanusCallbackDeps,
} from "../src/lib/janus-callback";
import { updateProjectV2ItemStatus } from "../src/lib/project-graphql";

// janus-callback.ts — Slack 버튼 1탭 → Status 전환 콜백 수신부. 핵심 불변식:
//   1. fail-closed — 시크릿 미설정 시 라우트 미등록
//   2. 위조/손상(서명·신선도·JSON) → 401/402, 처리불가(kind·action·value) → 200 무시
//   3. 멱등 — 더블클릭 시 mutation 1세트
//   4. 서명 스킴은 점(.) 구분 — 콜론 스킴 서명은 반드시 실패

const SECRET = "shared-secret";

// 정상 서명 — 수신부와 동일한 점(.) 스킴.
function sign(secret: string, ts: string, body: string): string {
  const base = Buffer.concat([Buffer.from(`${ts}.`, "utf8"), Buffer.from(body, "utf8")]);
  return "v0=" + crypto.createHmac("sha256", secret).update(base).digest("hex");
}

// ingress 콜론 스킴(`v0:{ts}:{body}`)으로 만든 서명 — 이 수신부는 반드시 거부해야 한다.
function signColon(secret: string, ts: string, body: string): string {
  const base = `v0:${ts}:${body}`;
  return "v0=" + crypto.createHmac("sha256", secret).update(base).digest("hex");
}

function makeFakeApp(): Probot {
  return {
    log: {
      info: vi.fn(),
      warn: vi.fn(),
      debug: vi.fn(),
      error: vi.fn(),
    },
  } as unknown as Probot;
}

// ── 순수 함수: verifyJanusSignature ──────────────────────────────────
describe("verifyJanusSignature", () => {
  const ts = "1700000000";
  const body = '{"kind":"interaction"}';

  it("정상 서명은 통과", () => {
    expect(verifyJanusSignature(SECRET, ts, body, sign(SECRET, ts, body))).toBe(true);
  });

  it("바이트 원문(Buffer)로도 통과", () => {
    const buf = Buffer.from(body, "utf8");
    expect(verifyJanusSignature(SECRET, ts, buf, sign(SECRET, ts, body))).toBe(true);
  });

  it("서명 불일치는 실패", () => {
    expect(verifyJanusSignature(SECRET, ts, body, sign("other", ts, body))).toBe(false);
  });

  it("콜론 스킴(v0:{ts}:{body})으로 만든 서명은 반드시 실패", () => {
    expect(verifyJanusSignature(SECRET, ts, body, signColon(SECRET, ts, body))).toBe(false);
  });

  it("v0= 접두 누락은 실패(throw 없이)", () => {
    const hex = sign(SECRET, ts, body).slice(3); // "v0=" 제거
    expect(verifyJanusSignature(SECRET, ts, body, hex)).toBe(false);
  });

  it("비hex·길이 불일치에도 throw 없이 false", () => {
    expect(verifyJanusSignature(SECRET, ts, body, "v0=zzz")).toBe(false);
    expect(verifyJanusSignature(SECRET, ts, body, "garbage")).toBe(false);
  });

  it("빈 secret / 빈 서명은 false", () => {
    expect(verifyJanusSignature("", ts, body, sign(SECRET, ts, body))).toBe(false);
    expect(verifyJanusSignature(SECRET, ts, body, "")).toBe(false);
  });
});

// ── 순수 함수: isTimestampFresh ──────────────────────────────────────
describe("isTimestampFresh", () => {
  const now = 1700000000;
  const w = 300;

  it("창 경계(정확히 +300s / -300s)는 신선", () => {
    expect(isTimestampFresh(now - 300, now, w)).toBe(true);
    expect(isTimestampFresh(now + 300, now, w)).toBe(true);
  });

  it("과거 초과는 stale", () => {
    expect(isTimestampFresh(now - 301, now, w)).toBe(false);
  });

  it("미래 skew 초과는 stale", () => {
    expect(isTimestampFresh(now + 301, now, w)).toBe(false);
  });

  it("비유한(NaN) 은 stale", () => {
    expect(isTimestampFresh(Number("abc"), now, w)).toBe(false);
  });
});

// ── 순수 함수: parseInteractionPayload ───────────────────────────────
describe("parseInteractionPayload", () => {
  it("interaction 은 통과·정규화", () => {
    const p = parseInteractionPayload({
      kind: "interaction",
      source_id: "pipeline",
      action: "set-status",
      correlation_id: "c1",
      user: "U1",
      channel: "C1",
      message_ts: "1.2",
      values: { action_value: "v" },
    });
    expect(p).not.toBeNull();
    expect(p?.action).toBe("set-status");
    expect(p?.correlationId).toBe("c1");
    expect(p?.actionValue).toBe("v");
  });

  it("interaction_raw / event / slash_command 는 null", () => {
    expect(parseInteractionPayload({ kind: "interaction_raw" })).toBeNull();
    expect(parseInteractionPayload({ kind: "event" })).toBeNull();
    expect(parseInteractionPayload({ kind: "slash_command" })).toBeNull();
  });

  it("깨진 JSON 문자열은 안전하게 null", () => {
    expect(parseInteractionPayload("{not json")).toBeNull();
  });

  it("객체 아님(null·숫자)도 null", () => {
    expect(parseInteractionPayload(null)).toBeNull();
    expect(parseInteractionPayload(42)).toBeNull();
  });
});

// ── 순수 함수: validateSetStatusValue ────────────────────────────────
describe("validateSetStatusValue", () => {
  const valid = {
    v: 1,
    t: "set-status",
    projectId: "PVT_abc",
    fieldId: "PVTSSF_def",
    optionId: "opt123",
    items: ["PVTI_1", "PVTI_2"],
    label: "In Progress",
  };

  it("정상 value 통과 (객체·JSON 문자열 둘 다)", () => {
    expect(validateSetStatusValue(valid)).not.toBeNull();
    expect(validateSetStatusValue(JSON.stringify(valid))).not.toBeNull();
    expect(validateSetStatusValue(valid)?.items).toHaveLength(2);
  });

  it("v !== 1 은 null", () => {
    expect(validateSetStatusValue({ ...valid, v: 2 })).toBeNull();
  });

  it("t 불일치는 null", () => {
    expect(validateSetStatusValue({ ...valid, t: "delete" })).toBeNull();
  });

  it("prefix 위반(projectId/fieldId/items)은 null", () => {
    expect(validateSetStatusValue({ ...valid, projectId: "X_abc" })).toBeNull();
    expect(validateSetStatusValue({ ...valid, fieldId: "PVT_def" })).toBeNull();
    expect(validateSetStatusValue({ ...valid, items: ["BAD_1"] })).toBeNull();
  });

  it("optionId 빈 문자열은 null", () => {
    expect(validateSetStatusValue({ ...valid, optionId: "" })).toBeNull();
  });

  it("items 0개·51개는 null", () => {
    expect(validateSetStatusValue({ ...valid, items: [] })).toBeNull();
    const fifty1 = Array.from({ length: 51 }, (_, i) => `PVTI_${i}`);
    expect(validateSetStatusValue({ ...valid, items: fifty1 })).toBeNull();
  });

  it("타입 오류(items 가 배열 아님, label 숫자)는 null", () => {
    expect(validateSetStatusValue({ ...valid, items: "PVTI_1" })).toBeNull();
    expect(validateSetStatusValue({ ...valid, label: 123 })).toBeNull();
  });

  it("깨진 JSON 문자열은 null", () => {
    expect(validateSetStatusValue("{broken")).toBeNull();
  });
});

// ── 순수 함수: shouldProcessOnce ─────────────────────────────────────
describe("shouldProcessOnce", () => {
  it("최초 true → TTL 내 false → TTL 후 true", () => {
    const map = new Map<string, number>();
    expect(shouldProcessOnce("k", 1000, map, 5000)).toBe(true);
    expect(shouldProcessOnce("k", 2000, map, 5000)).toBe(false); // TTL 내
    expect(shouldProcessOnce("k", 7000, map, 5000)).toBe(true); // TTL 경과
  });

  it("키가 다르면 독립적으로 처리", () => {
    const map = new Map<string, number>();
    expect(shouldProcessOnce("a", 1000, map, 5000)).toBe(true);
    expect(shouldProcessOnce("b", 1000, map, 5000)).toBe(true);
  });
});

// ── updateProjectV2ItemStatus (octokit graphql mock) ─────────────────
describe("updateProjectV2ItemStatus", () => {
  it("app.auth 로 얻은 octokit.graphql 을 올바른 변수로 호출", async () => {
    const graphql = vi.fn().mockResolvedValue({});
    const app = {
      auth: vi.fn().mockResolvedValue({ graphql }),
      log: { warn: vi.fn() },
    } as unknown as Probot;

    await updateProjectV2ItemStatus(app, 42, {
      projectId: "PVT_a",
      itemId: "PVTI_b",
      fieldId: "PVTSSF_c",
      optionId: "opt",
    });

    expect(app.auth).toHaveBeenCalledWith(42);
    expect(graphql).toHaveBeenCalledTimes(1);
    const [query, vars] = graphql.mock.calls[0];
    expect(query).toContain("updateProjectV2ItemFieldValue");
    expect(query).toContain("singleSelectOptionId");
    expect(vars).toEqual({
      projectId: "PVT_a",
      itemId: "PVTI_b",
      fieldId: "PVTSSF_c",
      optionId: "opt",
    });
  });
});

// ── 처리 코어: processInteractionCallback ────────────────────────────
describe("processInteractionCallback", () => {
  const validValue = {
    v: 1,
    t: "set-status",
    projectId: "PVT_abc",
    fieldId: "PVTSSF_def",
    optionId: "opt123",
    items: ["PVTI_1", "PVTI_2"],
    label: "In Progress",
  };

  function makePayload(overrides: Record<string, unknown> = {}) {
    return {
      kind: "interaction",
      source_id: "pipeline",
      action: "set-status",
      correlation_id: "c1",
      user: "U1",
      channel: "C1",
      message_ts: "1700.1",
      values: { action_value: JSON.stringify(validValue) },
      ...overrides,
    };
  }

  function makeDeps(overrides: Partial<JanusCallbackDeps> = {}): {
    deps: JanusCallbackDeps;
    updateItemStatus: ReturnType<typeof vi.fn>;
    sendMessageUpdate: ReturnType<typeof vi.fn>;
    notifyFailure: ReturnType<typeof vi.fn>;
    resolveJanusTarget: ReturnType<typeof vi.fn>;
  } {
    const updateItemStatus = vi.fn().mockResolvedValue(undefined);
    const sendMessageUpdate = vi.fn().mockResolvedValue(undefined);
    const notifyFailure = vi.fn().mockResolvedValue(undefined);
    const resolveJanusTarget = vi.fn().mockReturnValue({
      url: "http://janus",
      token: "tok",
      sourceId: "pipeline",
      channel: "Cx",
    });
    const deps: JanusCallbackDeps = {
      app: makeFakeApp(),
      authorInstallationId: 42,
      updateItemStatus: updateItemStatus as never,
      sendMessageUpdate: sendMessageUpdate as never,
      notifyFailure: notifyFailure as never,
      resolveJanusTarget: resolveJanusTarget as never,
      now: () => 1_700_000_000_000,
      dedupeMap: new Map(),
      dedupeTtlMs: 300000,
      ...overrides,
    };
    return { deps, updateItemStatus, sendMessageUpdate, notifyFailure, resolveJanusTarget };
  }

  it("정상 → items 만큼 mutation + 메시지 교체 1회(성공 텍스트)", async () => {
    const { deps, updateItemStatus, sendMessageUpdate } = makeDeps();
    await processInteractionCallback(makePayload(), deps);

    expect(updateItemStatus).toHaveBeenCalledTimes(2);
    expect(sendMessageUpdate).toHaveBeenCalledTimes(1);
    const [, msg] = sendMessageUpdate.mock.calls[0];
    expect(msg.text).toContain("✅");
    expect(msg.text).toContain("In Progress");
    expect(msg.channel).toBe("C1");
    expect(msg.ts).toBe("1700.1");
  });

  it("더블클릭(같은 correlation) → mutation 1세트만", async () => {
    const { deps, updateItemStatus } = makeDeps();
    await processInteractionCallback(makePayload(), deps);
    await processInteractionCallback(makePayload(), deps);
    // 2 items × 1세트 = 2 (두 번째 호출은 멱등 스킵)
    expect(updateItemStatus).toHaveBeenCalledTimes(2);
  });

  it("mutation 부분 실패 → 실패 텍스트 + notifyFailure", async () => {
    const { deps, sendMessageUpdate, notifyFailure } = makeDeps();
    (deps.updateItemStatus as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error("mutation 실패"));

    await processInteractionCallback(makePayload(), deps);

    const [, msg] = sendMessageUpdate.mock.calls[0];
    expect(msg.text).toContain("⚠️");
    expect(msg.text).toContain("1");
    expect(notifyFailure).toHaveBeenCalled();
  });

  it("관심 없는 kind → mutation 0회(무시)", async () => {
    const { deps, updateItemStatus } = makeDeps();
    await processInteractionCallback(makePayload({ kind: "event" }), deps);
    expect(updateItemStatus).not.toHaveBeenCalled();
  });

  it("미지원 action → mutation 0회(무시)", async () => {
    const { deps, updateItemStatus } = makeDeps();
    await processInteractionCallback(makePayload({ action: "reject" }), deps);
    expect(updateItemStatus).not.toHaveBeenCalled();
  });

  it("value 검증 실패 → mutation 0회 + notifyFailure", async () => {
    const { deps, updateItemStatus, notifyFailure } = makeDeps();
    const bad = makePayload({ values: { action_value: JSON.stringify({ v: 9 }) } });
    await processInteractionCallback(bad, deps);
    expect(updateItemStatus).not.toHaveBeenCalled();
    expect(notifyFailure).toHaveBeenCalled();
  });

  it("Janus 타깃 미설정 → 메시지 교체 스킵(하지만 mutation 은 수행)", async () => {
    const { deps, updateItemStatus, sendMessageUpdate } = makeDeps({
      resolveJanusTarget: vi.fn().mockReturnValue(null) as never,
    });
    await processInteractionCallback(makePayload(), deps);
    expect(updateItemStatus).toHaveBeenCalledTimes(2);
    expect(sendMessageUpdate).not.toHaveBeenCalled();
  });

  it("authorInstallationId null → mutation 0회 + notifyFailure", async () => {
    const { deps, updateItemStatus, notifyFailure } = makeDeps({
      authorInstallationId: null,
    });
    await processInteractionCallback(makePayload(), deps);
    expect(updateItemStatus).not.toHaveBeenCalled();
    expect(notifyFailure).toHaveBeenCalled();
  });

  it("처리 중 예외가 밖으로 새지 않는다(notifyFailure 로 수렴)", async () => {
    const { deps, notifyFailure } = makeDeps();
    // updateItemStatus 를 동기 throw 로 만들어 Promise.allSettled 밖 경로를 흔든다.
    deps.updateItemStatus = vi.fn(() => {
      throw new Error("동기 throw");
    }) as never;
    // resolve 로 정상 종료되어야 한다(throw 유출 금지).
    await expect(processInteractionCallback(makePayload(), deps)).resolves.toBeUndefined();
    expect(notifyFailure).toHaveBeenCalled();
  });
});

// ── HTTP 핸들러: createJanusCallbackHandler (상태 코드) ───────────────
describe("createJanusCallbackHandler", () => {
  const NOW_MS = 1_700_000_000_000;
  const NOW_S = Math.floor(NOW_MS / 1000);

  function makeRes(): Response & { status: ReturnType<typeof vi.fn>; json: ReturnType<typeof vi.fn> } {
    const res = {} as Response & { status: ReturnType<typeof vi.fn>; json: ReturnType<typeof vi.fn> };
    res.status = vi.fn(() => res);
    res.json = vi.fn(() => res);
    return res;
  }

  function makeReq(headers: Record<string, string>, body: Buffer): Request {
    return { headers, body } as unknown as Request;
  }

  function makeHandlerDeps(): {
    deps: JanusCallbackDeps;
    updateItemStatus: ReturnType<typeof vi.fn>;
  } {
    const updateItemStatus = vi.fn().mockResolvedValue(undefined);
    const deps: JanusCallbackDeps = {
      app: makeFakeApp(),
      authorInstallationId: 42,
      updateItemStatus: updateItemStatus as never,
      sendMessageUpdate: vi.fn().mockResolvedValue(undefined) as never,
      notifyFailure: vi.fn().mockResolvedValue(undefined) as never,
      resolveJanusTarget: vi.fn().mockReturnValue({
        url: "http://janus",
        token: "t",
        sourceId: "pipeline",
        channel: "Cx",
      }) as never,
      now: () => NOW_MS,
      dedupeMap: new Map(),
      dedupeTtlMs: 300000,
    };
    return { deps, updateItemStatus };
  }

  const validValue = {
    v: 1,
    t: "set-status",
    projectId: "PVT_abc",
    fieldId: "PVTSSF_def",
    optionId: "opt",
    items: ["PVTI_1"],
    label: "In Progress",
  };

  function validBody(): string {
    return JSON.stringify({
      kind: "interaction",
      source_id: "pipeline",
      action: "set-status",
      correlation_id: "c1",
      user: "U1",
      channel: "C1",
      message_ts: "1.2",
      values: { action_value: JSON.stringify(validValue) },
    });
  }

  it("정상 서명·신선 → 200 즉시 + 백그라운드 mutation", async () => {
    const { deps, updateItemStatus } = makeHandlerDeps();
    const handler = createJanusCallbackHandler({ signingSecret: SECRET, replayWindowS: 300 }, deps);
    const body = validBody();
    const ts = String(NOW_S);
    const req = makeReq(
      { "x-janus-signature": sign(SECRET, ts, body), "x-janus-timestamp": ts },
      Buffer.from(body, "utf8")
    );
    const res = makeRes();

    handler(req, res);
    expect(res.status).toHaveBeenCalledWith(200);

    await vi.waitFor(() => expect(updateItemStatus).toHaveBeenCalledTimes(1));
  });

  it("서명 불일치 → 401 + mutation 0회", () => {
    const { deps, updateItemStatus } = makeHandlerDeps();
    const handler = createJanusCallbackHandler({ signingSecret: SECRET, replayWindowS: 300 }, deps);
    const body = validBody();
    const ts = String(NOW_S);
    const req = makeReq(
      { "x-janus-signature": sign("wrong", ts, body), "x-janus-timestamp": ts },
      Buffer.from(body, "utf8")
    );
    const res = makeRes();

    handler(req, res);
    expect(res.status).toHaveBeenCalledWith(401);
    expect(updateItemStatus).not.toHaveBeenCalled();
  });

  it("stale timestamp → 401 + mutation 0회", () => {
    const { deps, updateItemStatus } = makeHandlerDeps();
    const handler = createJanusCallbackHandler({ signingSecret: SECRET, replayWindowS: 300 }, deps);
    const body = validBody();
    const staleTs = String(NOW_S - 1000); // 창 밖
    const req = makeReq(
      { "x-janus-signature": sign(SECRET, staleTs, body), "x-janus-timestamp": staleTs },
      Buffer.from(body, "utf8")
    );
    const res = makeRes();

    handler(req, res);
    expect(res.status).toHaveBeenCalledWith(401);
    expect(updateItemStatus).not.toHaveBeenCalled();
  });

  it("헤더 누락 → 401", () => {
    const { deps } = makeHandlerDeps();
    const handler = createJanusCallbackHandler({ signingSecret: SECRET, replayWindowS: 300 }, deps);
    const req = makeReq({}, Buffer.from("{}", "utf8"));
    const res = makeRes();

    handler(req, res);
    expect(res.status).toHaveBeenCalledWith(401);
  });

  it("서명은 맞지만 깨진 JSON 바디 → 400", () => {
    const { deps, updateItemStatus } = makeHandlerDeps();
    const handler = createJanusCallbackHandler({ signingSecret: SECRET, replayWindowS: 300 }, deps);
    const brokenBody = "{not json";
    const ts = String(NOW_S);
    const req = makeReq(
      { "x-janus-signature": sign(SECRET, ts, brokenBody), "x-janus-timestamp": ts },
      Buffer.from(brokenBody, "utf8")
    );
    const res = makeRes();

    handler(req, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(updateItemStatus).not.toHaveBeenCalled();
  });
});

// ── 라우트 등록: registerJanusCallback (fail-closed) ─────────────────
describe("registerJanusCallback", () => {
  const original = process.env.JANUS_CALLBACK_SIGNING_SECRET;
  afterEach(() => {
    if (original === undefined) {
      delete process.env.JANUS_CALLBACK_SIGNING_SECRET;
    } else {
      process.env.JANUS_CALLBACK_SIGNING_SECRET = original;
    }
    resetJanusDedupeForTest();
  });

  it("시크릿 미설정 → getRouter 자체 미호출(라우트 미등록)", () => {
    delete process.env.JANUS_CALLBACK_SIGNING_SECRET;
    const getRouter = vi.fn();
    registerJanusCallback(getRouter as never, {
      app: makeFakeApp(),
      authorInstallationId: 42,
    });
    expect(getRouter).not.toHaveBeenCalled();
  });

  it("시크릿 설정 → getRouter('/janus') 호출 + POST 라우트 등록", () => {
    process.env.JANUS_CALLBACK_SIGNING_SECRET = SECRET;
    const post = vi.fn();
    const router = { post };
    const getRouter = vi.fn().mockReturnValue(router);
    registerJanusCallback(getRouter as never, {
      app: makeFakeApp(),
      authorInstallationId: 42,
    });
    expect(getRouter).toHaveBeenCalledWith("/janus");
    expect(post).toHaveBeenCalledTimes(1);
    expect(post.mock.calls[0][0]).toBe("/callback");
  });

  it("getRouter 자체가 undefined 면 조용히 스킵", () => {
    process.env.JANUS_CALLBACK_SIGNING_SECRET = SECRET;
    expect(() =>
      registerJanusCallback(undefined, {
        app: makeFakeApp(),
        authorInstallationId: 42,
      })
    ).not.toThrow();
  });
});
