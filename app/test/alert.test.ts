import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { Probot } from "probot";
import {
  notifyFailure,
  shouldSend,
  resetAlertCooldownForTest,
} from "../src/lib/alert";

// alert.ts — 장애 알림. 핵심 불변식:
//   1. SLACK_WEBHOOK_URL 미설정 → fetch 미호출 & throw 금지
//   2. 설정 시 올바른 payload 로 fetch 1회
//   3. fetch reject → throw 금지 (본 로직 보호)
//   4. 쿨다운 순수함수(shouldSend) 동작
//
// notifyFailure 는 app.log.warn/debug 만 사용 → 최소 shim 으로 충분.

function makeFakeApp(): Probot {
  return {
    log: {
      warn: vi.fn(),
      debug: vi.fn(),
    },
  } as unknown as Probot;
}

describe("shouldSend (쿨다운 순수함수)", () => {
  it("기록이 없으면 첫 호출은 send=true", () => {
    const lastMap = new Map<string, number>();
    expect(shouldSend("k", 1000, lastMap, 5000)).toBe(true);
  });

  it("쿨다운 내 재호출은 false", () => {
    const lastMap = new Map<string, number>([["k", 1000]]);
    // 1000 + 3000 = 4000, 쿨다운 5000 이내 → 스킵
    expect(shouldSend("k", 4000, lastMap, 5000)).toBe(false);
  });

  it("쿨다운 경과 후 재호출은 true", () => {
    const lastMap = new Map<string, number>([["k", 1000]]);
    // 1000 + 6000 = 7000, 쿨다운 5000 초과 → 전송
    expect(shouldSend("k", 7000, lastMap, 5000)).toBe(true);
  });

  it("정확히 쿨다운 경계(now-last == cooldown)는 아직 스킵", () => {
    const lastMap = new Map<string, number>([["k", 1000]]);
    // 6000 - 1000 = 5000, > 5000 이 아니므로 false
    expect(shouldSend("k", 6000, lastMap, 5000)).toBe(false);
  });

  it("키가 다르면 독립적으로 전송", () => {
    const lastMap = new Map<string, number>([["a", 1000]]);
    expect(shouldSend("b", 1100, lastMap, 5000)).toBe(true);
  });
});

describe("notifyFailure", () => {
  const originalFetch = globalThis.fetch;

  const clearEnv = () => {
    delete process.env.SLACK_WEBHOOK_URL;
    delete process.env.ALERT_COOLDOWN_MS;
    delete process.env.ALERT_TIMEOUT_MS;
    // Janus 경로 격리 — ambient JANUS_* 가 webhook 테스트를 오염시키지 않도록.
    delete process.env.JANUS_BASE_URL;
    delete process.env.JANUS_AUTH_TOKEN;
    delete process.env.JANUS_ALERT_CHANNEL;
    delete process.env.JANUS_SOURCE_ID;
  };

  beforeEach(() => {
    resetAlertCooldownForTest();
    clearEnv();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    clearEnv();
    vi.restoreAllMocks();
  });

  it("SLACK_WEBHOOK_URL 미설정 시 fetch 미호출 & throw 안 함", async () => {
    const fetchMock = vi.fn();
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await expect(
      notifyFailure(app, { title: "t", context: "c" })
    ).resolves.toBeUndefined();

    expect(fetchMock).not.toHaveBeenCalled();
    expect(app.log.warn).toHaveBeenCalled();
  });

  it("설정 시 올바른 payload(URL·body)로 fetch 1회 호출", async () => {
    process.env.SLACK_WEBHOOK_URL = "https://hooks.slack.com/test";
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await notifyFailure(app, {
      title: "폴러 죽음",
      context: "에러 발생",
      url: "https://github.com/o/r/issues/1",
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [calledUrl, calledInit] = fetchMock.mock.calls[0];
    expect(calledUrl).toBe("https://hooks.slack.com/test");
    expect(calledInit.method).toBe("POST");

    const body = JSON.parse(calledInit.body as string);
    expect(body.text).toBe(
      "🚨 *폴러 죽음*\n에러 발생\n👀 https://github.com/o/r/issues/1"
    );
  });

  it("fetch 호출 시 AbortSignal(타임아웃) 을 signal 옵션으로 전달한다", async () => {
    process.env.SLACK_WEBHOOK_URL = "https://hooks.slack.com/test";
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await notifyFailure(app, { title: "t", context: "c" });

    const [, calledInit] = fetchMock.mock.calls[0];
    // AbortSignal 인스턴스가 signal 로 전달됐는지 확인 (타임아웃 실제 발동은 검증 불요).
    expect(calledInit.signal).toBeInstanceOf(AbortSignal);
  });

  it("url 없으면 payload 에 👀 줄을 넣지 않는다", async () => {
    process.env.SLACK_WEBHOOK_URL = "https://hooks.slack.com/test";
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await notifyFailure(app, { title: "t", context: "c" });

    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toBe("🚨 *t*\nc");
    expect(body.text).not.toContain("👀");
  });

  it("fetch reject 시 throw 안 함 (본 로직 보호)", async () => {
    process.env.SLACK_WEBHOOK_URL = "https://hooks.slack.com/test";
    const fetchMock = vi.fn().mockRejectedValue(new Error("network down"));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await expect(
      notifyFailure(app, { title: "t", context: "c" })
    ).resolves.toBeUndefined();
    expect(app.log.warn).toHaveBeenCalled();
  });

  it("동일 title 은 쿨다운 내 재전송 스킵 (fetch 1회만)", async () => {
    process.env.SLACK_WEBHOOK_URL = "https://hooks.slack.com/test";
    process.env.ALERT_COOLDOWN_MS = "300000";
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await notifyFailure(app, { title: "같은 장애", context: "1" });
    await notifyFailure(app, { title: "같은 장애", context: "2" });

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  // ── Janus 게이트웨이 경로 (P5.4 이관) ──
  const setJanusEnv = () => {
    process.env.JANUS_BASE_URL = "http://host.docker.internal:8700";
    process.env.JANUS_AUTH_TOKEN = "test-auth";
    process.env.JANUS_ALERT_CHANNEL = "C0PIPE";
    process.env.JANUS_SOURCE_ID = "pipeline";
  };

  it("Janus 설정 시 Janus /messages 로 Bearer·{source_id,channel,text} 전송", async () => {
    setJanusEnv();
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await notifyFailure(app, { title: "머지 차단", context: "blocker", url: "u" });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("http://host.docker.internal:8700/messages");
    expect(init.headers.Authorization).toBe("Bearer test-auth");
    const body = JSON.parse(init.body as string);
    expect(body).toEqual({
      source_id: "pipeline",
      channel: "C0PIPE",
      text: "🚨 *머지 차단*\nblocker\n👀 u",
    });
  });

  it("Janus 비2xx 실패 시 webhook 으로 폴백(fetch 2회)", async () => {
    setJanusEnv();
    process.env.SLACK_WEBHOOK_URL = "https://hooks.slack.com/test";
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: false, status: 502 }) // Janus 실패
      .mockResolvedValueOnce({ ok: true, status: 200 }); // webhook 성공
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await notifyFailure(app, { title: "t", context: "c" });

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[0][0]).toContain("/messages"); // 1차 Janus
    expect(fetchMock.mock.calls[1][0]).toBe("https://hooks.slack.com/test"); // 2차 webhook
  });

  it("Janus 실패 + webhook 없으면 warn 만 (throw 안 함, fetch 1회)", async () => {
    setJanusEnv();
    const fetchMock = vi.fn().mockRejectedValue(new Error("janus down"));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await expect(
      notifyFailure(app, { title: "t", context: "c" })
    ).resolves.toBeUndefined();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(app.log.warn).toHaveBeenCalled();
  });

  it("Janus·webhook 둘 다 미설정이면 fetch 미호출 & warn", async () => {
    const fetchMock = vi.fn();
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const app = makeFakeApp();

    await notifyFailure(app, { title: "t", context: "c" });

    expect(fetchMock).not.toHaveBeenCalled();
    expect(app.log.warn).toHaveBeenCalled();
  });
});
