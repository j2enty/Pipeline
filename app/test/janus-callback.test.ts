import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import crypto from "crypto";
import express from "express";
import request from "supertest";
import type { Request, Response } from "express";
import type { Probot } from "probot";
import {
  verifyJanusSignature,
  isTimestampFresh,
  parseInteractionPayload,
  validateSetStatusValue,
  beginProcessingOnce,
  confirmProcessed,
  releaseProcessing,
  processInteractionCallback,
  createJanusCallbackHandler,
  registerJanusCallback,
  resetJanusDedupeForTest,
  type JanusCallbackDeps,
  type DedupeEntry,
} from "../src/lib/janus-callback";
import { updateProjectV2ItemStatus } from "../src/lib/project-graphql";

// janus-callback.ts — Slack 버튼 1탭 → Status 전환 콜백 수신부. 핵심 불변식:
//   1. fail-closed — 시크릿 미설정 시 라우트 미등록
//   2. 위조/손상(서명·신선도·JSON) → 401/400, 처리불가(kind·action·value) → 200 무시
//   3. 멱등 — 성공 후 확정: 더블클릭 시 mutation 1세트, 실패 시 재클릭 복구 가능
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

  it("items 중복은 유니크화되어 반환", () => {
    const dup = { ...valid, items: ["PVTI_1", "PVTI_1", "PVTI_2"] };
    expect(validateSetStatusValue(dup)?.items).toEqual(["PVTI_1", "PVTI_2"]);
  });

  it("label 은 개행 제거 + 80자 절단(Slack 메시지 새니타이즈)", () => {
    const messy = { ...valid, label: "In\nProgress\r\n중" };
    expect(validateSetStatusValue(messy)?.label).toBe("In Progress 중");

    const long = { ...valid, label: "가".repeat(100) };
    expect(validateSetStatusValue(long)?.label).toBe("가".repeat(80));
  });

  it("label 절단은 코드포인트 단위 — 이모지(서로게이트 페어)를 반토막 내지 않는다", () => {
    // "😀" 는 UTF-16 유닛 2개 — 유닛 단위 slice(0,80)라면 40번째 이모지에서 깨진다.
    const emojiLong = { ...valid, label: "😀".repeat(100) };
    expect(validateSetStatusValue(emojiLong)?.label).toBe("😀".repeat(80));
  });
});

// ── 순수 함수: 멱등 dedupe (begin / confirm / release) ────────────────
describe("beginProcessingOnce / confirmProcessed / releaseProcessing", () => {
  it("최초 begin true(in-flight) → confirm 후 TTL 내 false → TTL 후 true", () => {
    const map = new Map<string, DedupeEntry>();
    expect(beginProcessingOnce("k", 1000, map, 5000)).toBe(true);
    confirmProcessed("k", 1000, map);
    expect(beginProcessingOnce("k", 2000, map, 5000)).toBe(false); // completed & TTL 내
    expect(beginProcessingOnce("k", 7000, map, 5000)).toBe(true); // TTL 경과
  });

  it("in-flight 중에는 begin false (동시 더블클릭 차단)", () => {
    const map = new Map<string, DedupeEntry>();
    expect(beginProcessingOnce("k", 1000, map, 5000)).toBe(true);
    // confirm 없이(처리 중) 재시도 → 차단. TTL 지나도 in-flight 는 유지.
    expect(beginProcessingOnce("k", 2000, map, 5000)).toBe(false);
    expect(beginProcessingOnce("k", 99999, map, 5000)).toBe(false);
  });

  it("release 후에는 즉시 재처리 가능 (실패 복구 경로)", () => {
    const map = new Map<string, DedupeEntry>();
    expect(beginProcessingOnce("k", 1000, map, 5000)).toBe(true);
    releaseProcessing("k", map);
    expect(beginProcessingOnce("k", 1001, map, 5000)).toBe(true);
  });

  it("키가 다르면 독립적으로 처리", () => {
    const map = new Map<string, DedupeEntry>();
    expect(beginProcessingOnce("a", 1000, map, 5000)).toBe(true);
    expect(beginProcessingOnce("b", 1000, map, 5000)).toBe(true);
  });

  it("만료된 completed 항목은 begin 시 정리된다(무한 성장 방지)", () => {
    const map = new Map<string, DedupeEntry>();
    beginProcessingOnce("old", 1000, map, 5000);
    confirmProcessed("old", 1000, map);
    beginProcessingOnce("new", 7000, map, 5000); // old 는 TTL 만료 → 정리
    expect(map.has("old")).toBe(false);
    expect(map.has("new")).toBe(true);
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
  // source_id 대조는 env JANUS_SOURCE_ID(기본 "pipeline") 기준 — ambient 오염 차단.
  beforeEach(() => {
    delete process.env.JANUS_SOURCE_ID;
    resetJanusDedupeForTest();
  });
  afterEach(() => {
    delete process.env.JANUS_SOURCE_ID;
  });

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

  it("정상 → items 만큼 mutation + 메시지 교체 1회(성공 텍스트·버튼 부재)", async () => {
    const { deps, updateItemStatus, sendMessageUpdate } = makeDeps();
    await processInteractionCallback(makePayload(), deps);

    expect(updateItemStatus).toHaveBeenCalledTimes(2);
    expect(sendMessageUpdate).toHaveBeenCalledTimes(1);
    const [, msg] = sendMessageUpdate.mock.calls[0];
    expect(msg.text).toContain("✅");
    expect(msg.text).toContain("In Progress");
    expect(msg.channel).toBe("C1");
    expect(msg.ts).toBe("1700.1");
    // 성공 경로는 버튼 제거(buttons 미지정) — 더 누를 이유가 없다.
    expect(msg.buttons).toBeUndefined();
  });

  it("성공 후 재클릭(같은 correlation) → mutation 1세트만 (completed 확정)", async () => {
    const { deps, updateItemStatus } = makeDeps();
    await processInteractionCallback(makePayload(), deps);
    await processInteractionCallback(makePayload(), deps);
    // 2 items × 1세트 = 2 (두 번째 호출은 멱등 스킵)
    expect(updateItemStatus).toHaveBeenCalledTimes(2);
  });

  it("전건 실패 후 재클릭 → dedupe 키 해제로 mutation 재실행 (복구 경로)", async () => {
    const { deps, updateItemStatus } = makeDeps();
    // 1차 클릭: 전건 실패 → 키 해제되어야 함.
    updateItemStatus.mockRejectedValue(new Error("전건 실패"));
    await processInteractionCallback(makePayload(), deps);
    expect(updateItemStatus).toHaveBeenCalledTimes(2);

    // 2차 클릭(재시도): 성공 경로 → 재실행되어야 함(성공-후-확정 모델).
    updateItemStatus.mockResolvedValue(undefined);
    await processInteractionCallback(makePayload(), deps);
    expect(updateItemStatus).toHaveBeenCalledTimes(4);

    // 3차 클릭: 직전이 성공(confirmed) → 멱등 스킵.
    await processInteractionCallback(makePayload(), deps);
    expect(updateItemStatus).toHaveBeenCalledTimes(4);
  });

  it("동시 더블클릭(같은 correlation 2건 병행) → mutation 1세트만 (in-flight 차단)", async () => {
    const { deps, updateItemStatus } = makeDeps();
    // mutation 이 이벤트 루프를 양보하는 동안 두 번째 호출이 도착하는 상황 재현.
    updateItemStatus.mockImplementation(
      () => new Promise((resolve) => setTimeout(resolve, 1))
    );
    await Promise.all([
      processInteractionCallback(makePayload(), deps),
      processInteractionCallback(makePayload(), deps),
    ]);
    expect(updateItemStatus).toHaveBeenCalledTimes(2); // 1세트(2 items)만
  });

  it("mutation 은 직렬 실행 (동시 in-flight 최대 1건 — rate limit 방어)", async () => {
    const { deps, updateItemStatus } = makeDeps();
    let activeCount = 0;
    let maxActiveCount = 0;
    updateItemStatus.mockImplementation(async () => {
      activeCount += 1;
      maxActiveCount = Math.max(maxActiveCount, activeCount);
      await new Promise((resolve) => setTimeout(resolve, 1));
      activeCount -= 1;
    });
    const threeItems = { ...validValue, items: ["PVTI_1", "PVTI_2", "PVTI_3"] };
    await processInteractionCallback(
      makePayload({ values: { action_value: JSON.stringify(threeItems) } }),
      deps
    );
    expect(updateItemStatus).toHaveBeenCalledTimes(3);
    expect(maxActiveCount).toBe(1);
  });

  it("중복 items → 유니크화되어 mutation 1회씩만", async () => {
    const { deps, updateItemStatus } = makeDeps();
    const dupItems = { ...validValue, items: ["PVTI_1", "PVTI_1", "PVTI_2"] };
    await processInteractionCallback(
      makePayload({ values: { action_value: JSON.stringify(dupItems) } }),
      deps
    );
    expect(updateItemStatus).toHaveBeenCalledTimes(2);
  });

  it("correlation_id 등 필수 필드 누락 → mutation 0회 + notifyFailure 관측", async () => {
    const requiredFields = ["correlation_id", "user", "channel", "message_ts"];
    for (const field of requiredFields) {
      const { deps, updateItemStatus, notifyFailure } = makeDeps();
      await processInteractionCallback(makePayload({ [field]: "" }), deps);
      expect(updateItemStatus).not.toHaveBeenCalled();
      expect(notifyFailure).toHaveBeenCalled();
    }
  });

  it("correlation_id 누락 클릭이 이어져도 정상 클릭은 유실되지 않는다", async () => {
    // 회귀 방지: 빈 correlation_id 가 dedupe 키(":set-status")를 오염시켜
    // 이후 정상 클릭이 스킵되는 버그 경로. 누락 건은 dedupe 전에 걸러져야 한다.
    const { deps, updateItemStatus } = makeDeps();
    await processInteractionCallback(makePayload({ correlation_id: "" }), deps);
    await processInteractionCallback(makePayload({ correlation_id: "real" }), deps);
    expect(updateItemStatus).toHaveBeenCalledTimes(2); // 정상 클릭 1세트 수행
  });

  it("source_id 불일치 → mutation 0회(무시)", async () => {
    const { deps, updateItemStatus } = makeDeps();
    await processInteractionCallback(makePayload({ source_id: "other-app" }), deps);
    expect(updateItemStatus).not.toHaveBeenCalled();
  });

  it("JANUS_SOURCE_ID 설정 시 그 값과 대조", async () => {
    process.env.JANUS_SOURCE_ID = "my-pipeline";
    const { deps, updateItemStatus } = makeDeps();
    // 기본값 "pipeline" 은 이제 불일치 → 무시.
    await processInteractionCallback(makePayload(), deps);
    expect(updateItemStatus).not.toHaveBeenCalled();
    // env 와 일치하는 source_id 는 처리.
    await processInteractionCallback(makePayload({ source_id: "my-pipeline" }), deps);
    expect(updateItemStatus).toHaveBeenCalledTimes(2);
  });

  it("mutation 부분 실패 → 실패 텍스트 + notifyFailure + '다시 시도' 버튼 재부착", async () => {
    const { deps, sendMessageUpdate, notifyFailure } = makeDeps();
    (deps.updateItemStatus as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error("mutation 실패"));

    await processInteractionCallback(makePayload(), deps);

    const [, msg] = sendMessageUpdate.mock.calls[0];
    expect(msg.text).toContain("⚠️");
    expect(msg.text).toContain("1");
    expect(msg.text).toContain("다시 시도");
    // 실패 경로는 dedupe 키를 해제하므로 재클릭 수단(버튼)도 남아야 한다 —
    // 콜백의 action_value 원문 그대로 재부착돼야 재클릭이 동일 payload 로 온다.
    expect(msg.buttons).toEqual([
      {
        action: "set-status",
        label: "다시 시도",
        value: JSON.stringify(validValue),
      },
    ]);
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
    // updateItemStatus 를 동기 throw 로 만들어 직렬 루프의 예외 경로를 흔든다.
    deps.updateItemStatus = vi.fn(() => {
      throw new Error("동기 throw");
    }) as never;
    // resolve 로 정상 종료되어야 한다(throw 유출 금지).
    await expect(processInteractionCallback(makePayload(), deps)).resolves.toBeUndefined();
    expect(notifyFailure).toHaveBeenCalled();
  });

  it("실패 + 후속 단계 예외까지 겹쳐도 키는 해제되어 재클릭 복구 가능", async () => {
    const { deps, updateItemStatus } = makeDeps();
    // 전건 실패 후 메시지 교체 단계(resolveJanusTarget)마저 throw → outer catch 경로.
    // 어느 경로로 죽든 in-flight 키가 남아 영구 차단되면 안 된다.
    updateItemStatus.mockRejectedValue(new Error("전건 실패"));
    (deps.resolveJanusTarget as ReturnType<typeof vi.fn>).mockImplementation(() => {
      throw new Error("타깃 해석 예외");
    });
    await expect(processInteractionCallback(makePayload(), deps)).resolves.toBeUndefined();

    // 키가 해제됐으므로 재클릭이 재실행돼야 한다.
    updateItemStatus.mockResolvedValue(undefined);
    (deps.resolveJanusTarget as ReturnType<typeof vi.fn>).mockReturnValue(null);
    await processInteractionCallback(makePayload(), deps);
    expect(updateItemStatus).toHaveBeenCalledTimes(4); // 2 + 2 (재실행됨)
  });
});

// ── HTTP 핸들러: createJanusCallbackHandler (상태 코드) ───────────────
describe("createJanusCallbackHandler", () => {
  const NOW_MS = 1_700_000_000_000;
  const NOW_S = Math.floor(NOW_MS / 1000);

  beforeEach(() => {
    delete process.env.JANUS_SOURCE_ID; // 기본 "pipeline" 대조 경로 고정
    resetJanusDedupeForTest();
  });

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

  it("body 가 Buffer 가 아님(상위 미들웨어 선소비) → 500 + error 로그 (무음 사망 방지)", () => {
    const { deps, updateItemStatus } = makeHandlerDeps();
    const handler = createJanusCallbackHandler({ signingSecret: SECRET, replayWindowS: 300 }, deps);
    const body = validBody();
    const ts = String(NOW_S);
    // 전역 JSON 미들웨어가 body 를 먼저 파싱해버린 배선 사고 재현 — body 가 객체.
    const req = {
      headers: { "x-janus-signature": sign(SECRET, ts, body), "x-janus-timestamp": ts },
      body: JSON.parse(body),
    } as unknown as Request;
    const res = makeRes();

    handler(req, res);
    expect(res.status).toHaveBeenCalledWith(500);
    expect(updateItemStatus).not.toHaveBeenCalled();
    expect(deps.app.log.error).toHaveBeenCalled();
  });
});

// ── 통합: 실제 express 앱 + express.raw 경로 (supertest) ──────────────
// express.raw 가 핸들러에 실제로 Buffer 를 준다는 계약을 라우터 레벨에서 박제한다.
describe("registerJanusCallback 통합 (실제 express)", () => {
  const NOW_MS = 1_700_000_000_000;
  const NOW_S = Math.floor(NOW_MS / 1000);

  beforeEach(() => {
    process.env.JANUS_CALLBACK_SIGNING_SECRET = SECRET;
    delete process.env.JANUS_SOURCE_ID;
    delete process.env.JANUS_CALLBACK_REPLAY_WINDOW_S;
    resetJanusDedupeForTest();
  });
  afterEach(() => {
    delete process.env.JANUS_CALLBACK_SIGNING_SECRET;
  });

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
      correlation_id: "c-int",
      user: "U1",
      channel: "C1",
      message_ts: "1.2",
      values: { action_value: JSON.stringify(validValue) },
    });
  }

  // probot 의 getRouter 와 동일한 계약(express.Router 반환·경로 마운트)을 재현.
  function makeIntegrationApp(): {
    server: express.Express;
    updateItemStatus: ReturnType<typeof vi.fn>;
  } {
    const server = express();
    const getRouter = (path?: string) => {
      const router = express.Router();
      server.use(path ?? "/", router);
      return router;
    };
    const updateItemStatus = vi.fn().mockResolvedValue(undefined);
    registerJanusCallback(getRouter as never, {
      app: makeFakeApp(),
      authorInstallationId: 42,
      updateItemStatus: updateItemStatus as never,
      sendMessageUpdate: vi.fn().mockResolvedValue(undefined) as never,
      notifyFailure: vi.fn().mockResolvedValue(undefined) as never,
      resolveJanusTarget: vi.fn().mockReturnValue(null) as never,
      now: () => NOW_MS,
      dedupeMap: new Map(),
    });
    return { server, updateItemStatus };
  }

  it("정상 서명 → 200 + mutation 호출 (express.raw 가 Buffer 를 준다)", async () => {
    const { server, updateItemStatus } = makeIntegrationApp();
    const body = validBody();
    const ts = String(NOW_S);

    const response = await request(server)
      .post("/janus/callback")
      .set("content-type", "application/json")
      .set("x-janus-signature", sign(SECRET, ts, body))
      .set("x-janus-timestamp", ts)
      .send(body);

    expect(response.status).toBe(200);
    await vi.waitFor(() => expect(updateItemStatus).toHaveBeenCalledTimes(1));
  });

  it("콜론 스킴 서명 → 401 (라우터 레벨에서도 점 스킴만 통과)", async () => {
    const { server, updateItemStatus } = makeIntegrationApp();
    const body = validBody();
    const ts = String(NOW_S);

    const response = await request(server)
      .post("/janus/callback")
      .set("content-type", "application/json")
      .set("x-janus-signature", signColon(SECRET, ts, body))
      .set("x-janus-timestamp", ts)
      .send(body);

    expect(response.status).toBe(401);
    expect(updateItemStatus).not.toHaveBeenCalled();
  });

  it("서명은 맞지만 깨진 JSON → 400", async () => {
    const { server, updateItemStatus } = makeIntegrationApp();
    const brokenBody = "{not json";
    const ts = String(NOW_S);

    const response = await request(server)
      .post("/janus/callback")
      .set("content-type", "application/json")
      .set("x-janus-signature", sign(SECRET, ts, brokenBody))
      .set("x-janus-timestamp", ts)
      .send(brokenBody);

    expect(response.status).toBe(400);
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
