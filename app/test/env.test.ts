import { describe, it, expect } from "vitest";
import { parsePollerConfigFromEnv, parseModulesIgnore } from "../src/lib/env";

// parsePollerConfigFromEnv — 환경변수에서 폴러 활성/비활성 + config 를
// 순수하게 판단한다. index.ts 가 이 결과에 맞춰 로깅·폴러 시작을 한다.
//
// 판단 순서: owner → author-installation-id → JSON 파싱 → 빈 배열 → config.
// 각 분기를 하나씩 검증한다.

// 정상 케이스의 기준이 되는 완전한 env (필요 시 일부만 덮어쓴다)
const validEnv: NodeJS.ProcessEnv = {
  OWNER: "acme",
  AUTHOR_INSTALLATION_ID: "12345",
  PROJECT_NUMBERS: "[3,5]",
  MODULES: '["Backend","iOS"]',
  STATUS_POLLER_INTERVAL_MS: "60000",
};

describe("parsePollerConfigFromEnv", () => {
  it("OWNER 가 없으면 owner-missing 으로 비활성화한다", () => {
    const env = { ...validEnv, OWNER: undefined };
    const result = parsePollerConfigFromEnv(env);
    expect(result).toEqual({ disabledReason: "owner-missing" });
  });

  it("OWNER 가 빈 문자열이어도 owner-missing 으로 비활성화한다", () => {
    const env = { ...validEnv, OWNER: "" };
    const result = parsePollerConfigFromEnv(env);
    expect(result).toEqual({ disabledReason: "owner-missing" });
  });

  it("AUTHOR_INSTALLATION_ID 가 없으면 author-installation-id-missing 으로 비활성화한다", () => {
    const env = { ...validEnv, AUTHOR_INSTALLATION_ID: undefined };
    const result = parsePollerConfigFromEnv(env);
    expect(result).toEqual({
      disabledReason: "author-installation-id-missing",
    });
  });

  it("PROJECT_NUMBERS 가 깨진 JSON 이면 parse-failed 로 비활성화한다", () => {
    const env = { ...validEnv, PROJECT_NUMBERS: "[3,5" };
    const result = parsePollerConfigFromEnv(env);
    if (!("disabledReason" in result)) {
      throw new Error("parse-failed 가 반환돼야 한다");
    }
    expect(result.disabledReason).toBe("parse-failed");
    // 진단용 원본 문자열이 함께 실려야 한다 (로그에 노출됨)
    expect(result.projectNumbersRaw).toBe("[3,5");
    expect(result.parseError).toBeInstanceOf(Error);
  });

  it("MODULES 가 깨진 JSON 이면 parse-failed 로 비활성화한다", () => {
    const env = { ...validEnv, MODULES: "{not json}" };
    const result = parsePollerConfigFromEnv(env);
    if (!("disabledReason" in result)) {
      throw new Error("parse-failed 가 반환돼야 한다");
    }
    expect(result.disabledReason).toBe("parse-failed");
    expect(result.modulesRaw).toBe("{not json}");
  });

  it("PROJECT_NUMBERS 가 빈 배열이면 empty-arrays 로 비활성화한다", () => {
    const env = { ...validEnv, PROJECT_NUMBERS: "[]" };
    const result = parsePollerConfigFromEnv(env);
    if (!("disabledReason" in result)) {
      throw new Error("empty-arrays 가 반환돼야 한다");
    }
    expect(result.disabledReason).toBe("empty-arrays");
    expect(result.projectNumbers).toEqual([]);
    expect(result.modules).toEqual(["Backend", "iOS"]);
  });

  it("MODULES 가 빈 배열이면 empty-arrays 로 비활성화한다", () => {
    const env = { ...validEnv, MODULES: "[]" };
    const result = parsePollerConfigFromEnv(env);
    if (!("disabledReason" in result)) {
      throw new Error("empty-arrays 가 반환돼야 한다");
    }
    expect(result.disabledReason).toBe("empty-arrays");
  });

  it("PROJECT_NUMBERS / MODULES 가 아예 미설정이면 기본값 [] 로 empty-arrays 가 된다", () => {
    const env = {
      OWNER: "acme",
      AUTHOR_INSTALLATION_ID: "12345",
    };
    const result = parsePollerConfigFromEnv(env);
    if (!("disabledReason" in result)) {
      throw new Error("empty-arrays 가 반환돼야 한다");
    }
    expect(result.disabledReason).toBe("empty-arrays");
  });

  it("모든 값이 정상이면 올바른 config 를 반환한다", () => {
    const result = parsePollerConfigFromEnv(validEnv);
    expect(result).toEqual({
      config: {
        ownerLogin: "acme",
        projectNumbers: [3, 5],
        modules: ["Backend", "iOS"],
        authorInstallationId: 12345,
        intervalMs: 60000,
      },
    });
  });

  it("STATUS_POLLER_INTERVAL_MS 미설정 시 기본 300000(5분) 을 쓴다", () => {
    const env = { ...validEnv, STATUS_POLLER_INTERVAL_MS: undefined };
    const result = parsePollerConfigFromEnv(env);
    if ("disabledReason" in result) {
      throw new Error("config 가 반환돼야 한다");
    }
    expect(result.config.intervalMs).toBe(300000);
  });

  // STATUS_POLLER_INTERVAL_MS 오설정 방어 (M7).
  //   비유한(NaN)·0·음수 → 기본 300000 폴백. setInterval(NaN)→0ms 폭주 +
  //   evaluateHealth 은폐(now-lastTickAt > NaN*2 항상 false)를 파싱 단계에서 차단.
  it.each([
    ["5m", "단위 붙은 오타"],
    ["abc", "숫자 아님"],
    ["0", "0 (setInterval 폭주)"],
    ["-100", "음수"],
    ["", "빈 문자열"],
    ["NaN", "리터럴 NaN"],
    ["Infinity", "무한대"],
  ])(
    "STATUS_POLLER_INTERVAL_MS 가 %o (%s) 이면 기본 300000 으로 폴백한다",
    (badValue) => {
      const env = { ...validEnv, STATUS_POLLER_INTERVAL_MS: badValue };
      const result = parsePollerConfigFromEnv(env);
      if ("disabledReason" in result) {
        throw new Error("config 가 반환돼야 한다");
      }
      expect(result.config.intervalMs).toBe(300000);
    }
  );

  it("STATUS_POLLER_INTERVAL_MS 가 정상 숫자면 그 값을 그대로 쓴다", () => {
    const env = { ...validEnv, STATUS_POLLER_INTERVAL_MS: "60000" };
    const result = parsePollerConfigFromEnv(env);
    if ("disabledReason" in result) {
      throw new Error("config 가 반환돼야 한다");
    }
    expect(result.config.intervalMs).toBe(60000);
  });

  it("authorInstallationId 는 숫자로 변환된다", () => {
    const env = { ...validEnv, AUTHOR_INSTALLATION_ID: "999" };
    const result = parsePollerConfigFromEnv(env);
    if ("disabledReason" in result) {
      throw new Error("config 가 반환돼야 한다");
    }
    expect(result.config.authorInstallationId).toBe(999);
    expect(typeof result.config.authorInstallationId).toBe("number");
  });
});

// parseModulesIgnore — MODULES_IGNORE 환경변수 문자열을 제외 모듈명 배열로 변환한다.
// "조용한 실패 → 시끄러운 실패" 안전망의 일부: 깨진 JSON 이나 배열이 아닌 값은
// 조용히 [] 로 폴백하지 않고 throw 해서 호출부가 에스컬레이션하게 한다.
//
// 빈 값(미설정/빈/공백)은 정상 → [], 그 외 잘못된 값은 throw 로 나뉜다.
describe("parseModulesIgnore", () => {
  // 빈 값 계열 — 제외 모듈 없음(정상)으로 본다.
  it("undefined 이면 빈 배열을 반환한다", () => {
    expect(parseModulesIgnore(undefined)).toEqual([]);
  });

  it("빈 문자열이면 빈 배열을 반환한다", () => {
    expect(parseModulesIgnore("")).toEqual([]);
  });

  it("공백만 있으면 빈 배열을 반환한다", () => {
    expect(parseModulesIgnore("   ")).toEqual([]);
  });

  // 올바른 JSON 배열 계열 — 파싱된 배열을 그대로 돌려준다.
  it("빈 JSON 배열 문자열이면 빈 배열을 반환한다", () => {
    expect(parseModulesIgnore("[]")).toEqual([]);
  });

  it("원소 1개짜리 JSON 배열을 그대로 반환한다", () => {
    expect(parseModulesIgnore('["Design"]')).toEqual(["Design"]);
  });

  it("원소 여러 개짜리 JSON 배열을 그대로 반환한다", () => {
    expect(parseModulesIgnore('["Design","Docs"]')).toEqual([
      "Design",
      "Docs",
    ]);
  });

  // 잘못된 값 계열 — 조용히 폴백하지 않고 throw 한다.
  it("따옴표 없는 깨진 JSON 이면 throw 한다", () => {
    expect(() => parseModulesIgnore("[Design]")).toThrow();
  });

  it("배열이 아닌 객체이면 throw 한다", () => {
    expect(() => parseModulesIgnore("{}")).toThrow();
  });

  it("배열이 아닌 문자열이면 throw 한다", () => {
    expect(() => parseModulesIgnore('"Design"')).toThrow();
  });

  it("배열이 아닌 null 이면 throw 한다", () => {
    expect(() => parseModulesIgnore("null")).toThrow();
  });
});
