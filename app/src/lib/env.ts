import type { StatusPollerOptions } from "../pollers/status-poller";

// 폴러 tick 간격 기본값 (5분). STATUS_POLLER_INTERVAL_MS env 로 덮어쓸 수 있다.
// alert.ts 의 DEFAULT_COOLDOWN_MS 와 같은 값·같은 의미(1주기)지만 별개 상수로 둔다.
export const DEFAULT_STATUS_POLLER_INTERVAL_MS = 300000;

// STATUS_POLLER_INTERVAL_MS env → 안전한 interval ms.
//   - 미설정 → 기본값
//   - "5m"·"abc" 같은 비유한(NaN) 또는 0·음수 → 기본값으로 조용히 폴백
//     (alert.ts 의 resolveTimeoutMs 와 동일 패턴: Number.isFinite && > 0)
//   순수 함수 유지를 위해 여기서 로깅하지 않는다 — 안전한 값만 반환.
function resolvePollerIntervalMs(raw: string | undefined): number {
  if (!raw) {
    return DEFAULT_STATUS_POLLER_INTERVAL_MS;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0
    ? parsed
    : DEFAULT_STATUS_POLLER_INTERVAL_MS;
}

// 폴러 활성화/비활성화 사유 코드 — index.ts 가 이 코드에 맞춰 동일한 로그를 남긴다.
//
// 부수효과(로깅) 없이 "어떤 사유로 켜지거나 꺼지는지"만 순수하게 판단해서 반환한다.
// 실제 로깅·폴러 시작은 호출부(index.ts)의 책임.
export type PollerDisabledReason =
  | "owner-missing"
  | "author-installation-id-missing"
  | "parse-failed"
  | "empty-arrays";

// 파싱 결과 — 성공 시 config, 실패 시 사유(+진단용 원본/파싱값).
export type PollerConfigResult =
  | { config: StatusPollerOptions }
  | {
      disabledReason: PollerDisabledReason;
      // parse-failed 진단용 (원본 문자열 + 파싱 에러)
      projectNumbersRaw?: string;
      modulesRaw?: string;
      parseError?: unknown;
      // empty-arrays 진단용 (파싱은 됐으나 비어있음)
      projectNumbers?: number[];
      modules?: string[];
    };

// 환경변수 → StatusPoller 옵션 변환 (순수 함수, 부수효과 없음).
//
// 판단 순서는 index.ts 의 기존 동작과 동일하게 유지한다:
//   1. OWNER 없음            → disabled (owner-missing)
//   2. AUTHOR_INSTALLATION_ID 없음 → disabled (author-installation-id-missing)
//   3. PROJECT_NUMBERS/MODULES JSON 파싱 실패 → disabled (parse-failed)
//   4. PROJECT_NUMBERS 또는 MODULES 빈 배열   → disabled (empty-arrays)
//   5. 그 외                 → config 반환
export function parsePollerConfigFromEnv(
  env: NodeJS.ProcessEnv
): PollerConfigResult {
  const ownerLogin = env.OWNER ?? "";
  const projectNumbersRaw = env.PROJECT_NUMBERS ?? "[]";
  const modulesRaw = env.MODULES ?? "[]";
  const authorInstallationIdRaw = env.AUTHOR_INSTALLATION_ID ?? "";
  const intervalMs = resolvePollerIntervalMs(env.STATUS_POLLER_INTERVAL_MS);

  if (!ownerLogin) {
    return { disabledReason: "owner-missing" };
  }
  if (!authorInstallationIdRaw) {
    return { disabledReason: "author-installation-id-missing" };
  }

  let projectNumbers: number[];
  let modules: string[];
  try {
    projectNumbers = JSON.parse(projectNumbersRaw);
    modules = JSON.parse(modulesRaw);
  } catch (parseError) {
    return {
      disabledReason: "parse-failed",
      projectNumbersRaw,
      modulesRaw,
      parseError,
    };
  }

  if (projectNumbers.length === 0 || modules.length === 0) {
    return {
      disabledReason: "empty-arrays",
      projectNumbers,
      modules,
    };
  }

  return {
    config: {
      ownerLogin,
      projectNumbers,
      modules,
      authorInstallationId: Number(authorInstallationIdRaw),
      intervalMs,
    },
  };
}

// MODULES_IGNORE 환경변수 문자열 → 제외 모듈명 배열 (순수 함수, 부수효과 없음).
//
//   - undefined / 빈 문자열 / 공백만 → [] (제외 안 함, 정상)
//   - 올바른 JSON 배열 → 그 배열
//   - JSON 파싱 실패(예: 따옴표 없는 [Design]) 또는 배열이 아님 → Error throw
//     (호출부가 잡아서 에스컬레이션 — 조용한 폴백 금지)
export function parseModulesIgnore(raw: string | undefined): string[] {
  const trimmed = (raw ?? "").trim();
  if (trimmed === "") {
    return [];
  }
  const parsed = JSON.parse(trimmed); // 깨진 JSON 이면 여기서 throw
  if (!Array.isArray(parsed)) {
    throw new Error(`MODULES_IGNORE 가 JSON 배열이 아님 (받은 타입: ${typeof parsed})`);
  }
  return parsed;
}
