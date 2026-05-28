import { describe, it, expect } from "vitest";
import { evaluateHealth } from "../src/lib/healthcheck";

// evaluateHealth — 순수 함수. 살아있음 판단:
//   - lastTickAt null (폴러 미가동) → ok (degraded 아님)
//   - 최근 tick → ok
//   - now - lastTickAt > intervalMs*2 → degraded
//   - 경계값 검증

const INTERVAL = 300000; // 5분

describe("evaluateHealth", () => {
  it("lastTickAt 이 null 이면 ok (폴러 미가동은 degraded 아님)", () => {
    expect(evaluateHealth(null, INTERVAL, 1_000_000)).toBe("ok");
  });

  it("방금 tick 했으면 ok", () => {
    const now = 1_000_000;
    expect(evaluateHealth(now, INTERVAL, now)).toBe("ok");
  });

  it("한 주기 지났어도 ok (intervalMs*2 이내)", () => {
    const last = 1_000_000;
    const now = last + INTERVAL; // 1주기 경과
    expect(evaluateHealth(last, INTERVAL, now)).toBe("ok");
  });

  it("intervalMs*2 초과면 degraded", () => {
    const last = 1_000_000;
    const now = last + INTERVAL * 2 + 1; // 2주기 + 1ms 초과
    expect(evaluateHealth(last, INTERVAL, now)).toBe("degraded");
  });

  it("정확히 intervalMs*2 경계는 아직 ok (초과가 아님)", () => {
    const last = 1_000_000;
    const now = last + INTERVAL * 2; // == intervalMs*2, > 아니므로 ok
    expect(evaluateHealth(last, INTERVAL, now)).toBe("ok");
  });

  it("intervalMs*2 + 1ms 부터 degraded (경계 바로 위)", () => {
    const last = 0;
    expect(evaluateHealth(last, INTERVAL, INTERVAL * 2 + 1)).toBe("degraded");
  });
});
