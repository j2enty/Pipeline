import { describe, it, expect } from "vitest";
import { parsePollerConfigFromEnv } from "../src/lib/env";

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
