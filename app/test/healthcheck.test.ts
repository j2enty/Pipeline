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

  // 이중 차단(M7): 오염된 intervalMs 가 흘러와도 안전 기본값으로 대체돼야 한다.
  // 만약 방어가 없으면 `now - lastTickAt > NaN*2` 등이 항상 false 라 degraded 가
  // 영영 은폐된다. lastTickAt 이 아주 오래전(기본값 5분의 2주기 훨씬 초과)이면
  // intervalMs 가 비정상이어도 반드시 degraded 여야 한다.
  describe("오염된 intervalMs 는 안전 기본값으로 대체 — degraded 은폐 방지", () => {
    const last = 1_000_000;
    const now = last + 10_000_000; // 기본값 300000ms*2=600000ms 를 훨씬 초과

    it("intervalMs = NaN 이어도 degraded (ok 로 은폐되지 않음)", () => {
      expect(evaluateHealth(last, NaN, now)).toBe("degraded");
    });

    it("intervalMs = 0 이어도 degraded", () => {
      expect(evaluateHealth(last, 0, now)).toBe("degraded");
    });

    it("intervalMs = 음수(-100) 여도 degraded", () => {
      expect(evaluateHealth(last, -100, now)).toBe("degraded");
    });

    it("intervalMs = Infinity 여도 degraded (비유한 방어)", () => {
      expect(evaluateHealth(last, Infinity, now)).toBe("degraded");
    });
  });
});
